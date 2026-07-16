"""Per-application volume via Windows Core Audio sessions (new-features Ф2).

Windows controls each app's volume through its audio *sessions* (not the master
mixer), so this uses pycaw to enumerate active sessions and set/adjust the
volume of every session belonging to a given process. Absolute "set" is the
primary action ("громкость на 30" -> 30 %); increase/decrease/mute/unmute are
extras. A session exists only while the app is actually playing, so callers must
handle "process has no active session" gracefully.
"""
from __future__ import annotations

from typing import Optional


def _co_init() -> None:
    # pycaw runs on whatever thread calls it; make sure COM is initialised there
    # (the sidecar drives this from a thread-pool executor, not the main thread).
    try:
        import comtypes
        comtypes.CoInitialize()
    except Exception:
        pass


def _sessions():
    from pycaw.pycaw import AudioUtilities
    return AudioUtilities.GetAllSessions()


def _pretty(display: str, proc_name: str) -> str:
    d = (display or "").strip()
    # DisplayName is frequently empty or an "@%windir%\...,-123" resource ref;
    # fall back to the exe name without extension in that case.
    if d and not d.startswith("@"):
        return d
    base = proc_name
    if base.lower().endswith(".exe"):
        base = base[:-4]
    return base


def _volume_of(session):
    from pycaw.pycaw import ISimpleAudioVolume
    try:
        vol = session._ctl.QueryInterface(ISimpleAudioVolume)
        return vol.GetMasterVolume()
    except Exception:
        return None


def list_sessions() -> list[dict]:
    """Active sessions that have a real process, deduped by process name:
    [{process, display_name, volume(0..1|None)}]. Empty on any failure."""
    _co_init()
    out: dict[str, dict] = {}
    try:
        for s in _sessions():
            proc = s.Process
            if proc is None:
                continue
            try:
                name = proc.name()  # e.g. "Yandex Music.exe"
            except Exception:
                continue
            if not name:
                continue
            key = name.lower()
            if key in out:
                continue
            out[key] = {
                "process": name,
                "display_name": _pretty(s.DisplayName or "", name),
                "volume": _volume_of(s),
            }
    except Exception:
        pass
    return list(out.values())


def apply(process: str, action: str = "set",
          value: Optional[float] = None) -> dict:
    """Apply a volume [action] to EVERY session of [process] (some apps open
    several). [value] is 0..1 for set/increase/decrease. Returns
    {ok, found, volume, process, action}; ok is False when the app has no active
    session (nothing is playing)."""
    _co_init()
    from pycaw.pycaw import ISimpleAudioVolume
    target = (process or "").lower()
    action = action if action in (
        "set", "increase", "decrease", "mute", "unmute") else "set"
    found = 0
    last: Optional[float] = None
    try:
        for s in _sessions():
            proc = s.Process
            if proc is None:
                continue
            try:
                name = proc.name()
            except Exception:
                continue
            if not name or name.lower() != target:
                continue
            try:
                vol = s._ctl.QueryInterface(ISimpleAudioVolume)
            except Exception:
                continue
            found += 1
            if action == "mute":
                vol.SetMute(1, None)
            elif action == "unmute":
                vol.SetMute(0, None)
            else:
                cur = vol.GetMasterVolume()
                if action == "increase":
                    nv = cur + (value or 0.0)
                elif action == "decrease":
                    nv = cur - (value or 0.0)
                else:  # set — absolute
                    nv = value if value is not None else cur
                nv = max(0.0, min(1.0, nv))
                vol.SetMasterVolume(nv, None)
                if nv > 0:
                    vol.SetMute(0, None)  # a non-zero level implies audible
                last = nv
    except Exception:
        pass
    return {
        "ok": found > 0,
        "found": found,
        "volume": last,
        "process": process,
        "action": action,
    }
