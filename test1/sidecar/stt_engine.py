"""Streaming speech-to-text: mic capture + webrtcvad segmentation + faster-whisper.

The engine captures 16 kHz mono audio, uses webrtcvad to find speech segments,
emits {"type": "vad", ...} on speech start/stop, transcribes the growing buffer
periodically for {"type": "stt.partial"} and the whole segment on silence for
{"type": "stt.final"}. All heavy deps are imported lazily so the server can run
(and report capabilities) even before they are installed.
"""
from __future__ import annotations

import queue
import threading
import time

SAMPLE_RATE = 16000
FRAME_MS = 30
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000  # 480
FRAME_BYTES = FRAME_SAMPLES * 2  # int16

# Default Whisper decoding primer (Russian command vocabulary). Biases the
# decoder toward the words the assistant actually expects. The Dart side may
# override this via `stt.start`/`stt.config` (wake word + vocabulary).
_DEFAULT_PROMPT = (
    "Ирис. Открой, закрой, запусти, останови, включи, выключи, найди, "
    "поставь, громкость, яркость, скриншот, музыка, браузер, блокнот, "
    "стоп, хватит."
)


class SttEngine:
    def __init__(self, model_size: str = "small", device: str = "cpu",
                 compute_type: str = "int8") -> None:
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self._model = None
        self._available = False
        try:
            import faster_whisper  # noqa: F401
            import sounddevice  # noqa: F401
            import webrtcvad  # noqa: F401
            import numpy  # noqa: F401

            self._available = True
        except Exception:
            self._available = False

        self._running = False
        self._frames: "queue.Queue[bytes]" = queue.Queue()
        self._capture = None
        self._worker: threading.Thread | None = None
        self._on_event = None
        self._language = None
        # Whisper decoding bias: the wake word + a command vocabulary primer so
        # short domain phrases ("открой блокнот") are transcribed more reliably.
        self._prompt: str | None = _DEFAULT_PROMPT

    @property
    def available(self) -> bool:
        return self._available

    def set_model(self, model_size: str) -> None:
        """Switch the Whisper model size; reloads lazily on next transcription."""
        if model_size and model_size != self.model_size:
            self.model_size = model_size
            self._model = None  # force _ensure_model() to reload the new size

    def set_prompt(self, prompt: str | None) -> None:
        """Update the Whisper decoding primer (wake word + command vocabulary)."""
        p = (prompt or "").strip()
        self._prompt = p if p else _DEFAULT_PROMPT

    def _ensure_model(self):
        if self._model is None:
            from faster_whisper import WhisperModel

            self._model = WhisperModel(
                self.model_size, device=self.device, compute_type=self.compute_type
            )
        return self._model

    # Backlog guard: if transcription can't keep up with real time (e.g. a
    # heavy model on CPU), the frame queue would grow without bound and every
    # reply would arrive minutes late. Cap it at ~30 s and drop the OLDEST
    # audio — better to lose stale speech than to lag forever.
    _MAX_QUEUED_FRAMES = 30_000 // FRAME_MS

    @staticmethod
    def _resolve_input_device(name: str | None):
        """PortAudio input index for a Windows device label ('' = default).

        The app sends the friendly endpoint name (WASAPI); PortAudio names may
        be truncated (MME cuts at ~31 chars), so match on a lowercase prefix
        in both directions.
        """
        if not name:
            return None
        try:
            import sounddevice as sd

            want = name.strip().lower()[:28]
            if not want:
                return None
            for i, d in enumerate(sd.query_devices()):
                if d.get("max_input_channels", 0) <= 0:
                    continue
                have = str(d.get("name", "")).strip().lower()[:28]
                if have and (want in have or have in want or
                             want.startswith(have) or have.startswith(want)):
                    return i
        except Exception:
            pass
        return None

    def start(self, language: str | None, on_event,
              device: str | None = None, prompt: str | None = None) -> bool:
        if not self._available or self._running:
            return self._running
        self._on_event = on_event
        self._language = (language or "ru") if language != "auto" else None
        if prompt is not None:
            self.set_prompt(prompt)
        try:
            import sounddevice as sd

            self._running = True
            with self._frames.mutex:
                self._frames.queue.clear()

            def cb(indata, frames, time_info, status):  # PortAudio thread
                if self._running:
                    if self._frames.qsize() > self._MAX_QUEUED_FRAMES:
                        try:
                            self._frames.get_nowait()
                        except Exception:
                            pass
                    self._frames.put(bytes(indata))

            self._capture = sd.RawInputStream(
                samplerate=SAMPLE_RATE,
                blocksize=FRAME_SAMPLES,
                dtype="int16",
                channels=1,
                device=self._resolve_input_device(device),
                callback=cb,
            )
            self._capture.start()
            self._worker = threading.Thread(target=self._process, daemon=True)
            self._worker.start()
            return True
        except Exception as e:  # pragma: no cover
            self._running = False
            self._emit({"type": "error", "message": f"stt start failed: {e}"})
            return False

    def stop(self) -> None:
        self._running = False
        try:
            if self._capture is not None:
                self._capture.stop()
                self._capture.close()
        except Exception:
            pass
        self._capture = None

    def _emit(self, msg: dict) -> None:
        if self._on_event is not None:
            try:
                self._on_event(msg)
            except Exception:
                pass

    def _process(self) -> None:
        import numpy as np
        import webrtcvad

        # Aggressiveness 3 (strictest): laptop mic arrays emit a constant
        # noise floor that level 2 happily labels "speech" — the segment then
        # NEVER closes, stt.final never fires and the assistant looks dead
        # (observed live: 150 s of nonstop partials, zero finals).
        vad = webrtcvad.Vad(3)
        speech: list[bytes] = []
        speaking = False
        silence_frames = 0
        last_partial = 0.0
        SILENCE_LIMIT = int(600 / FRAME_MS)  # ~600 ms of silence ends a phrase
        MAX_SPEECH_FRAMES = int(12_000 / FRAME_MS)  # force a final after 12 s
        PARTIAL_TAIL_FRAMES = int(5_000 / FRAME_MS)  # partials: last 5 s only
        # Noise gate on top of VAD — silence on some mics still passes VAD and
        # Whisper then hallucinates subtitle credits out of it.
        RMS_GATE = 0.010

        def finalize():
            nonlocal speech, speaking, silence_frames
            speaking = False
            self._emit({"type": "vad", "speaking": False})
            audio = b"".join(speech)
            speech = []
            silence_frames = 0
            self._transcribe(np, audio, final=True)

        while self._running:
            try:
                frame = self._frames.get(timeout=0.5)
            except queue.Empty:
                continue
            if len(frame) != FRAME_BYTES:
                continue
            samples = np.frombuffer(frame, dtype=np.int16)
            rms = float(np.sqrt(np.mean((samples / 32768.0) ** 2)))
            try:
                is_speech = rms >= RMS_GATE and vad.is_speech(frame, SAMPLE_RATE)
            except Exception:
                is_speech = False

            if is_speech:
                if not speaking:
                    speaking = True
                    self._emit({"type": "vad", "speaking": True})
                speech.append(frame)
                silence_frames = 0
                if len(speech) >= MAX_SPEECH_FRAMES:
                    finalize()
                    continue
                now = time.monotonic()
                if now - last_partial > 0.8 and speech:
                    last_partial = now
                    # Re-transcribing the WHOLE buffer every 0.8 s is what
                    # melts the CPU on long segments — partials only need the
                    # recent tail (they're just live feedback for the pill).
                    tail = speech[-PARTIAL_TAIL_FRAMES:]
                    self._transcribe(np, b"".join(tail), final=False)
            elif speaking:
                speech.append(frame)
                silence_frames += 1
                if silence_frames >= SILENCE_LIMIT:
                    finalize()

    # Whisper's signature hallucinations on noise/near-silence (it was
    # trained on subtitles): anything matching these is dropped outright.
    _HALLUCINATION_MARKERS = (
        "субтитр", "подписывайтесь", "продолжение следует", "редактор",
        "корректор", "amara.org", "амара.орг", "dimatorzok",
        "thanks for watching", "субтитры делал", "♪",
    )

    @classmethod
    def _hallucinated(cls, text: str) -> bool:
        low = text.lower()
        return any(m in low for m in cls._HALLUCINATION_MARKERS)

    def _transcribe(self, np, audio_bytes: bytes, final: bool) -> None:
        if not audio_bytes:
            return
        try:
            model = self._ensure_model()
            samples = (
                np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0
            )
            # Finals get a silero VAD pass inside faster-whisper: it strips
            # non-speech, so noise segments mostly return empty instead of
            # hallucinated subtitle credits. Finals also use a wider beam +
            # temperature fallback for accuracy (they're infrequent, so the
            # extra CPU is fine); partials stay cheap/raw for low latency.
            segments, _ = model.transcribe(
                samples,
                language=self._language,
                beam_size=5 if final else 1,
                temperature=[0.0, 0.2, 0.4] if final else 0.0,
                initial_prompt=self._prompt,
                vad_filter=final,
                condition_on_previous_text=False,
            )
            text = " ".join(s.text.strip() for s in segments).strip()
            if text and not self._hallucinated(text):
                self._emit({
                    "type": "stt.final" if final else "stt.partial",
                    "text": text,
                })
        except Exception as e:  # pragma: no cover
            self._emit({"type": "error", "message": f"transcribe failed: {e}"})
