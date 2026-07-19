import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:ffi/ffi.dart';
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:record/record.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:tray_manager/tray_manager.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:fllama/fllama.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:system_info_plus/system_info_plus.dart';

import 'local_model_stub.dart' if (dart.library.io) 'local_model_io.dart';
// Voice visualization widget variants (self-contained CustomPainter widgets,
// adapted from user-provided LiveKit-style bars and SmoothUI Siri Orb).
import 'lk_bar_visualizer.dart';
import 'siri_orb.dart';
import 'wave_field_3d.dart';
import 'wave_field_flat.dart';

// --- Library split into physical part-files under lib/src/ (one library, so all
// private `_` visibility is preserved). See CLAUDE.md for the class→file map. ---
part 'src/bootstrap.dart';
part 'src/i18n.dart';
part 'src/models.dart';
part 'src/llm_services.dart';
part 'src/app_state.dart';
part 'src/theme_widgets.dart';
part 'src/desktop_integration.dart';
part 'src/updater_and_web.dart';
part 'src/sidecar_client.dart';
part 'src/desktop_home.dart';
part 'src/remote_input.dart';
part 'src/voice_viz.dart';
part 'src/desktop_settings.dart';
part 'src/chat_screen.dart';
part 'src/voice_screen.dart';
part 'src/settings_screens.dart';

// Kept short now that the animated ImmersiveSplash provides the real
// startup dwell — otherwise boot would be this delay plus the ~1.5s
// animation stacked back to back.
const _minSplashDuration = Duration(milliseconds: 300);

// Single-instance guard: the main app claims this fixed loopback port. A second
// launch fails to bind, signals the running instance to surface its window, and
// exits — so the desktop shortcut focuses the running app instead of spawning a
// duplicate. Kept alive for the process lifetime so it isn't garbage-collected.
const int _kSingleInstancePort = 47653;
io.ServerSocket? _singleInstanceLock;

// The floating widget window is this many times larger than `overlaySize` so
// there's transparent breathing room around the visualization (the viz itself
// keeps its size — see OverlayWidgetView).
const double kWidgetWindowScale = 1.35;

// HuggingFace repo the GigaAM-v3 sherpa-onnx model is published under — shown in
// the "model not found" hint (TZ1). Mirrors GIGAAM_HF_REPO in the sidecar.
const String kGigaamHfRepo =
    'csukuangfj/sherpa-onnx-nemo-transducer-giga-am-v3-russian-2025-12-16';

// Named Win32 mutex held for the whole process lifetime. The Inno Setup
// installer declares the same name via AppMutex, so during a silent in-app
// update it can detect the running instance and (with CloseApplications=force)
// close it via Restart Manager before copying files — without this the old
// files stay locked and the update silently doesn't apply. The handle is left
// open for the whole process (released automatically when the process dies), so
// there's nothing to store.
void _claimAppMutex() {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final createMutex = k32
        .lookupFunction<_CreateMutexNative, _CreateMutexDart>('CreateMutexW');
    final name = 'EVS-SingleInstance-Mutex'.toNativeUtf16();
    createMutex(nullptr, 0, name);
    malloc.free(name); // the kernel copies the name
  } catch (_) {}
}

typedef _CreateMutexNative = IntPtr Function(
    Pointer<Void>, Int32, Pointer<Utf16>);
typedef _CreateMutexDart = int Function(Pointer<Void>, int, Pointer<Utf16>);

// Best-effort cleanup of a backend orphaned by a previous crashed session.
// main()'s first-instance path is only reached when no other EVS main is
// running (single-instance guard) and before we spawn our own backend — so any
// surviving evs_sidecar.exe is a stray from a crash, holding the mic/IPC port
// and blocking a clean cold start. The Job Object (ProcessJob) and the
// sidecar's parent-watchdog normally prevent orphans; this is the
// belt-and-suspenders for when both failed (TZ: единое дерево процессов —
// чистый повторный запуск после падения).
Future<void> _sweepOrphanBackends() async {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    await io.Process.run(
        'taskkill', ['/F', '/IM', 'evs_sidecar.exe'],
        runInShell: false);
  } catch (_) {}
}

// Restore the main window's saved geometry (size / position / maximized) before
// the first show, validated against the current monitor layout so it never
// lands off-screen after a display change. Geometry lives in prefs (userdata),
// so it survives app updates — the installer replaces the program files in
// {app} but never touches {app}\userdata. DPI note: window_manager and
// screen_retriever both work in logical pixels, so the comparison is
// consistent; mixed-DPI multi-monitor may still be approximate.
Future<void> _restoreWindowBounds(SharedPreferences prefs) async {
  try {
    final w = prefs.getDouble('winW');
    final h = prefs.getDouble('winH');
    final x = prefs.getDouble('winX');
    final y = prefs.getDouble('winY');
    // No saved geometry (first run) — keep WindowOptions' centered default.
    if (w == null || h == null || x == null || y == null) return;
    final rect = await _clampToVisibleArea(Rect.fromLTWH(x, y, w, h));
    await windowManager.setBounds(rect);
    if (prefs.getBool('winMax') ?? false) await windowManager.maximize();
  } catch (_) {}
}

// Fit a saved window rect into the current displays: shrink it to the target
// monitor's work area and, if its title bar isn't visible on any monitor
// (config changed), re-center it on the monitor it most overlaps.
Future<Rect> _clampToVisibleArea(Rect rect) async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    final rects = <Rect>[];
    for (final d in displays) {
      final pos = d.visiblePosition ?? Offset.zero;
      final size = d.visibleSize ?? d.size;
      rects.add(pos & size);
    }
    if (rects.isEmpty) return rect;
    // Pick the display the window overlaps most (fallback: the first/primary).
    var target = rects.first;
    var bestOverlap = -1.0;
    for (final r in rects) {
      final ix = math.min(rect.right, r.right) - math.max(rect.left, r.left);
      final iy = math.min(rect.bottom, r.bottom) - math.max(rect.top, r.top);
      final overlap = (ix > 0 && iy > 0) ? ix * iy : 0.0;
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        target = r;
      }
    }
    var width = rect.width.clamp(900.0, target.width);
    var height = rect.height.clamp(600.0, target.height);
    // Is a meaningful part of the title bar on any monitor?
    final probe = Offset(rect.left + rect.width / 2, rect.top + 12);
    final onScreen = rects.any((r) => r.contains(probe));
    double left, top;
    if (onScreen) {
      left = rect.left.clamp(target.left, target.right - width);
      top = rect.top.clamp(target.top, target.bottom - height);
    } else {
      left = target.left + (target.width - width) / 2;
      top = target.top + (target.height - height) / 2;
    }
    return Rect.fromLTWH(left, top, width, height);
  } catch (_) {
    return rect;
  }
}

// Back SharedPreferences with a JSON file in the app data root (which is
// <exeDir>\userdata in portable mode) instead of the fixed AppData location, so
// chats/settings live next to the program too. Migrates the existing AppData
// prefs once; the legacy file is never deleted (safety net against data loss).
// Must be installed BEFORE any SharedPreferences.getInstance() call.
Future<void> _installPortablePrefs() async {
  try {
    // Only override the store in portable mode. In the AppData fallback the
    // default shared_preferences_windows store already reads the right file
    // (shared_preferences.json) — installing ours (prefs.json) there would hide
    // the user's existing settings/chats.
    final root = await appDataRoot();
    final legacy = await legacyDataRoot();
    if (root == legacy) return;
    SharedPreferencesStorePlatform.instance =
        await _PortablePrefsStore.create();
  } catch (_) {}
}

class _PortablePrefsStore extends SharedPreferencesStorePlatform {
  final io.File _file;
  final Map<String, Object> _cache;
  _PortablePrefsStore._(this._file, this._cache);

  static Future<_PortablePrefsStore> create() async {
    final root = await appDataRoot();
    final sep = io.Platform.pathSeparator;
    final file = io.File('$root${sep}prefs.json');
    var data = <String, Object>{};
    try {
      if (await file.exists()) {
        data = _decode(await file.readAsString());
      } else {
        // One-time migration from the legacy AppData shared_preferences.json.
        final legacyRoot = await legacyDataRoot();
        if (legacyRoot != root) {
          final legacy = io.File('$legacyRoot${sep}shared_preferences.json');
          if (await legacy.exists()) {
            data = _decode(await legacy.readAsString());
            try {
              await file.writeAsString(jsonEncode(data));
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return _PortablePrefsStore._(file, data);
  }

  static Map<String, Object> _decode(String s) {
    final out = <String, Object>{};
    try {
      final m = jsonDecode(s);
      if (m is Map) {
        m.forEach((k, v) {
          if (v != null) out[k.toString()] = v as Object;
        });
      }
    } catch (_) {}
    return out;
  }

  Future<void> _persist() async {
    try {
      await _file.writeAsString(jsonEncode(_cache));
    } catch (_) {}
  }

  @override
  Future<bool> clear() async {
    _cache.clear();
    await _persist();
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async {
    // JSON turns List<String> into List<dynamic>; restore the type
    // SharedPreferences expects.
    final out = <String, Object>{};
    _cache.forEach((k, v) {
      out[k] = v is List ? v.map((e) => e.toString()).toList() : v;
    });
    return out;
  }

  @override
  Future<bool> remove(String key) async {
    _cache.remove(key);
    await _persist();
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _cache[key] = value;
    await _persist();
    return true;
  }
}

void main(List<String> args) async {
  final startedAt = DateTime.now();
  WidgetsFlutterBinding.ensureInitialized();
  final isWindows = defaultTargetPlatform == TargetPlatform.windows;

  // Second-process mode: the floating visualization widget runs as its OWN
  // window/process (`evs.exe --viz-overlay --port=N`), fed by the main app
  // over a localhost WebSocket (VizOverlayServer). This way the widget truly
  // coexists with the chat window, and all the window plumbing
  // (frameless/transparent/topmost/drag) is just this process's main window.
  if (isWindows && args.contains('--viz-overlay')) {
    await _vizOverlayMain(args);
    return;
  }

  // Enforce a single running instance of the main app (widget process above is
  // exempt — it returned already).
  if (isWindows) {
    try {
      _singleInstanceLock = await io.ServerSocket.bind(
          io.InternetAddress.loopbackIPv4, _kSingleInstancePort);
      // First instance: hold the named mutex the installer looks for (AppMutex),
      // so a silent in-app update can close us via Restart Manager.
      _claimAppMutex();
      // Sole instance confirmed and no backend spawned yet: reap any backend
      // orphaned by a previous crash before it blocks the mic/port.
      await _sweepOrphanBackends();
      // We're the first instance: any later launch connects here → show window.
      _singleInstanceLock!.listen((conn) {
        conn.listen((_) {}, onError: (_) {}, cancelOnError: true);
        unawaited(DesktopIntegration.instance.showMainWindow());
        conn.destroy();
      });
    } catch (_) {
      // Port already held → another instance is running. Tell it to surface,
      // then exit without starting a duplicate.
      try {
        final s = await io.Socket.connect(
            io.InternetAddress.loopbackIPv4, _kSingleInstancePort,
            timeout: const Duration(seconds: 2));
        s.add(const [1]);
        await s.flush();
        await s.close();
      } catch (_) {}
      io.exit(0);
    }
  }

  // Portable data (when the app folder is writable): move existing engines/logs
  // next to the program, and back SharedPreferences with a file there. Both run
  // before getInstance / any data access. No-op / AppData fallback otherwise.
  if (isWindows) {
    await migrateHeavyDataIfPortable();
    await _installPortablePrefs();
  }
  final prefs = await SharedPreferences.getInstance();
  final app = AppState(prefs);
  if (isWindows) {
    await windowManager.ensureInitialized();
    await hotKeyManager.unregisterAll();
    // Frameless window — hide the native title bar; EVS draws its own controls
    // (see _WindowTitleBar). Window stays resizable. With the widget enabled
    // (default) the chat window starts HIDDEN — only the floating widget and
    // the tray icon appear; double-click on the widget / tray opens the chat.
    const windowOptions = WindowOptions(
      size: Size(1280, 720),
      minimumSize: Size(900, 600),
      center: true,
      title: 'EVS',
      titleBarStyle: TitleBarStyle.hidden,
    );
    final startHidden = prefs.getBool('overlayMode') ?? true;
    unawaited(windowManager.waitUntilReadyToShow(windowOptions, () async {
      // Restore saved geometry before the first paint (no jump from the default
      // size to the saved one). Applied even while hidden, so a later show from
      // the tray/widget already lands at the right spot.
      await _restoreWindowBounds(prefs);
      if (startHidden) {
        // The native runner shows the window on the first frame regardless —
        // hide explicitly: with the widget enabled, only the floating widget
        // and the tray icon should be visible at startup.
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    }));
  }
  await app.load();

  if (isWindows) {
    await DesktopIntegration.instance.init(app);
  }

  final elapsed = DateTime.now().difference(startedAt);
  if (elapsed < _minSplashDuration) {
    await Future.delayed(_minSplashDuration - elapsed);
  }

  runApp(ChangeNotifierProvider.value(value: app, child: const MiraiApp()));
}

// The floating widget owns its own position, persisted to a DEDICATED file
// (userdata/widget_pos.json) written ONLY by the widget process — never through
// the shared prefs. Rationale (TZ3.3): main + widget share one prefs.json, each
// with its own in-memory cache, so a full-file _persist() from one process
// clobbers fresh values written by the other; and routing the position through
// the main app lost the last drag before shutdown when the widget was killed. A
// private file removes both problems (single writer, survives the main app
// dying). Stores absolute coords plus a best-effort monitor anchor (stable
// display id + work-area-relative offset + DPI) so a widget parked on a second
// monitor returns there after a disconnect/reconnect.
class WidgetPosStore {
  static Future<io.File?> _file() async {
    try {
      final root = await appDataRoot();
      return io.File('$root${io.Platform.pathSeparator}widget_pos.json');
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> read() async {
    try {
      final f = await _file();
      if (f == null || !await f.exists()) return null;
      final m = jsonDecode(await f.readAsString());
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeAbsolute(Offset pos) async {
    try {
      final f = await _file();
      if (f == null) return;
      final rec = <String, dynamic>{'absX': pos.dx, 'absY': pos.dy};
      final anchor = await _anchorFor(pos);
      if (anchor != null) rec.addAll(anchor);
      await f.writeAsString(jsonEncode(rec));
    } catch (_) {}
  }

  // One-time migration: seed the file from the legacy prefs overlayX/Y (owned by
  // the main process) so an existing widget keeps its spot across this update.
  static Future<void> migrateFromPrefs(SharedPreferences prefs) async {
    try {
      final f = await _file();
      if (f == null || await f.exists()) return;
      final x = prefs.getDouble('overlayX');
      final y = prefs.getDouble('overlayY');
      if (x == null || y == null) return;
      await writeAbsolute(Offset(x, y));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> _anchorFor(Offset pos) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      for (final d in displays) {
        final dp = d.visiblePosition ?? Offset.zero;
        final ds = d.visibleSize ?? d.size;
        if ((dp & ds).contains(pos)) {
          return {
            'mon': d.id,
            'monName': d.name,
            'relX': pos.dx - dp.dx,
            'relY': pos.dy - dp.dy,
            'scale': d.scaleFactor ?? 1.0,
          };
        }
      }
    } catch (_) {}
    return null;
  }

  // Resolve a saved record into an absolute position for the CURRENT monitor
  // layout. Returns null when the saved monitor is gone AND the absolute
  // fallback isn't on any current display — the caller then parks the widget on
  // a safe default WITHOUT overwriting the record, so it returns to its place
  // when the monitor comes back.
  static Future<Offset?> resolve(Map<String, dynamic> rec) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) return null;
      final mon = rec['mon'];
      final monName = rec['monName'];
      final relX = (rec['relX'] as num?)?.toDouble();
      final relY = (rec['relY'] as num?)?.toDouble();
      if (relX != null && relY != null) {
        for (final d in displays) {
          final match = (mon != null && d.id == mon) ||
              (monName != null && d.name == monName);
          if (match) {
            final dp = d.visiblePosition ?? Offset.zero;
            return Offset(dp.dx + relX, dp.dy + relY);
          }
        }
      }
      // Saved monitor absent — use the absolute fallback only if still on-screen.
      final absX = (rec['absX'] as num?)?.toDouble();
      final absY = (rec['absY'] as num?)?.toDouble();
      if (absX != null && absY != null) {
        final pos = Offset(absX, absY);
        for (final d in displays) {
          final dp = d.visiblePosition ?? Offset.zero;
          final ds = d.visibleSize ?? d.size;
          if ((dp & ds).contains(pos)) return pos;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

/* ==================== ПРОЦЕСС ПЛАВАЮЩЕГО ВИДЖЕТА ==================== */

// Entry point of the widget process (`evs.exe --viz-overlay --port=N`): a
// tiny transparent always-on-top window rendering just the voice
// visualization. No prefs writes, tray, hotkeys, sidecar, updater or mic
// here — everything it shows arrives from the main process over a localhost
// WebSocket, and it exits as soon as that socket closes.
Future<void> _vizOverlayMain(List<String> args) async {
  var port = 0;
  for (final a in args) {
    if (a.startsWith('--port=')) port = int.tryParse(a.substring(7)) ?? 0;
  }
  await windowManager.ensureInitialized();
  try {
    await acrylic.Window.initialize();
  } catch (_) {}
  // Placeholder size; the first cfg from the main process sets the real one
  // (overlaySize * kWidgetWindowScale). Pre-scaled to avoid a resize flash.
  const opts = WindowOptions(
    size: Size(260 * kWidgetWindowScale, 260 * kWidgetWindowScale),
    minimumSize: Size(120, 120),
    title: 'EVS Widget',
    titleBarStyle: TitleBarStyle.hidden,
    skipTaskbar: true,
    alwaysOnTop: true,
  );
  unawaited(windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.setAsFrameless();
    try {
      await acrylic.Window.setEffect(
        effect: acrylic.WindowEffect.transparent,
        color: const Color(0x00000000),
        dark: true,
      );
    } catch (_) {}
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    // Restore the widget's own saved position (its private file) before showing,
    // resolved against the current monitor layout. If its monitor is gone, park
    // at a safe default WITHOUT touching the saved record (see WidgetPosStore).
    Offset? restored;
    final rec = await WidgetPosStore.read();
    if (rec != null) restored = await WidgetPosStore.resolve(rec);
    if (restored != null) {
      await windowManager.setPosition(restored);
    } else {
      await windowManager.setAlignment(Alignment.centerRight);
    }
    await windowManager.show();
  }));
  runApp(VizOverlayApp(port: port));
}

class VizOverlayApp extends StatefulWidget {
  final int port;
  const VizOverlayApp({super.key, required this.port});
  @override
  State<VizOverlayApp> createState() => _VizOverlayAppState();
}

class _VizOverlayAppState extends State<VizOverlayApp> with WindowListener {
  // A bare AppState used purely as the config holder: the shared widgets
  // (OverlayWidgetView, EvsLiveViz, …) read vizType/accent/… through the
  // provider, so mirroring the main process's settings into it makes them
  // work unchanged. load() is never called and no setter ever runs here, so
  // this process never writes shared_preferences.
  AppState? _cfg;
  io.WebSocket? _ws;
  // The widget persists its OWN position (WidgetPosStore) — onWindowMoved is
  // unreliable after a native startDragging() on Windows, so poll the position
  // on a timer and write the file on any real change. _userMoved gates the
  // final flush so a widget parked on a default spot (its monitor gone) never
  // overwrites the saved location.
  Timer? _posTimer;
  Offset? _lastPollPos;
  bool _userMoved = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _boot();
  }

  Future<void> _boot() async {
    // Same portable prefs store as the main process (same exe folder → same
    // root). Read-only here, but keeps both processes pointed at one file.
    await _installPortablePrefs();
    final prefs = await SharedPreferences.getInstance();
    setState(() => _cfg = AppState(prefs));
    await _connect();
    _startPositionWatch();
  }

  void _startPositionWatch() {
    _posTimer?.cancel();
    _posTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      try {
        final p = await windowManager.getPosition();
        final last = _lastPollPos;
        final moved = last == null ||
            (p.dx - last.dx).abs() > 1 ||
            (p.dy - last.dy).abs() > 1;
        if (!moved) return;
        _lastPollPos = p;
        // Skip the first reading (the restored/parked spot); only persist once
        // the user has actually dragged the widget somewhere new. The widget
        // writes its OWN file — no round-trip through the main process.
        if (last != null) {
          _userMoved = true;
          unawaited(WidgetPosStore.writeAbsolute(p));
        }
      } catch (_) {}
    });
  }

  Future<void> _connect() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final ws = await io.WebSocket.connect('ws://127.0.0.1:${widget.port}');
        _ws = ws;
        ws.listen(_onMsg, onDone: _die, onError: (_) => _die());
        return;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    _die();
  }

  // The main app is gone (socket closed / never appeared) — so are we. Flush the
  // final position first (the last <500 ms of dragging the poll may have missed)
  // — but only if the user actually moved the widget, so a widget parked on a
  // default spot because its monitor is gone never overwrites the saved record.
  Future<void> _die() async {
    if (_userMoved) {
      try {
        await WidgetPosStore.writeAbsolute(await windowManager.getPosition());
      } catch (_) {}
    }
    io.exit(0);
  }

  void _onMsg(dynamic data) {
    final app = _cfg;
    if (app == null || data is! String) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'cfg':
        app.applyVizCfg(m);
        final size = (m['size'] as num?)?.toDouble();
        if (size != null) unawaited(windowManager.setSize(Size(size, size)));
        // Position is restored by the widget itself before show (WidgetPosStore)
        // — the main process no longer sends x/y in cfg.
        break;
      case 'lvl':
        VoiceLevels.instance.tts.value =
            ((m['v'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
        break;
      case 'va':
        // Mirror the main process's assistant state into this process's
        // (unattached) singletons — the shared badge/glow widgets listen to
        // exactly these notifiers.
        final s = m['s'] as String?;
        if (s != null) {
          VoiceAssistant.instance.state.value = VaState.values
              .firstWhere((e) => e.name == s, orElse: () => VaState.idle);
        }
        if (m['wake'] is bool) {
          VoiceAssistant.instance.wakeActive.value = m['wake'] as bool;
        }
        final pulse = (m['pulse'] as num?)?.toInt();
        if (pulse != null) VoiceAssistant.instance.wakePulse.value = pulse;
        break;
      case 'note':
        final ts = DateTime.now().millisecondsSinceEpoch;
        vizNotice.value = (
          (m['text'] as String?) ?? '',
          (m['kind'] as String?) ?? 'info',
          ts,
        );
        Timer(const Duration(milliseconds: 2800), () {
          if (vizNotice.value?.$3 == ts) vizNotice.value = null;
        });
        break;
      case 'bye':
        _die();
    }
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ws?.add(jsonEncode(m));
    } catch (_) {}
  }

  @override
  void dispose() {
    _posTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = _cfg;
    if (app == null) return const SizedBox.shrink();
    return ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        color: Colors.transparent,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.transparent,
          fontFamily: 'Nunito',
        ),
        home: OverlayWidgetView(
          onOpen: () => _send({'t': 'open'}),
          onHide: () async {
            await windowManager.hide();
            _send({'t': 'hidden'});
          },
        ),
      ),
    );
  }
}

/* ============================ ЛОКАЛИЗАЦИЯ ============================ */

const Map<String, Map<String, String>> _i18n = {
  'ru': {
    'appName': 'EVS',
    // EVS desktop UI
    'yesterday': 'Вчера',
    'microphone': 'Микрофон',
    'ready': 'Готов',
    'micListening': 'Слушаю',
    'apiKeyHint': 'API-ключ (если нужен)',
    'statusLocalModel': 'Локальная нейросеть',
    'statusRemoteModel': 'Удалённая нейросеть',
    'statusOnline': 'онлайн',
    'statusConnected': 'подключена',
    'statusConnecting': 'подключение…',
    'statusNoModel': 'модель не выбрана',
    'statusDisconnected': 'не подключена',
    'statusError': 'ошибка подключения',
    'statusTitle': 'Состояние нейросети',
    'modelField': 'Модель',
    'serverField': 'Сервер',
    'navGeneral': 'Общие',
    'navGeneralSub': 'настройки приложения',
    'navVoiceInput': 'Голосовой ввод',
    'navVoiceInputSub': 'распознавание и микрофон',
    'navVoiceCommands': 'Голосовые команды',
    'navVoiceCommandsSub': 'управление компьютером',
    'navModel': 'Модель и инференс',
    'navModelSub': 'нейросеть и подключение',
    'navPersona': 'Личность и память',
    'navPersonaSub': 'персонализация ассистента',
    'navPrivacy': 'Приватность',
    'navPrivacySub': 'данные и доступ',
    'navAbout': 'О приложении',
    'navAboutSub': 'версия и обновления',
    'sectionStub': 'Раздел в разработке — скоро здесь появятся настройки.',
    'cardLangLoc': 'Язык и локализация',
    'interfaceLanguage': 'Язык интерфейса',
    'interfaceLanguageDesc': 'Язык меню, кнопок и уведомлений',
    'recognitionLanguage': 'Язык распознавания (STT)',
    'recognitionLanguageDesc': 'По умолчанию совпадает с языком интерфейса',
    'sttAuto': 'Авто',
    'cardAppearance': 'Внешний вид',
    'appStyleDesc': 'Liquid Glass — размытие и акриловые эффекты',
    'styleClassic': 'Классический',
    'fontSizeDesc': 'Влияет на размер шрифта и элементов',
    'cardStartup': 'Запуск и поведение',
    'autostart': 'Автозапуск с Windows',
    'autostartDesc': 'Запускать EVS при входе в систему',
    'minimizeToTray': 'Сворачивать в трей',
    'minimizeToTrayDesc': 'Убирать в значок при сворачивании',
    'closeToTray': 'Закрывать в трей',
    'closeToTrayDesc': 'При закрытии окна сворачивать в трей, а не выходить',
    'globalHotkey': 'Глобальная горячая клавиша',
    'globalHotkeyDesc': 'Показать окно EVS из любого приложения',
    'trayShow': 'Показать EVS',
    'trayQuit': 'Выход',
    'notifications': 'Уведомления',
    'notificationsDesc': 'Показывать системные уведомления Windows',
    'uiAnimations': 'Анимации интерфейса',
    'uiAnimationsDesc': 'Плавные переходы и эффекты',
    'sidecar': 'Голосовой движок (Python)',
    'sidecarDesc': 'Отдельный процесс EVS для Whisper, VAD и озвучки',
    'sidecarConnected': 'Подключён',
    'sidecarStarting': 'Запуск…',
    'sidecarStopped': 'Не запущен',
    'sidecarComponent': 'Компонент движка',
    'sidecarComponentDesc': 'Догружается отдельно (не входит в установщик)',
    'download': 'Скачать',
    'componentReady': 'Установлен',
    'componentVerifying': 'Проверка…',
    'cardStt': 'Движок STT',
    'sttEngine': 'Движок распознавания',
    'sttEngineDesc': 'Локальный движок (Whisper/GigaAM) работает офлайн на вашем железе',
    'localEngineName': 'Локальный (EVS)',
    'msShort': 'мс',
    'cardSttModel': 'Локальный движок',
    'engWhisperName': 'Whisper',
    'engWhisperShort': 'Мультиязычная, средняя точность',
    'engGigaamName': 'GigaAM-v3',
    'engGigaamShort': 'Лучшая точность для русского. Рекомендуется',
    'moreDetails': 'Подробнее',
    'lessDetails': 'Свернуть',
    'checkConn': 'Проверить соединение',
    'connChecking': 'Проверка…',
    'connOnline': 'Соединение есть',
    'connModelsCount': 'моделей',
    'connBadUrl': 'Укажите адрес сервера выше',
    'refreshModelsBtn': 'Обновить список',
    'cardPresets': 'Быстрые профили',
    'presetsDesc':
        'Один тап настраивает несколько параметров сразу. Тонкую настройку можно сделать ниже.',
    'presetFast': 'Быстро',
    'presetFastDesc': 'CPU · лёгкое шумоподавление · без веб-поиска',
    'presetQuality': 'Качество',
    'presetQualityDesc': 'GPU · сильное шумоподавление',
    'presetSearch': 'Поиск',
    'presetSearchDesc': 'Веб-поиск включён',
    'presetChat': 'Чат',
    'presetChatDesc': 'Веб-поиск выключен',
    'presetApplied': 'Профиль применён: {name}',
    'modelPerMode': 'Модель по режиму',
    'modelPerModeDesc':
        'Разные модели для поиска и обычного чата. Поисковая используется, когда '
            'для ответа подтянуты веб-результаты.',
    'modelForSearch': 'Для поиска',
    'modelForChat': 'Для чата',
    'modelDefaultGlobal': 'Как выбрана глобально',
    'modelNotOnServer': 'не найдена на сервере',
    'cardLlmAdv': 'Дополнительно',
    'llmAdvDesc':
        'Параметры запроса к модели. Пустое поле — параметр не отправляется, '
            'работает значение самой модели.',
    'llmNumCtx': 'Размер контекста',
    'llmNumCtxDesc': 'num_ctx — сколько токенов модель держит в контексте',
    'llmNumPredict': 'Лимит ответа',
    'llmNumPredictDesc': 'num_predict — максимальная длина ответа в токенах',
    'llmTemp': 'Температура',
    'llmTempDesc': 'temperature — 0 предсказуемо, выше — свободнее (0–1.5)',
    'llmKeepAlive': 'Держать модель в памяти',
    'llmKeepAliveDesc': 'keep_alive — например 30m или -1 (не выгружать)',
    'llmDefaultHint': 'по умолчанию',
    'llmBadNumber': 'Нужно число',
    'llmTempRange': 'Допустимо 0–1.5',
    'engWhisperDetail':
        'Понимает много языков, но короткие русские команды распознаёт хуже GigaAM. Медленнее на длинных фразах — обрабатывает звук 30-секундными окнами. base и tiny легче и быстрее, но точность ещё ниже — вариант для слабого железа.',
    'engGigaamDetail':
        'Обучена специально на русской речи, уверенно распознаёт короткие команды. ~300 МБ на диске, ~0.6–1 ГБ ОЗУ, отклик ~0.1–0.3 с. Работает только с русским языком.',
    'dnOffDetail':
        'Микрофон передаётся как есть. Подходит для тихой комнаты и хорошего микрофона; ресурсы не тратятся.',
    'dnLightDetail':
        'GTCRN — лёгкая нейросеть: убирает постоянный шум (вентиляторы, гул) и часть резких звуков. Задержка ~10 мс, нагрузка на процессор незаметна.',
    'dnStrongDetail':
        'DeepFilterNet — модель посерьёзнее: давит клавиатуру, музыку, разговоры. Ощутимо больше нагрузки на процессор, требует скачивания модели (~8 МБ). Включай, если лёгкого шумоподавления не хватает.',
    'engActive': 'Активна',
    'engReady': 'Готова',
    'engLoading': 'Загружается…',
    'engNotFound': 'Модель не найдена',
    'engSwitchFailed': 'Не удалось переключить движок',
    'engWhisperSize': 'Размер модели',
    'cardModels': 'Модели',
    'mdlInstalled': 'Установлена',
    'mdlNotInstalled': 'Не установлена',
    'mdlDownload': 'Скачать',
    'mdlOpenFolder': 'Открыть папку моделей',
    'mdlRamShort': 'МБ ОЗУ',
    'mdlActiveCantDelete': 'Нельзя удалить активную модель',
    'mdlDeleteConfirm': 'Удалить модель с диска?',
    'mdlDelete': 'Удалить',
    'mbShort': 'МБ',
    'mdlTotalDisk': 'Занято на диске',
    'cardDenoise': 'Шумоподавление',
    'mdlAdd': 'Добавить',
    'deviceLabel': 'Обработка',
    'deviceCpu': 'CPU',
    'deviceGpu': 'GPU',
    'deviceHintWhisper': 'На GPU Whisper работает в разы быстрее на длинных фразах.',
    'deviceFellBack': 'Не удалось задействовать GPU — работаю на процессоре.',
    'cardGameMode': 'Игровой режим',
    'gmFullscreen': 'Игровой режим',
    'gmFullscreenDesc': 'В полноэкранной игре переношу GPU-движки на процессор',
    'gmVram': 'Следить за видеопамятью',
    'gmVramDesc': 'Разгружать GPU, когда видеопамять почти заполнена (нужен NVIDIA)',
    'gmVramEnter': 'Порог включения',
    'gmVramExit': 'Порог выключения',
    'gmNotify': 'Голосовое уведомление',
    'gmNotifyDesc': 'Проговаривать вход/выход из разгрузки; бейдж остаётся в любом случае',
    'gmExclusions': 'Исключения',
    'gmExclusionsDesc': 'Процессы, которые полноэкранны, но не игры (видеоплеер и т.п.)',
    'gmExclAdd': 'Добавить процесс',
    'gmOffloadActive': 'Сейчас активна разгрузка GPU — движки на процессоре.',
    'gmOffloadBadge': 'Разгрузка GPU',
    'gmReasonFullscreen': 'полноэкранный режим',
    'gmReasonVram': 'заполнена видеопамять',
    'gmNotifyFullscreen': 'Обнаружен полноэкранный режим — переключаюсь на процессор',
    'gmNotifyVram': 'Видеопамять почти заполнена — переключаюсь на процессор',
    'gmNotifyExit': 'Возвращаю настройки',
    'extraMics': 'Дополнительные микрофоны',
    'extraMicsDesc': 'Слушать сразу с нескольких микрофонов (например, в разных комнатах). Одна фраза, услышанная несколькими, выполнится один раз.',
    'micSelfCleaningHint': 'У этого микрофона своё шумоподавление — встроенное отключено, чтобы не обрабатывать звук дважды.',
    'dnOff': 'Выкл',
    'dnLight': 'Лёгкое',
    'dnStrong': 'Сильное',
    'dnOffShort': 'Микрофон как есть — для тихой комнаты и хорошего микрофона.',
    'dnLightShort':
        'Убирает фоновый шум, почти не тратит ресурсы. Рекомендуется.',
    'dnStrongShort':
        'Максимальное подавление: клавиатура, музыка, разговоры. Дороже по CPU.',
    'dnNotInstalled': 'Модель не скачана — откройте раздел «Модели».',
    'whisperOffline': 'Whisper (офлайн)',
    'whisperModel': 'Модель Whisper',
    'whisperModelDesc':
        'Влияет на качество и скорость. Внимание: medium на CPU обрабатывает '
            'фразу ~минуту — ассистент будет казаться мёртвым. Рекомендуется small',
    'cardInputDevice': 'Устройство ввода',
    'inputDevice': 'Устройство ввода',
    'inputDeviceDesc': 'Микрофон, используемый для записи',
    'defaultDevice': 'По умолчанию',
    'micTest': 'Тест микрофона',
    'micTestDesc': 'Проверьте уровень и качество сигнала',
    'runTest': 'Запустить тест',
    'inputLevel': 'Уровень входного сигнала',
    'cardListenMode': 'Режим прослушивания',
    'activationMode': 'Режим активации',
    'activationModeDesc': 'Push-to-talk требует удержания клавиши',
    'continuous': 'Непрерывное',
    'autoSendPause': 'Авто-отправка по паузе',
    'autoSendPauseDesc': 'Отправлять текст автоматически после тишины',
    'pauseDuration': 'Длительность паузы',
    'pauseDurationDesc': 'Через сколько секунд считать фразу завершённой',
    'secShort': 'с',
    'showPartial': 'Показывать частичный текст',
    'showPartialDesc': 'Отображать распознанное прямо во время речи',
    'cardVoiceViz': 'Визуализация голоса',
    'vizType': 'Тип визуализации',
    'vizTypeDesc': 'Анимация, реагирующая на уровень голоса',
    'vizSphere': 'Сфера',
    'vizWaves': 'Волны',
    'vizBars': 'Бары',
    'vizNone': 'Нет',
    'navWidgets': 'Виджеты',
    'navWidgetsSub': 'визуализация и оверлей',
    'cardWsPreview': 'Предпросмотр',
    'cardWsStyle': 'Стиль виджета',
    'cardWsParams': 'Параметры',
    'vizOrb': 'Siri Orb',
    'vizLkBars': 'Полоски',
    'vizWave3d': 'Волны 3D',
    'vizWaveFlat': 'Поле частиц',
    'settingsUnsaved': 'Есть несохранённые изменения',
    'settingsSaved': 'Настройки применены и сохранены',
    'settingsSaveFailed':
        'Не удалось применить настройки. Возвращены прежние значения',
    'settingsExitTitle': 'Сохранить изменения?',
    'settingsExitSave': 'Сохранить',
    'settingsExitDiscard': 'Не сохранять',
    'settingsExitStay': 'Остаться',
    'wsAccent': 'Акцентный цвет',
    'wsAccentDesc': 'Цвет Siri Orb и Полосок',
    'wsOrbSize': 'Размер орба',
    'wsOrbSpeed': 'Скорость вращения',
    'wsOrbSpeedDesc': 'Секунд на полный оборот',
    'wsFast': 'быстро',
    'wsSlow': 'медленно',
    'wsBarCount': 'Количество полосок',
    'wsSimVoice': 'Имитация голоса',
    'wsStateIdle': 'Ожидание',
    'wsStateListening': 'Слушает',
    'wsStateSpeaking': 'Говорит',
    'wsStateThinking': 'Думает',
    'ovlEnter': 'Плавающий виджет',
    'ovlEnterDesc':
        'Визуализация в маленьком прозрачном окне поверх всех окон. '
            'Двойной клик по виджету — вернуться в чат',
    'ovlShow': 'Показывать виджет',
    'ovlSize': 'Размер виджета',
    'ovlSizeDesc': 'Размер плавающего окна с визуализацией',
    'ovlSizeS': 'Маленький',
    'ovlSizeM': 'Средний',
    'ovlSizeL': 'Большой',
    'ovlOpenChat': 'Открыть EVS',
    'ovlHide': 'Скрыть виджет',
    'trayOverlay': 'Плавающий виджет',
    'showVizBg': 'Показывать в фоне',
    'showVizBgDesc': 'Отображать визуализацию на главном экране',
    'cardVoiceResp': 'Голос ответа',
    'voiceResponses': 'Озвучивать ответы',
    'voiceResponsesDesc': 'Проговаривать ответы ассистента голосом',
    'announceReady': 'Озвучивать готовность',
    'announceReadyDesc': 'Произносить голосом, когда ассистент готов слушать',
    'ttsEngineTitle': 'Движок озвучки',
    'ttsEnginePiper': 'Piper',
    'ttsEnginePiperHint': 'быстро, офлайн, CPU',
    'ttsEngineCosy': 'CosyVoice',
    'ttsEngineCosyHint': 'качество, GPU',
    'ttsCosyUnavailable': 'CosyVoice недоступен — сервер не отвечает',
    'ttsCosyEndpoint': 'Endpoint CosyVoice',
    'ttsCosyCheck': 'Проверить соединение',
    'ttsCosyOnline': 'На связи',
    'ttsCosyOffline': 'Не отвечает',
    'ttsCosyFellBack': 'CosyVoice недоступен — озвучка переключена на Piper',
    'ttsCosyChecking': 'Проверка…',
    'ttsCosyWiringHint':
        'Настройки сохраняются. Синтез через CosyVoice подключится, когда сервер будет развёрнут.',
    'ttsCosyVoice': 'Голос / пресет',
    'ttsCosyVoiceHint': 'ID пресета (spk_id) — для моделей SFT. Необязательно.',
    'ttsCosyClone': 'Клонировать по образцу',
    'ttsCosyClonePick': 'Выбрать WAV…',
    'ttsCosyCloneNone': 'Образец не выбран',
    'ttsCosyClonePrompt': 'Текст в образце',
    'ttsCosyClonePromptHint': 'Что произнесено в WAV-образце (нужно для клонирования).',
    'ttsCosySpeed': 'Скорость',
    'ttsCosyEmotion': 'Эмоция',
    'ttsCosyEmotionNeutral': 'Нейтрально',
    'ttsCosyEmotionHappy': 'Радостно',
    'ttsCosyEmotionSad': 'Грустно',
    'ttsCosyEmotionSerious': 'Строго',
    'ttsCosyEmotionCalm': 'Спокойно',
    'ttsCosyEmotionExcited': 'Воодушевлённо',
    'ttsCosyInstruct': 'Инструкция (свободный текст)',
    'ttsCosyInstructHint': 'Своя инструкция стиля/эмоции — переопределяет пресет.',
    'ttsCosyDevice': 'Устройство синтеза',
    'ttsInterp': 'Интерпретатор озвучки',
    'ttsInterpDesc':
        'Приводит текст к произносимому виду перед синтезом: числа и даты словами, '
            'без эмодзи и разметки.',
    'ttsInterpRules': 'Правилами',
    'ttsInterpRulesHint': 'Быстро, офлайн',
    'ttsInterpModel': 'Через модель',
    'ttsInterpModelHint': 'Точнее, но медленнее и нужен сервер',
    'ttsInterpModelField': 'Модель интерпретатора',
    'ttsInterpFellBack':
        'Модель интерпретатора недоступна — озвучиваю по правилам.',
    'readyGreeting': 'Готова слушать',
    'sttStarting': 'Запуск…',
    'sttLoadingModels': 'Загружаю модели…',
    'sttReadyMsg': 'Готова слушать',
    'sttErrorState': 'Ошибка запуска распознавания',
    'ttsRate': 'Скорость речи',
    'ttsRateDesc': 'Темп проговаривания',
    'ttsVolume': 'Громкость',
    'cardAssistantVoice': 'Голос ассистента',
    'voiceSystemName': 'Системный голос (без скачивания)',
    'voiceSystemDesc': 'Звучит машинно, зато работает сразу — без загрузок.',
    'voiceListen': 'Прослушать',
    'voiceSelect': 'Выбрать',
    'voiceSamplePhrase': 'Привет! Я EVS, твой голосовой ассистент.',
    'voiceIrina': 'Женский голос, среднее качество (Piper).',
    'voiceDenis': 'Мужской голос, среднее качество (Piper).',
    'voiceDmitri': 'Мужской голос, среднее качество (Piper).',
    'voiceRuslan': 'Мужской голос, среднее качество (Piper).',
    'cardCmdExec': 'Выполнение команд',
    'cmdAllow': 'Разрешить выполнение команд',
    'cmdAllowDesc':
        'EVS сможет запускать приложения, открывать сайты и управлять системой',
    'cardCmdRecognition': 'Распознавание команд',
    'cmdMode': 'Режим распознавания',
    'cmdModeDesc': 'Как EVS понимает, что это команда, а не текст для ввода',
    'cmdModeWake': 'Слово-активатор',
    'cmdModeSeparate': 'Отдельный режим',
    'cmdModeFirst': 'Сначала команда',
    'cmdActivator': 'Слово-активатор',
    'cmdActivatorDesc': 'Скажите «EVS» перед командой, напр. «EVS, открой браузер»',
    'cmdStopWords': 'Слова остановки',
    'cmdStopWordsDesc': 'Через запятую. Прервут озвучку и генерацию (напр. «стоп, хватит, отмена»)',
    'saveServerBtn': 'Сохранить адрес',
    'vaListening': 'Слушаю…',
    'vaThinking': 'Думаю…',
    'vaRunning': 'Выполняю…',
    'vaDone': 'Готово',
    'vaFailed': 'Не удалось выполнить команду',
    'vaCmdDisabled': 'Команда распознана, но выполнение выключено (включите «Разрешить выполнение команд»)',
    'vaCmdNotFound': 'Команда не найдена',
    'chatToggle': 'Чат',
    'chatToggleDesc': 'Выключите, чтобы работали только команды: нераспознанная фраза не уйдёт в чат, а ответит «Команда не найдена». Текстовый ввод при этом отключается.',
    'chatDisabledHint': 'Чат отключён — работают только голосовые команды',
    'vaSttOffline': 'Голосовой движок не подключён',
    'updRestart': 'Перезапустить',
    'updUpToDate': 'Актуальная версия',
    'updReadyShort': 'Обновление',
    'updFlowDesc': 'Обновление скачается в фоне — останется перезапустить',
    'updAvailableTitle': 'Доступно обновление',
    'updDialogHint': 'Обновление уже скачано. Перезапустите EVS, чтобы применить.',
    'updLater': 'Позже',
    'updFailedApply': 'Обновление не установилось. Закройте EVS полностью и попробуйте снова.',
    'updApplied': 'EVS обновлён до {v}',
    'updFailedManual': 'Автообновление до {v} не установилось. Скачайте установщик вручную.',
    'updDownloadManual': 'Скачать',
    'webSearch': 'Веб-поиск',
    'webSearchEnable': 'Искать в интернете',
    'webSearchDesc': 'Ассистент найдёт свежие данные (курс, погода, новости), когда вопрос этого требует.',
    'webSearchKeysHint': 'Работает без ключа (DuckDuckGo). Ключ Tavily или Brave — стабильнее и качественнее.',
    'webSearchTavily': 'Tavily API-ключ (необязательно)',
    'webSearchBrave': 'Brave API-ключ (необязательно)',
    'webSearching': '🔎 Ищу в интернете…',
    'vaWakeHeard': 'услышал, говорите!',
    'vaArmed': 'Говорите команду…',
    'vaCmdUnknown': 'Команду не понял',
    'vaStopped': 'Остановлено',
    'vaConfirmTitle': 'Выполнить команду?',
    'vaConfirmBody': 'EVS распознал команду:',
    'cardSecurity': 'Безопасность',
    'cmdThreshold': 'Порог совпадения фразы',
    'cmdThresholdDesc': 'Насколько точно фраза должна совпасть с командой',
    'cmdConfirm': 'Подтверждение перед выполнением',
    'cmdConfirmAlways': 'Всегда',
    'cmdConfirmRisky': 'Только опасные',
    'cmdConfirmNever': 'Никогда',
    'cardCatalog': 'Каталог команд',
    'cmdEmpty': 'Пока нет команд — добавьте первую.',
    'cmdAdd': 'Добавить команду',
    'cmdPhrase': 'Фраза-триггер',
    'cmdValue': 'Значение (путь, URL, действие)',
    'next': 'Далее',
    'cmdWizType': 'Что добавить?',
    'cmdWizProgram': 'Программа',
    'cmdWizFile': 'Файл',
    'cmdWizSite': 'Сайт',
    'cmdWizSystem': 'Система',
    'cmdWizMedia': 'Медиа',
    'cmdSuggest': 'Предложить команды',
    'cmdSuggestTitle': 'Предложенные команды',
    'cmdSuggestScanning': 'Сканирую приложения и подбираю фразы…',
    'cmdSuggestEmpty': 'Не нашлось новых приложений для команд.',
    'cmdSuggestSaveSel': 'Сохранить выбранные',
    'cmdSuggestCollision': 'Фраза уже используется',
    'cmdSuggestFreq': 'часто',
    'cmdSuggestPrivacy':
        'Имена приложений уходят только в вашу локальную модель. Пути берутся из системы, ИИ их не трогает.',
    'cmdSuggestSaved': 'Добавлено команд: {n}',
    'cmdOnboardTitle': 'Голосовые команды для ваших приложений',
    'cmdOnboardBody':
        'EVS может просмотреть установленные приложения и предложить готовые голосовые команды для их запуска. Список можно отредактировать перед сохранением.',
    'cmdOnboardYes': 'Подобрать команды',
    'navRemote': 'Телефоны',
    'navRemoteSub': 'удалённый ввод с телефона',
    'remoteCardListener': 'Удалённый ввод',
    'remoteEnable': 'Принимать команды с телефонов',
    'remoteEnableDesc':
        'Локальный слушатель по Tailscale/LAN. Наружу порт не публикуется; команды принимаются только от привязанных устройств.',
    'remotePort': 'Порт',
    'remoteServerOff': 'Слушатель выключен',
    'remoteServerOn': 'Слушает',
    'remotePortBusy': 'Порт занят — смените порт',
    'remoteAddress': 'Адрес для подключения',
    'remoteResponse': 'Куда отдавать ответ',
    'remoteRespDesktop': 'Озвучивать на десктопе',
    'remoteRespPhone': 'Текст на телефон',
    'remoteRespBoth': 'Оба',
    'remoteCardDevices': 'Подключённые телефоны',
    'remoteNoDevices': 'Пока нет привязанных телефонов',
    'remoteCardAdd': 'Добавить телефон',
    'remotePairCode': 'Код сопряжения',
    'remotePairHint':
        'Введите этот код (или отсканируйте QR) в приложении на телефоне. Действует 5 минут.',
    'remoteNewCode': 'Обновить код',
    'remoteScanQr': 'QR для подключения',
    'remoteUnpair': 'Отвязать',
    'remotePermVoice': 'Голос',
    'remotePermText': 'Текст',
    'remoteOnline': 'в сети',
    'remoteLastSeen': 'был(а) в сети',
    'remoteNever': 'ещё не подключался',
    'remoteEnableFirst': 'Сначала включите приём команд',
    'cmdWizVolume': 'Громкость приложения',
    'volPickApp': 'Приложение (из воспроизводящих сейчас)',
    'volNoSessions':
        'Нет приложений, воспроизводящих звук. Запустите нужное (например, музыку) и обновите список.',
    'volAction': 'Действие',
    'volActSet': 'Установить',
    'volActInc': 'Прибавить',
    'volActDec': 'Убавить',
    'volActMute': 'Заглушить',
    'volActUnmute': 'Вернуть звук',
    'volDefault': 'Значение по умолчанию',
    'cmdWizPickProgram': 'Выберите программу',
    'cmdWizPickExe': 'Выбрать файл вручную…',
    'cmdWizNoPrograms': 'Программы не найдены',
    'cmdWizSearch': 'Поиск…',
    'cmdWizPhrase': 'Фраза-триггер',
    'cmdWizPhraseHint': 'Скажите эту фразу, чтобы выполнить',
    'cmdWizSpeak': 'Фраза для озвучки (необязательно)',
    'cmdWizSpeakHint': 'например: Открываю Яндекс Музыку',
    'sysLock': 'Блокировка экрана',
    'sysSleep': 'Спящий режим',
    'sysVolUp': 'Громкость +',
    'sysVolDown': 'Громкость −',
    'sysMute': 'Без звука',
    'mediaPlay': 'Плей / Пауза',
    'mediaNext': 'Следующий трек',
    'mediaPrev': 'Предыдущий трек',
    'sttTest': 'Тест распознавания',
    'sttTestDesc': 'Произнесите фразу и посмотрите, как её записал распознаватель — удобно, чтобы подобрать фразу-триггер.',
    'sttTestStart': 'Начать тест',
    'sttTestStop': 'Остановить',
    'sttTestHint': 'Скажите что-нибудь — здесь появится распознанный текст…',
    'sttTestClear': 'Очистить',
    'run': 'Запустить',
    'cmdRunTitle': 'Выполнить команду?',
    'cmdRunOk': 'Команда выполнена',
    'cmdRunFail': 'Не удалось выполнить команду',
    'typeApp': 'Приложение',
    'typeFile': 'Файл',
    'typeWeb': 'Сайт',
    'typeSystem': 'Системное',
    'typeMedia': 'Медиа',
    'typeAppVolume': 'Громкость',
    'volNotPlaying': '{app} сейчас не воспроизводит звук',
    'volNoNumber': 'Не расслышал число',
    'volSet': 'Громкость {app}: {N}%',
    'add': 'Добавить',
    'cardConnMode': 'Режим подключения',
    'modeOnDevice': 'Локально на устройстве (on-device)',
    'modeOnDeviceDesc':
        'Модель работает прямо на вашем компьютере. Максимальная приватность, нет зависимости от сети.',
    'modeLocalServer': 'Локальный сервер (Ollama / LAN)',
    'modeLocalServerDesc':
        'Подключение к серверу в локальной сети. Данные не выходят за пределы вашей сети.',
    'modeRemote': 'Удалённый сервер (OpenAI-совместимый)',
    'modeRemoteDesc':
        'Запросы уходят в интернет. Поддерживаются любые OpenAI-совместимые API.',
    'cardModelPick': 'Выбор модели',
    'noModelsYet': 'Нет загруженных моделей — скачайте модель ниже.',
    'modelActive': 'активна',
    'cardGenParams': 'Параметры генерации',
    'temperatureDesc': 'Выше — креативнее, ниже — точнее',
    'topPDesc': 'Вероятностный порог выборки токенов',
    'cardStyle': 'Стиль ответов',
    'formality': 'Формальность',
    'formalLeft': 'Официально',
    'formalRight': 'Дружески',
    'empathy': 'Эмпатия',
    'empathyLeft': 'Нейтрально',
    'empathyRight': 'Высокая',
    'verbosity': 'Многословность',
    'verbosityLeft': 'Лаконично',
    'verbosityRight': 'Подробно',
    'humor': 'Юмор',
    'humorLeft': 'Серьёзно',
    'humorRight': 'С юмором',
    'creativity': 'Креативность',
    'creativityLeft': 'Буквально',
    'creativityRight': 'Творчески',
    'cardAssistant': 'Личность ассистента',
    'assistantNameLabel': 'Имя ассистента',
    'assistantNameDesc': 'Как ассистент будет называть себя',
    'emojiPolicy': 'Политика эмодзи',
    'emojiPolicyDesc': 'Как часто использовать эмодзи в ответах',
    'emojiNever': 'Никогда',
    'emojiSometimes': 'Иногда',
    'emojiAlways': 'Часто',
    'cardMemory': 'Память',
    'autoSaveFacts': 'Автосохранение фактов',
    'autoSaveFactsDesc': 'EVS сам запоминает важные детали из разговора',
    'askBeforeRemember': 'Спрашивать перед «Запомнить»',
    'askBeforeRememberDesc': 'Показывать запрос перед добавлением воспоминания',
    'clearMemory': 'Очистить память',
    'cardCmdScope': 'Область действия команд',
    'permFiles': 'Файлы и папки',
    'permBrowser': 'Браузер и сайты',
    'permMedia': 'Медиа и звук',
    'permSystem': 'Системные настройки',
    'permNetwork': 'Сетевые запросы',
    'permRegistry': 'Реестр Windows',
    'cardNetSec': 'Сетевая безопасность',
    'offlineMode': 'Офлайн-режим',
    'offlineModeDesc': 'Запретить все сетевые запросы (модель + обновления)',
    'noTelemetry': 'Запретить телеметрию',
    'noTelemetryDesc': 'Не отправлять анонимную статистику использования',
    'noModelNet': 'Запретить сетевые запросы модели',
    'noModelNetDesc': 'Только локальный инференс, без API',
    'cardBlacklist': 'Чёрный список фраз',
    'cardData': 'Данные и конфиденциальность',
    'clearHistory': 'Очистить историю чатов',
    'clearHistoryDesc':
        'Удалить все сеансы и переписки без возможности восстановления',
    'resetMemory': 'Сбросить память и профиль',
    'resetMemoryDesc': 'Удалить все воспоминания, профиль пользователя и заметку',
    'resetAll': 'Сбросить все настройки',
    'resetAllDesc': 'Вернуть EVS к заводским настройкам. Действие необратимо.',
    'fullReset': 'Полный сброс',
    'versionLabel': 'Версия',
    'platform': 'Платформа',
    'changelog': 'Список изменений',
    'updates': 'Обновления',
    'autoCheck': 'Автоматическая проверка',
    'autoCheckDesc': 'Проверять обновления при запуске',
    'checkNow': 'Проверить сейчас',
    'checkUpdate': 'Обновить',
    'howCanIHelp': 'Чем могу помочь?',
    'subtitle':
        'Приватный ИИ для письма, планирования, кода и повседневных вопросов.',
    'askAnything': 'Спросите что угодно',
    'summarize': 'Кратко',
    'rewrite': 'Переписать',
    'fixGrammar': 'Грамматика',
    'downloadedModels': 'Доступные модели',
    'manageModels': 'Управление моделями',
    'newChat': 'Новый чат',
    'createImage': 'Создать изображение',
    'createImageHint':
        'Создание изображения — отправьте запрос модели изображений',
    'loadingModels': 'Загрузка моделей…',
    'loadingShort': 'Загрузка',
    'gettingReady': 'Готовим…',
    'loadingYourModel': 'Загружаем модель — секунду.',
    'preparingModel': 'Подготовка модели',
    'noModelsFound': 'Модели не найдены',
    'noModelsAvailable': 'Нет доступных моделей',
    'refreshModels': 'Обновить список моделей',
    'mute': 'Выкл. микрофон',
    'unmute': 'Вкл. микрофон',
    'listening': 'Внимательно слушаю…',
    'preparingMic': 'Подключение микрофона…',
    'micUnavailable': 'Не удалось подключить микрофон',
    'micUnavailableDesc':
        'Проверьте разрешение на запись звука и подключение к интернету, затем попробуйте снова.',
    'retry': 'Повторить',
    'muted': 'Микрофон выключен',
    'micSettingsTitle': 'Настройки микрофона',
    'micAutoSend': 'Автоотправка после паузы',
    'micAutoSendDesc': 'Сообщение отправится само, как только вы замолчите',
    'micPauseDuration': 'Длительность паузы перед отправкой',
    'send': 'Отправить',
    'speakNaturally':
        'Говорите свободно. EVS ответит, как только вы сделаете паузу.',
    'conversations': 'Беседы',
    'chats': 'Чаты',
    'chatsDesc':
        'Здесь хранятся ваши недавние диалоги, готовые продолжиться в любой момент.',
    'chatsLabel': 'ЧАТЫ',
    'pinnedLabel': 'ЗАКРЕПЛЁННЫЕ',
    'latestLabel': 'ПОСЛЕДНИЙ',
    'noChatsYet': 'Чатов пока нет',
    'startFresh': 'Начните новый пустой диалог.',
    'continueSection': 'Продолжить',
    'latestConversation': 'ПОСЛЕДНИЙ ДИАЛОГ',
    'resume': 'Возобновить',
    'recent': 'Недавние',
    'noChatsDesc':
        'Как только вы начнёте общение, история диалогов появится здесь.',
    'startNewChat': 'Начать новый чат',
    'searchChats': 'Поиск по чатам и сообщениям',
    'messages': 'сообщений',
    'pin': 'Закрепить',
    'unpin': 'Открепить',
    'delete': 'Удалить',
    'chatDeleted': 'Чат удалён',
    'undo': 'Отменить',
    'rename': 'Переименовать',
    'renameChat': 'Переименовать чат',
    'renameChatHint': 'Название чата',
    'msgCopy': 'Копировать',
    'msgEdit': 'Редактировать',
    'msgRegenerate': 'Перегенерировать',
    'msgContinue': 'Продолжить',
    'msgUseInComposer': 'Использовать в поле ввода',
    'msgRemember': 'Запомнить',
    'msgForgetMemory': 'Забыть связанное воспоминание',
    'msgPinContext': 'Закрепить в контексте чата',
    'msgUnpinContext': 'Открепить из контекста чата',
    'msgCopied': 'Скопировано',
    'msgRemembered': 'Добавлено в память',
    'msgForgotten': 'Воспоминание забыто',
    'msgPinned': 'Закреплено в контексте чата',
    'msgUnpinned': 'Откреплено из контекста чата',
    'savedMemoriesSection': 'Сохранённые воспоминания',
    'noSavedMemories': 'Пока нет сохранённых воспоминаний.',
    'pinnedMessagesSection': 'Закреплённые сообщения',
    'noPinnedMessages': 'Пока нет закреплённых сообщений.',
    'justNow': 'только что',
    'minAgo': 'мин назад',
    'hAgo': 'ч назад',
    'dAgo': 'дн назад',
    'settings': 'Настройки',
    'settingsDesc':
        'Настройте EVS, управляйте поведением приложения и просматривайте сведения в одном месте.',
    'sectionApp': 'Приложение',
    'sectionTheme': 'Оформление',
    'sectionAbout': 'О приложении',
    'checkForUpdates': 'Проверить обновления',
    'downloadingUpdate': 'Скачивание обновления…',
    'updateAvailable': 'Доступно обновление',
    'upToDate': 'У вас последняя версия',
    'updateCheckFailed': 'Не удалось проверить обновления',
    'updateDownloadFailed': 'Не удалось скачать обновление',
    'downloadUpdateNow': 'Скачать и установить',
    'later': 'Позже',
    'aboutVersion': 'О версии',
    'whatsNewTitle': 'Что нового в версии',
    'gotIt': 'Понятно',
    'manageModelsItem': 'Управление моделями',
    'localModelsItem': 'Локальные модели',
    'localModelsTitle': 'Локальные модели',
    'localModelsDesc':
        'Скачайте модель прямо на устройство и общайтесь с ней без подключения к серверу.',
    'tierLight': 'Лёгкие',
    'tierLightDesc': 'Для слабых/старых телефонов (32-бит ARM, мало ОЗУ)',
    'tierMid': 'Средние',
    'tierMidDesc':
        'Для современных смартфонов среднего класса (например, Honor 70)',
    'tierHigh': 'Мощные',
    'tierHighDesc':
        'Для флагманов с большим запасом ОЗУ (например, iPhone 15 Pro Max)',
    'tierRoleplay': 'Для ролевой игры',
    'tierRoleplayDesc':
        'Файнтюны на ролевых/литературных диалогах, а не только на ассистентских задачах',
    'onDevice': 'на устройстве',
    'downloadModel': 'Скачать',
    'downloadingModel': 'Загрузка…',
    'cancelDownload': 'Отмена',
    'useModel': 'Использовать',
    'modelInUse': 'Используется',
    'deleteModel': 'Удалить',
    'localModelMissing':
        'Файл модели не найден. Скачайте модель ещё раз в разделе «Локальные модели».',
    'modelCrashWarn':
        'Локальная модель вызвала сбой при загрузке и отключена:',
    'deleteLocalModelTitle': 'Удалить модель?',
    'deleteLocalModelBody':
        'Файл модели будет удалён с устройства. Скачать её снова можно в любой момент.',
    'personalization': 'Персонализация',
    'memory': 'Память',
    'rpMode': 'Режим ролевой игры',
    'rpModeOn': 'Режим ролевой игры включён для этого чата',
    'rpModeOff': 'Режим ролевой игры выключен для этого чата',
    'rpEnableDesc':
        'Заменяет обычный системный промпт на персонажа из этой вкладки и фиксирует модель за этим чатом.',
    'stopGeneration': 'Остановить генерацию',
    'tabRoleplay': 'Ролевая игра',
    'rpDesc':
        'Имена персонажей, сценарий, параметры генерации и блокнот мира для этого чата.',
    'rpModelLocked': 'Модель зафиксирована для этого чата',
    'rpModelLockedToast':
        'Модель этого чата зафиксирована при включении режима ролевой игры и не меняется внутри сессии.',
    'rpMyCharacter': 'Мой персонаж',
    'rpMyCharacterDesc': 'Кто вы в этой истории — имя и описание вашего персонажа.',
    'rpAiRole': 'Роль ИИ',
    'rpAiRoleDesc': 'Кем должна быть нейросеть в этом чате — имя и личность персонажа.',
    'rpUserName': 'Ваше имя',
    'rpUserDescription': 'Описание вашего персонажа',
    'rpUserDescriptionDesc':
        'Кто ваш персонаж — внешность, характер, роль в истории. Модель учитывает это, обращаясь к вам, но играет не за вас.',
    'rpUserDescriptionHint':
        'Опишите своего персонажа. Доступны {{user}} и {{char}}.',
    'rpAiName': 'Имя персонажа ИИ',
    'rpScenarioSection': 'Сценарий',
    'systemPrompt': 'Системный промпт / личность персонажа',
    'systemPromptDesc':
        'Главное описание персонажа — голос, характер, манера речи. Заменяет обычный системный промпт личности в этом чате.',
    'rpSystemPromptHint':
        'Опишите персонажа от первого лица. Доступны {{user}} и {{char}}.',
    'rpPlaceholderExampleTitle': 'Пример',
    'rpPlaceholderExample':
        '«Ты — {{char}}, бывалый капитан космического корабля. Ты называешь {{user}} новым членом экипажа и общаешься с ним грубовато, но по-доброму.» При ответе модель сама заменит {{user}} и {{char}} на имена из полей выше.',
    'scenario': 'Сценарий / окружение',
    'scenarioDesc':
        'Вступление и контекст истории — обстановка, в которой начинается диалог.',
    'rpScenarioHint': 'С чего начинается история?',
    'rpSampling': 'Параметры генерации',
    'rpTemperature': 'Температура',
    'rpTemperatureDesc':
        'Выше — более случайные и неожиданные ответы, ниже — более предсказуемые.',
    'rpTopP': 'Top-P',
    'rpTopPDesc':
        'Отсекает менее вероятные варианты слов; меньшее значение — более предсказуемый текст.',
    'rpRepetitionPenalty': 'Штраф за повторение',
    'rpRepetitionPenaltyDesc':
        'Снижает шанс, что модель повторяет одни и те же фразы.',
    'rpMaxTokens': 'Длина ответа',
    'rpMaxTokensDesc': 'Примерный потолок длины одного ответа.',
    'rpPresetShort': 'Коротко (150)',
    'rpPresetMedium': 'Средне (300)',
    'rpPresetLong': 'Роман (600)',
    'rpPresetEpic': 'Эпопея (1000)',
    'rpLorebook': 'Блокнот мира',
    'rpLorebookEnable': 'Блокнот мира (Lorebook)',
    'rpLorebookDesc':
        'Статьи с ключевыми словами подмешиваются в промпт, когда упоминаются в чате.',
    'rpLorebookKeywords': 'Ключевые слова, через запятую',
    'rpLorebookContent': 'Описание для промпта',
    'rpLorebookAddEntry': 'Добавить статью',
    'rpStopSequences': 'Стоп-последовательности',
    'rpStopSequencesDesc':
        'Генерация останавливается, как только модель выводит один из этих фрагментов текста.',
    'rpStopSequenceHint': 'Введите текст и нажмите Enter',
    'rpContextWindow': 'Лимит контекста',
    'rpContextWindowDesc':
        'Сколько последних сообщений чата помещается в запрос к модели за один раз.',
    'rpContextFull':
        'Контекст этого чата почти заполнен — можно сжать старую историю в краткое резюме.',
    'rpCompressButton': 'Сжать память чата',
    'language': 'Язык',
    'serverAddress': 'Адрес сервера',
    'showKeyboard': 'Клавиатура при запуске',
    'haptics': 'Виброотклик',
    'themeMode': 'Тема',
    'themeSystem': 'Системная',
    'themeLight': 'Светлая',
    'themeDark': 'Тёмная',
    'themeClaude': 'Claude',
    'themeClaudeDark': 'Claude (тёмная)',
    'themeGray': 'Серая',
    'appStyle': 'Стиль приложения',
    'appStyleDialogTitle': 'Стиль приложения',
    'appStyleStandard': 'Обычный',
    'appStyleGlass': 'Liquid Glass',
    'showChips': 'Показывать подсказки',
    'fontSize': 'Размер шрифта',
    'deleteHistory': 'Удалить историю диалогов',
    'terms': 'Условия использования',
    'privacy': 'Политика конфиденциальности',
    'licenses': 'Лицензии',
    'cantUndo': 'Это действие нельзя отменить.',
    'cancel': 'Отмена',
    'save': 'Сохранить',
    'done': 'Готово',
    'reset': 'Сбросить',
    'serverDialogTitle': 'Подключение к нейросети',
    'serverUrlLabel': 'Адрес (IP:порт или https://...)',
    'serverUrlHint': 'например 192.168.1.100:11434 или https://api.site.com',
    'apiKeyOptional': 'API-ключ (необязательно)',
    'languageDialogTitle': 'Выбор языка',
    'russian': 'Русский',
    'english': 'English',
    'addModelHint': 'Добавьте модель вручную',
    'attachFile': 'Прикрепить файл',
    'fileAttached': 'Файл прикреплён',
    'imageNotSupportedWarning':
        'Эта модель не понимает изображения — увидит только имя файла.',
    'recentPhotos': 'Недавние',
    'noRecentPhotos': 'Нет недавних фото',
    'photoAccessDenied':
        'Нет доступа к галерее. Разрешите доступ к фото в настройках устройства.',
    'attachTabGallery': 'Галерея',
    'attachTabFile': 'Файл',
    'serverError': 'Ошибка сервера',
    'unreachable': 'Не удалось подключиться к серверу',
    'checkAddress': 'Проверьте адрес в настройках.',
    'pers': 'Персонализация',
    'chatPers': 'Настройки этого чата',
    'tabPersonality': 'Личность',
    'tabMemory': 'Память',
    'persDesc': 'Настройте личность, поведение и контекст ассистента под себя.',
    'memoryDesc':
        'Управляйте тем, что EVS запоминает о вас, и сколько контекста диалога видят локальные модели.',
    'persPersona': 'Личность и стиль общения',
    'persPreset': 'Готовая персона',
    'persPresetDesc':
        'Шаблон стиля общения — мгновенно подстраивает черты характера и тон ниже.',
    'preset_friend': 'Лучший друг',
    'preset_mentor': 'Наставник / Коуч',
    'preset_expert': 'Эксперт',
    'preset_creative': 'Креативный партнёр',
    'preset_custom': 'Свой стиль',
    'slidersTitle': 'Черты характера',
    'sl_formality': 'Формальность',
    'sl_formalityDesc': 'Насколько официально или непринуждённо звучит ответ.',
    'sl_empathy': 'Эмпатия',
    'sl_empathyDesc': 'Тёплый и поддерживающий тон — или сухой и по делу.',
    'sl_verbosity': 'Детализация',
    'sl_verbosityDesc':
        'Подробные объяснения — или короткие ответы по существу.',
    'sl_humor': 'Юмор',
    'sl_humorDesc': 'Насколько уместны шутки и игривость.',
    'sl_creativity': 'Креативность',
    'sl_creativityDesc':
        'Привычные ответы — или нестандартные идеи и сравнения.',
    'speechStyle': 'Стиль речи',
    'emojiUsage': 'Эмодзи',
    'emojiUsageDesc': 'Как часто в ответах появляются эмодзи.',
    'emoji_never': 'Никогда',
    'emoji_sometimes': 'Иногда',
    'emoji_always': 'Всегда',
    'answerFormat': 'Формат ответов',
    'answerFormatDesc':
        'Обычный текст, списки или таблицы, когда это подходит по смыслу.',
    'fmt_plain': 'Обычный текст',
    'fmt_lists': 'Списки',
    'fmt_tables': 'Таблицы где можно',
    'persBehavior': 'Функциональность и поведение',
    'defaultLength': 'Длина ответа по умолчанию',
    'defaultLengthDesc': 'Целевая длина ответа, если вы не уточнили иначе.',
    'len_short': 'Короткая',
    'len_normal': 'Стандартная',
    'len_long': 'Развёрнутая',
    'proactivity': 'Проактивность',
    'proactivityDesc':
        'Отвечать только на вопрос, переспрашивать при неясности или предлагать смежные темы.',
    'pro_answer': 'Только отвечать',
    'pro_clarify': 'Задавать уточнения',
    'pro_suggest': 'Предлагать темы',
    'useMarkdown': 'Использовать markdown-разметку',
    'useMarkdownDesc': 'Заголовки, списки и выделение текста в ответах.',
    'memorySection': 'Память и контекст',
    'longMemory': 'Долговременная память',
    'longMemoryDesc': 'Учитывать заметку ниже при ответах ассистента.',
    'memoryNote': 'Запомни обо мне, что…',
    'autoSaveMemories': 'Автосохранение полезных деталей',
    'autoSaveMemoriesDesc':
        'После каждого ответа тихо спрашивать модель, стоит ли запомнить что-то устойчивое: предпочтения, факты профиля, текущие задачи.',
    'askBeforeRemembering': 'Спрашивать перед сохранением',
    'askBeforeRememberingDesc':
        'Выбирать категорию воспоминания при сохранении сообщения вручную.',
    'deleteAllMemories': 'Удалить все воспоминания',
    'deleteAllMemoriesDesc': 'Очистить все сохранённые воспоминания на устройстве.',
    'deleteAllMemoriesConfirm':
        'Все сохранённые воспоминания будут удалены без возможности восстановления.',
    'chooseMemoryCategory': 'Выберите категорию воспоминания',
    'memCatPreference': 'Предпочтение',
    'memCatProfile': 'Профиль',
    'memCatProject': 'Проект',
    'memCatOther': 'Другое',
    'contextSize': 'Размер контекста',
    'contextSizeDesc':
        'Сколько диалога помнит локальная модель. Больше — лучше память, но выше нагрузка на устройство и медленнее ответы.',
    'contextSizeMaxFor': 'Максимум для',
    'contextSizeMaxForDevice': 'Максимум для этого устройства',
    'contextSizeMovedToRp':
        'Для этого чата размер контекста настраивается во вкладке «Ролевая игра» — там же, где лимит контекста и параметры генерации.',
    'persProfile': 'О вас',
    'name': 'Имя',
    'pronouns': 'Местоимения',
    'profession': 'Профессия',
    'interests': 'Интересы и хобби',
    'goals': 'Цели',
    'useMyData': 'Использовать мои данные для ответов',
    'useMyDataDesc': 'Имя, профессия, интересы и другие поля из этого раздела.',
    'knowledgeLevel': 'Уровень знаний',
    'kl_beginner': 'Новичок',
    'kl_student': 'Студент',
    'kl_expert': 'Эксперт',
    'location': 'Местоположение (город / часовой пояс)',
    'persSafety': 'Безопасность и границы',
    'avoidTopics': 'Темы для избегания',
    'contentFilter': 'Фильтр контента',
    'cf_strict': 'Строгий',
    'cf_balanced': 'Сбалансированный',
    'cf_off': 'Без фильтра',
    'warnUncertain': 'Предупреждать о неуверенности и чувствительных темах',
    'warnUncertainDesc': 'Честно говорить, когда ассистент не уверен в ответе.',
    'localDataTitle': 'Персонализация хранится локально на устройстве',
    'localDataDesc':
        'Имя, заметки и настройки личности не уходят на сервер — они используются только для построения промпта, который видит модель.',
    'persAdvanced': 'Продвинутые настройки',
    'reasoning': 'Стиль мышления',
    'reasoningDesc':
        'Отвечать сразу или сначала рассуждать пошагово, показывая ход мысли.',
    'rs_fast': 'Быстрый и интуитивный',
    'rs_step': 'Пошаговое рассуждение',
    'toneTitle': 'Тон в тексте',
    'toneTitleDesc': 'Общая эмоциональная окраска текста ответов.',
    'tone_neutral': 'Нейтральный',
    'tone_sarcastic': 'Саркастичный',
    'tone_melancholic': 'Меланхоличный',
    'tone_excited': 'Восторженный',
    'customPrompt': 'Свой системный промпт',
    'customPromptDesc':
        'Добавляется в конец системного промпта — для правил, которых нет среди настроек выше.',
    'customPromptHint': 'Прямая инструкция ассистенту…',
  },
  'en': {
    'appName': 'EVS',
    // EVS desktop UI
    'yesterday': 'Yesterday',
    'microphone': 'Microphone',
    'ready': 'Ready',
    'micListening': 'Listening',
    'apiKeyHint': 'API key (if required)',
    'statusLocalModel': 'Local model',
    'statusRemoteModel': 'Remote model',
    'statusOnline': 'online',
    'statusConnected': 'connected',
    'statusConnecting': 'connecting…',
    'statusNoModel': 'no model selected',
    'statusDisconnected': 'not connected',
    'statusError': 'connection error',
    'statusTitle': 'Model status',
    'modelField': 'Model',
    'serverField': 'Server',
    'navGeneral': 'General',
    'navGeneralSub': 'application settings',
    'navVoiceInput': 'Voice input',
    'navVoiceInputSub': 'recognition & microphone',
    'navVoiceCommands': 'Voice commands',
    'navVoiceCommandsSub': 'computer control',
    'navModel': 'Model & inference',
    'navModelSub': 'neural net & connection',
    'navPersona': 'Personality & memory',
    'navPersonaSub': 'assistant personalization',
    'navPrivacy': 'Privacy',
    'navPrivacySub': 'data & access',
    'navAbout': 'About',
    'navAboutSub': 'version & updates',
    'sectionStub': 'Section under construction — settings coming soon.',
    'cardLangLoc': 'Language & localization',
    'interfaceLanguage': 'Interface language',
    'interfaceLanguageDesc': 'Language of menus, buttons and notifications',
    'recognitionLanguage': 'Recognition language (STT)',
    'recognitionLanguageDesc': 'Defaults to the interface language',
    'sttAuto': 'Auto',
    'cardAppearance': 'Appearance',
    'appStyleDesc': 'Liquid Glass — blur and acrylic effects',
    'styleClassic': 'Classic',
    'fontSizeDesc': 'Affects font and element sizes',
    'cardStartup': 'Startup & behavior',
    'autostart': 'Launch at startup',
    'autostartDesc': 'Start EVS when you sign in',
    'minimizeToTray': 'Minimize to tray',
    'minimizeToTrayDesc': 'Hide to the tray icon when minimized',
    'closeToTray': 'Close to tray',
    'closeToTrayDesc': 'Closing the window hides to tray instead of quitting',
    'globalHotkey': 'Global hotkey',
    'globalHotkeyDesc': 'Show the EVS window from any application',
    'trayShow': 'Show EVS',
    'trayQuit': 'Quit',
    'notifications': 'Notifications',
    'notificationsDesc': 'Show Windows system notifications',
    'uiAnimations': 'UI animations',
    'uiAnimationsDesc': 'Smooth transitions and effects',
    'sidecar': 'Voice engine (Python)',
    'sidecarDesc': 'Separate EVS process for Whisper, VAD and TTS',
    'sidecarConnected': 'Connected',
    'sidecarStarting': 'Starting…',
    'sidecarStopped': 'Stopped',
    'sidecarComponent': 'Engine component',
    'sidecarComponentDesc': 'Downloaded separately (not in the installer)',
    'download': 'Download',
    'componentReady': 'Installed',
    'componentVerifying': 'Verifying…',
    'cardStt': 'STT engine',
    'sttEngine': 'Recognition engine',
    'sttEngineDesc': 'The local engine (Whisper/GigaAM) runs offline on your hardware',
    'localEngineName': 'Local (EVS)',
    'msShort': 'ms',
    'cardSttModel': 'Local engine',
    'engWhisperName': 'Whisper',
    'engWhisperShort': 'Multilingual, average accuracy',
    'engGigaamName': 'GigaAM-v3',
    'engGigaamShort': 'Best accuracy for Russian. Recommended',
    'moreDetails': 'More',
    'lessDetails': 'Less',
    'checkConn': 'Check connection',
    'connChecking': 'Checking…',
    'connOnline': 'Connected',
    'connModelsCount': 'models',
    'connBadUrl': 'Enter the server address above',
    'refreshModelsBtn': 'Refresh list',
    'cardPresets': 'Quick profiles',
    'presetsDesc':
        'One tap sets several options at once. Fine-tune below afterwards.',
    'presetFast': 'Fast',
    'presetFastDesc': 'CPU · light denoise · no web search',
    'presetQuality': 'Quality',
    'presetQualityDesc': 'GPU · strong denoise',
    'presetSearch': 'Search',
    'presetSearchDesc': 'Web search on',
    'presetChat': 'Chat',
    'presetChatDesc': 'Web search off',
    'presetApplied': 'Profile applied: {name}',
    'modelPerMode': 'Model per mode',
    'modelPerModeDesc':
        'Separate models for search and ordinary chat. The search model is used '
            'when live web results are pulled into the answer.',
    'modelForSearch': 'For search',
    'modelForChat': 'For chat',
    'modelDefaultGlobal': 'As selected globally',
    'modelNotOnServer': 'not on server',
    'cardLlmAdv': 'Advanced',
    'llmAdvDesc': 'Request parameters for the model. A blank field is not sent '
        'at all — the model\'s own default applies.',
    'llmNumCtx': 'Context size',
    'llmNumCtxDesc': 'num_ctx — how many tokens the model keeps in context',
    'llmNumPredict': 'Response limit',
    'llmNumPredictDesc': 'num_predict — maximum response length in tokens',
    'llmTemp': 'Temperature',
    'llmTempDesc': 'temperature — 0 is predictable, higher is freer (0–1.5)',
    'llmKeepAlive': 'Keep model loaded',
    'llmKeepAliveDesc': 'keep_alive — e.g. 30m, or -1 to never unload',
    'llmDefaultHint': 'default',
    'llmBadNumber': 'Must be a number',
    'llmTempRange': 'Allowed 0–1.5',
    'engWhisperDetail':
        'Understands many languages, but recognizes short Russian commands worse than GigaAM. Slower on long phrases — it processes audio in 30-second windows. base and tiny are lighter and faster but less accurate — for weak hardware.',
    'engGigaamDetail':
        'Trained specifically on Russian speech; confidently recognizes short commands. ~300 MB on disk, ~0.6–1 GB RAM, ~0.1–0.3 s latency. Russian only.',
    'dnOffDetail':
        'The microphone is passed through untouched. Good for a quiet room and a decent mic; costs nothing.',
    'dnLightDetail':
        'GTCRN — a lightweight neural net: removes constant noise (fans, hum) and some sharp sounds. ~10 ms latency, negligible CPU.',
    'dnStrongDetail':
        'DeepFilterNet — a heavier model: suppresses keyboard, music, conversations. Noticeably more CPU and needs a model download (~8 MB). Use it when light suppression is not enough.',
    'engActive': 'Active',
    'engReady': 'Ready',
    'engLoading': 'Loading…',
    'engNotFound': 'Model not found',
    'engSwitchFailed': 'Could not switch engine',
    'engWhisperSize': 'Model size',
    'cardModels': 'Models',
    'mdlInstalled': 'Installed',
    'mdlNotInstalled': 'Not installed',
    'mdlDownload': 'Download',
    'mdlOpenFolder': 'Open models folder',
    'mdlRamShort': 'MB RAM',
    'mdlActiveCantDelete': "Can't delete the active model",
    'mdlDeleteConfirm': 'Delete this model from disk?',
    'mdlDelete': 'Delete',
    'mbShort': 'MB',
    'mdlTotalDisk': 'Disk used',
    'cardDenoise': 'Noise suppression',
    'mdlAdd': 'Add',
    'deviceLabel': 'Processing',
    'deviceCpu': 'CPU',
    'deviceGpu': 'GPU',
    'deviceHintWhisper': 'On the GPU, Whisper is much faster on long phrases.',
    'deviceFellBack': 'Could not use the GPU — running on the CPU.',
    'cardGameMode': 'Game mode',
    'gmFullscreen': 'Game mode',
    'gmFullscreenDesc': 'Move GPU engines to the CPU while a fullscreen game is up',
    'gmVram': 'Watch video memory',
    'gmVramDesc': 'Offload the GPU when VRAM is nearly full (needs NVIDIA)',
    'gmVramEnter': 'Engage threshold',
    'gmVramExit': 'Release threshold',
    'gmNotify': 'Voice notification',
    'gmNotifyDesc': 'Speak on entering/leaving offload; the badge stays regardless',
    'gmExclusions': 'Exclusions',
    'gmExclusionsDesc': 'Processes that are fullscreen but not games (video player, etc.)',
    'gmExclAdd': 'Add process',
    'gmOffloadActive': 'GPU offload is active — engines are on the CPU.',
    'gmOffloadBadge': 'GPU offload',
    'gmReasonFullscreen': 'fullscreen mode',
    'gmReasonVram': 'video memory full',
    'gmNotifyFullscreen': 'Fullscreen mode detected — switching to the processor',
    'gmNotifyVram': 'Video memory is nearly full — switching to the processor',
    'gmNotifyExit': 'Restoring settings',
    'extraMics': 'Additional microphones',
    'extraMicsDesc': 'Listen on several microphones at once (e.g. in different rooms). One phrase heard by several runs only once.',
    'micSelfCleaningHint': 'This microphone has its own noise suppression — the built-in one is off so audio isn\'t processed twice.',
    'dnOff': 'Off',
    'dnLight': 'Light',
    'dnStrong': 'Strong',
    'dnOffShort': 'Mic as-is — for a quiet room and a good microphone.',
    'dnLightShort':
        'Removes background noise, barely uses resources. Recommended.',
    'dnStrongShort':
        'Maximum suppression: keyboard, music, chatter. Heavier on CPU.',
    'dnNotInstalled': 'Model not downloaded — open the Models section.',
    'whisperOffline': 'Whisper (offline)',
    'whisperModel': 'Whisper model',
    'whisperModelDesc':
        'Affects quality and speed. Warning: medium takes ~a minute per '
            'utterance on CPU — the assistant will feel dead. Small is recommended',
    'cardInputDevice': 'Input device',
    'inputDevice': 'Input device',
    'inputDeviceDesc': 'Microphone used for recording',
    'defaultDevice': 'Default',
    'micTest': 'Microphone test',
    'micTestDesc': 'Check the level and signal quality',
    'runTest': 'Run test',
    'inputLevel': 'Input signal level',
    'cardListenMode': 'Listening mode',
    'activationMode': 'Activation mode',
    'activationModeDesc': 'Push-to-talk requires holding a key',
    'continuous': 'Continuous',
    'autoSendPause': 'Auto-send on pause',
    'autoSendPauseDesc': 'Send text automatically after silence',
    'pauseDuration': 'Pause duration',
    'pauseDurationDesc': 'How many seconds of silence end a phrase',
    'secShort': 's',
    'showPartial': 'Show partial text',
    'showPartialDesc': 'Display recognized text live while speaking',
    'cardVoiceViz': 'Voice visualization',
    'vizType': 'Visualization type',
    'vizTypeDesc': 'Animation reacting to your voice level',
    'vizSphere': 'Sphere',
    'vizWaves': 'Waves',
    'vizBars': 'Bars',
    'vizNone': 'None',
    'navWidgets': 'Widgets',
    'navWidgetsSub': 'visualization & overlay',
    'cardWsPreview': 'Preview',
    'cardWsStyle': 'Widget style',
    'cardWsParams': 'Parameters',
    'vizOrb': 'Siri Orb',
    'vizLkBars': 'Stripes',
    'vizWave3d': 'Waves 3D',
    'vizWaveFlat': 'Particle field',
    'settingsUnsaved': 'You have unsaved changes',
    'settingsSaved': 'Settings applied and saved',
    'settingsSaveFailed': 'Could not apply settings. Previous values restored',
    'settingsExitTitle': 'Save changes?',
    'settingsExitSave': 'Save',
    'settingsExitDiscard': "Don't save",
    'settingsExitStay': 'Stay',
    'wsAccent': 'Accent color',
    'wsAccentDesc': 'Color of the Siri Orb and Stripes',
    'wsOrbSize': 'Orb size',
    'wsOrbSpeed': 'Rotation speed',
    'wsOrbSpeedDesc': 'Seconds per full turn',
    'wsFast': 'fast',
    'wsSlow': 'slow',
    'wsBarCount': 'Number of bars',
    'wsSimVoice': 'Voice simulation',
    'wsStateIdle': 'Idle',
    'wsStateListening': 'Listening',
    'wsStateSpeaking': 'Speaking',
    'wsStateThinking': 'Thinking',
    'ovlEnter': 'Floating widget',
    'ovlEnterDesc':
        'The visualization in a small transparent always-on-top window. '
            'Double-click the widget to return to the chat',
    'ovlShow': 'Show the widget',
    'ovlSize': 'Widget size',
    'ovlSizeDesc': 'Size of the floating visualization window',
    'ovlSizeS': 'Small',
    'ovlSizeM': 'Medium',
    'ovlSizeL': 'Large',
    'ovlOpenChat': 'Open EVS',
    'ovlHide': 'Hide widget',
    'trayOverlay': 'Floating widget',
    'showVizBg': 'Show in background',
    'showVizBgDesc': 'Display the visualization on the home screen',
    'cardVoiceResp': 'Voice response',
    'voiceResponses': 'Speak responses',
    'voiceResponsesDesc': 'Read the assistant\'s replies aloud',
    'announceReady': 'Announce readiness',
    'announceReadyDesc': 'Say aloud when the assistant is ready to listen',
    'ttsEngineTitle': 'Voice engine',
    'ttsEnginePiper': 'Piper',
    'ttsEnginePiperHint': 'fast, offline, CPU',
    'ttsEngineCosy': 'CosyVoice',
    'ttsEngineCosyHint': 'quality, GPU',
    'ttsCosyUnavailable': 'CosyVoice unavailable — server not responding',
    'ttsCosyEndpoint': 'CosyVoice endpoint',
    'ttsCosyCheck': 'Check connection',
    'ttsCosyOnline': 'Online',
    'ttsCosyOffline': 'Not responding',
    'ttsCosyFellBack': 'CosyVoice unavailable — switched to Piper',
    'ttsCosyChecking': 'Checking…',
    'ttsCosyWiringHint':
        'Settings are saved. CosyVoice synthesis connects once the server is deployed.',
    'ttsCosyVoice': 'Voice / preset',
    'ttsCosyVoiceHint': 'Preset id (spk_id) — for SFT models. Optional.',
    'ttsCosyClone': 'Clone from sample',
    'ttsCosyClonePick': 'Choose WAV…',
    'ttsCosyCloneNone': 'No sample chosen',
    'ttsCosyClonePrompt': 'Text in the sample',
    'ttsCosyClonePromptHint': 'What is spoken in the WAV sample (needed for cloning).',
    'ttsCosySpeed': 'Speed',
    'ttsCosyEmotion': 'Emotion',
    'ttsCosyEmotionNeutral': 'Neutral',
    'ttsCosyEmotionHappy': 'Happy',
    'ttsCosyEmotionSad': 'Sad',
    'ttsCosyEmotionSerious': 'Serious',
    'ttsCosyEmotionCalm': 'Calm',
    'ttsCosyEmotionExcited': 'Excited',
    'ttsCosyInstruct': 'Instruction (free text)',
    'ttsCosyInstructHint': 'Your own style/emotion instruction — overrides the preset.',
    'ttsCosyDevice': 'Synthesis device',
    'ttsInterp': 'Speech interpreter',
    'ttsInterpDesc':
        'Rewrites text into a speakable form before synthesis: numbers and dates '
            'as words, no emoji or markup.',
    'ttsInterpRules': 'Rules',
    'ttsInterpRulesHint': 'Fast, offline',
    'ttsInterpModel': 'Via model',
    'ttsInterpModelHint': 'More accurate but slower, needs a server',
    'ttsInterpModelField': 'Interpreter model',
    'ttsInterpFellBack':
        'Interpreter model unavailable — speaking with rules.',
    'readyGreeting': 'Ready to listen',
    'sttStarting': 'Starting…',
    'sttLoadingModels': 'Loading models…',
    'sttReadyMsg': 'Ready to listen',
    'sttErrorState': 'Speech engine failed to start',
    'ttsRate': 'Speech rate',
    'ttsRateDesc': 'Speaking tempo',
    'ttsVolume': 'Volume',
    'cardAssistantVoice': 'Assistant voice',
    'voiceSystemName': 'System voice (no download)',
    'voiceSystemDesc': 'Sounds robotic, but works instantly — no downloads.',
    'voiceListen': 'Listen',
    'voiceSelect': 'Select',
    'voiceSamplePhrase': 'Hello! I am EVS, your voice assistant.',
    'voiceIrina': 'Female voice, medium quality (Piper).',
    'voiceDenis': 'Male voice, medium quality (Piper).',
    'voiceDmitri': 'Male voice, medium quality (Piper).',
    'voiceRuslan': 'Male voice, medium quality (Piper).',
    'cardCmdExec': 'Command execution',
    'cmdAllow': 'Allow command execution',
    'cmdAllowDesc':
        'EVS can launch apps, open sites and control the system',
    'cardCmdRecognition': 'Command recognition',
    'cmdMode': 'Recognition mode',
    'cmdModeDesc': 'How EVS tells a command apart from dictation',
    'cmdModeWake': 'Wake word',
    'cmdModeSeparate': 'Separate mode',
    'cmdModeFirst': 'Command first',
    'cmdActivator': 'Wake word',
    'cmdActivatorDesc': 'Say “EVS” before a command, e.g. “EVS, open browser”',
    'cmdStopWords': 'Stop words',
    'cmdStopWordsDesc': 'Comma-separated. Interrupt speech and generation (e.g. “stop, cancel, quiet”)',
    'saveServerBtn': 'Save address',
    'vaListening': 'Listening…',
    'vaThinking': 'Thinking…',
    'vaRunning': 'Running…',
    'vaDone': 'Done',
    'vaFailed': 'Could not run the command',
    'vaCmdDisabled': 'Command recognized, but execution is off (enable "Allow command execution")',
    'vaCmdNotFound': 'Command not found',
    'chatToggle': 'Chat',
    'chatToggleDesc': 'Turn off for commands only: an unrecognized phrase won\'t go to chat, it answers "Command not found". Text input is disabled too.',
    'chatDisabledHint': 'Chat is off — voice commands only',
    'vaSttOffline': 'Voice engine not connected',
    'updRestart': 'Restart',
    'updUpToDate': 'Up to date',
    'updReadyShort': 'Update',
    'updFlowDesc': 'Downloads in the background — just restart to apply',
    'updAvailableTitle': 'Update available',
    'updDialogHint': 'The update is already downloaded. Restart EVS to apply.',
    'updLater': 'Later',
    'updFailedApply': 'The update did not install. Fully close EVS and try again.',
    'updApplied': 'EVS updated to {v}',
    'updFailedManual': 'Auto-update to {v} did not install. Download the installer manually.',
    'updDownloadManual': 'Download',
    'webSearch': 'Web search',
    'webSearchEnable': 'Search the web',
    'webSearchDesc': 'The assistant fetches fresh info (rates, weather, news) when a question needs it.',
    'webSearchKeysHint': 'Works without a key (DuckDuckGo). A Tavily or Brave key is more reliable and higher quality.',
    'webSearchTavily': 'Tavily API key (optional)',
    'webSearchBrave': 'Brave API key (optional)',
    'webSearching': '🔎 Searching the web…',
    'vaWakeHeard': 'heard you, go ahead!',
    'vaArmed': 'Say the command…',
    'vaCmdUnknown': 'Could not understand the command',
    'vaStopped': 'Stopped',
    'vaConfirmTitle': 'Run command?',
    'vaConfirmBody': 'EVS recognized a command:',
    'cardSecurity': 'Security',
    'cmdThreshold': 'Phrase match threshold',
    'cmdThresholdDesc': 'How closely a phrase must match a command',
    'cmdConfirm': 'Confirm before running',
    'cmdConfirmAlways': 'Always',
    'cmdConfirmRisky': 'Risky only',
    'cmdConfirmNever': 'Never',
    'cardCatalog': 'Command catalog',
    'cmdEmpty': 'No commands yet — add the first one.',
    'cmdAdd': 'Add command',
    'cmdPhrase': 'Trigger phrase',
    'cmdValue': 'Value (path, URL, action)',
    'next': 'Next',
    'cmdWizType': 'What to add?',
    'cmdWizProgram': 'Program',
    'cmdWizFile': 'File',
    'cmdWizSite': 'Website',
    'cmdWizSystem': 'System',
    'cmdWizMedia': 'Media',
    'cmdSuggest': 'Suggest commands',
    'cmdSuggestTitle': 'Suggested commands',
    'cmdSuggestScanning': 'Scanning apps and drafting phrases…',
    'cmdSuggestEmpty': 'No new apps to make commands for.',
    'cmdSuggestSaveSel': 'Save selected',
    'cmdSuggestCollision': 'Phrase already in use',
    'cmdSuggestFreq': 'frequent',
    'cmdSuggestPrivacy':
        'Only app names go to your local model. Paths come from the system; the AI never touches them.',
    'cmdSuggestSaved': 'Commands added: {n}',
    'cmdOnboardTitle': 'Voice commands for your apps',
    'cmdOnboardBody':
        'EVS can look through your installed apps and suggest ready-made voice commands to launch them. You can edit the list before saving.',
    'cmdOnboardYes': 'Suggest commands',
    'navRemote': 'Phones',
    'navRemoteSub': 'remote input from a phone',
    'remoteCardListener': 'Remote input',
    'remoteEnable': 'Accept commands from phones',
    'remoteEnableDesc':
        'Local listener over Tailscale/LAN. The port is not exposed to the internet; only paired devices may send commands.',
    'remotePort': 'Port',
    'remoteServerOff': 'Listener off',
    'remoteServerOn': 'Listening',
    'remotePortBusy': 'Port is busy — change it',
    'remoteAddress': 'Connection address',
    'remoteResponse': 'Where to send the reply',
    'remoteRespDesktop': 'Speak on desktop',
    'remoteRespPhone': 'Text back to phone',
    'remoteRespBoth': 'Both',
    'remoteCardDevices': 'Connected phones',
    'remoteNoDevices': 'No paired phones yet',
    'remoteCardAdd': 'Add a phone',
    'remotePairCode': 'Pairing code',
    'remotePairHint':
        'Enter this code (or scan the QR) in the phone app. Valid for 5 minutes.',
    'remoteNewCode': 'New code',
    'remoteScanQr': 'QR to connect',
    'remoteUnpair': 'Unpair',
    'remotePermVoice': 'Voice',
    'remotePermText': 'Text',
    'remoteOnline': 'online',
    'remoteLastSeen': 'last seen',
    'remoteNever': 'never connected',
    'remoteEnableFirst': 'Enable command receiving first',
    'cmdWizVolume': 'App volume',
    'volPickApp': 'App (from those playing now)',
    'volNoSessions':
        'No apps are playing sound. Start one (e.g. music) and refresh the list.',
    'volAction': 'Action',
    'volActSet': 'Set',
    'volActInc': 'Increase',
    'volActDec': 'Decrease',
    'volActMute': 'Mute',
    'volActUnmute': 'Unmute',
    'volDefault': 'Default value',
    'cmdWizPickProgram': 'Pick a program',
    'cmdWizPickExe': 'Choose a file manually…',
    'cmdWizNoPrograms': 'No programs found',
    'cmdWizSearch': 'Search…',
    'cmdWizPhrase': 'Trigger phrase',
    'cmdWizPhraseHint': 'Say this phrase to run it',
    'cmdWizSpeak': 'Phrase to speak (optional)',
    'cmdWizSpeakHint': 'e.g. Opening Yandex Music',
    'sysLock': 'Lock screen',
    'sysSleep': 'Sleep',
    'sysVolUp': 'Volume +',
    'sysVolDown': 'Volume −',
    'sysMute': 'Mute',
    'mediaPlay': 'Play / Pause',
    'mediaNext': 'Next track',
    'mediaPrev': 'Previous track',
    'sttTest': 'Recognition test',
    'sttTestDesc': 'Say a phrase and see how the recognizer wrote it — handy for designing a trigger phrase.',
    'sttTestStart': 'Start test',
    'sttTestStop': 'Stop',
    'sttTestHint': 'Say something — the recognized text appears here…',
    'sttTestClear': 'Clear',
    'run': 'Run',
    'cmdRunTitle': 'Run this command?',
    'cmdRunOk': 'Command executed',
    'cmdRunFail': 'Command failed',
    'typeApp': 'App',
    'typeFile': 'File',
    'typeWeb': 'Site',
    'typeSystem': 'System',
    'typeMedia': 'Media',
    'typeAppVolume': 'Volume',
    'volNotPlaying': '{app} is not playing any sound right now',
    'volNoNumber': "I didn't catch a number",
    'volSet': '{app} volume: {N}%',
    'add': 'Add',
    'cardConnMode': 'Connection mode',
    'modeOnDevice': 'On-device (local)',
    'modeOnDeviceDesc':
        'The model runs right on your PC. Maximum privacy, no network dependency.',
    'modeLocalServer': 'Local server (Ollama / LAN)',
    'modeLocalServerDesc':
        'Connect to a server on your local network. Data stays inside your network.',
    'modeRemote': 'Remote server (OpenAI-compatible)',
    'modeRemoteDesc':
        'Requests go to the internet. Any OpenAI-compatible API is supported.',
    'cardModelPick': 'Model selection',
    'noModelsYet': 'No downloaded models — download one below.',
    'modelActive': 'active',
    'cardGenParams': 'Generation parameters',
    'temperatureDesc': 'Higher — more creative, lower — more precise',
    'topPDesc': 'Probability threshold for token sampling',
    'cardStyle': 'Reply style',
    'formality': 'Formality',
    'formalLeft': 'Formal',
    'formalRight': 'Friendly',
    'empathy': 'Empathy',
    'empathyLeft': 'Neutral',
    'empathyRight': 'High',
    'verbosity': 'Verbosity',
    'verbosityLeft': 'Concise',
    'verbosityRight': 'Detailed',
    'humor': 'Humor',
    'humorLeft': 'Serious',
    'humorRight': 'Playful',
    'creativity': 'Creativity',
    'creativityLeft': 'Literal',
    'creativityRight': 'Creative',
    'cardAssistant': 'Assistant personality',
    'assistantNameLabel': 'Assistant name',
    'assistantNameDesc': 'What the assistant calls itself',
    'emojiPolicy': 'Emoji policy',
    'emojiPolicyDesc': 'How often to use emoji in replies',
    'emojiNever': 'Never',
    'emojiSometimes': 'Sometimes',
    'emojiAlways': 'Often',
    'cardMemory': 'Memory',
    'autoSaveFacts': 'Auto-save facts',
    'autoSaveFactsDesc': 'EVS remembers important details from the conversation',
    'askBeforeRemember': 'Ask before “Remember”',
    'askBeforeRememberDesc': 'Show a prompt before adding a memory',
    'clearMemory': 'Clear memory',
    'cardCmdScope': 'Command scope',
    'permFiles': 'Files & folders',
    'permBrowser': 'Browser & sites',
    'permMedia': 'Media & sound',
    'permSystem': 'System settings',
    'permNetwork': 'Network requests',
    'permRegistry': 'Windows registry',
    'cardNetSec': 'Network security',
    'offlineMode': 'Offline mode',
    'offlineModeDesc': 'Block all network requests (model + updates)',
    'noTelemetry': 'Disable telemetry',
    'noTelemetryDesc': 'Do not send anonymous usage statistics',
    'noModelNet': 'Disable model network',
    'noModelNetDesc': 'Local inference only, no API',
    'cardBlacklist': 'Phrase blacklist',
    'cardData': 'Data & privacy',
    'clearHistory': 'Clear chat history',
    'clearHistoryDesc': 'Delete all sessions and chats permanently',
    'resetMemory': 'Reset memory & profile',
    'resetMemoryDesc': 'Delete all memories, the user profile and the note',
    'resetAll': 'Reset all settings',
    'resetAllDesc': 'Return EVS to factory defaults. This cannot be undone.',
    'fullReset': 'Full reset',
    'versionLabel': 'Version',
    'platform': 'Platform',
    'changelog': 'Changelog',
    'updates': 'Updates',
    'autoCheck': 'Automatic check',
    'autoCheckDesc': 'Check for updates on launch',
    'checkNow': 'Check now',
    'checkUpdate': 'Update',
    'howCanIHelp': 'How can I help?',
    'subtitle':
        'Private AI for writing, planning, coding, and everyday questions.',
    'askAnything': 'Ask anything',
    'summarize': 'Summarize',
    'rewrite': 'Rewrite',
    'fixGrammar': 'Fix Grammar',
    'downloadedModels': 'Downloaded Models',
    'manageModels': 'Manage Models',
    'newChat': 'New Chat',
    'createImage': 'Create Image',
    'createImageHint': 'Create Image — send a request to an image model',
    'loadingModels': 'Loading models…',
    'loadingShort': 'Loading',
    'gettingReady': 'Getting ready…',
    'loadingYourModel': 'Loading your model — just a moment.',
    'preparingModel': 'Preparing model',
    'noModelsFound': 'No models found',
    'noModelsAvailable': 'No models available',
    'refreshModels': 'Refresh model list',
    'mute': 'Mute',
    'unmute': 'Unmute',
    'listening': 'Listening carefully…',
    'preparingMic': 'Connecting microphone…',
    'micUnavailable': 'Couldn\'t connect to the microphone',
    'micUnavailableDesc':
        'Check the microphone permission and your internet connection, then try again.',
    'retry': 'Retry',
    'muted': 'Muted',
    'micSettingsTitle': 'Microphone settings',
    'micAutoSend': 'Auto-send after pause',
    'micAutoSendDesc': 'The message sends itself as soon as you go quiet',
    'micPauseDuration': 'Pause duration before sending',
    'send': 'Send',
    'speakNaturally':
        'Speak naturally. EVS will respond as soon as you pause.',
    'conversations': 'Conversations',
    'chats': 'Chats',
    'chatsDesc':
        'Your recent work lives here, ready to resume whenever you are.',
    'chatsLabel': 'CHATS',
    'pinnedLabel': 'PINNED',
    'latestLabel': 'LATEST',
    'noChatsYet': 'No chats yet',
    'startFresh': 'Start fresh with an empty thread.',
    'continueSection': 'Continue',
    'latestConversation': 'LATEST CONVERSATION',
    'resume': 'Resume',
    'recent': 'Recent',
    'noChatsDesc':
        'Once you start chatting, your local conversation history will show up here.',
    'startNewChat': 'Start New Chat',
    'searchChats': 'Search chats and messages',
    'messages': 'messages',
    'pin': 'Pin',
    'unpin': 'Unpin',
    'delete': 'Delete',
    'chatDeleted': 'Chat deleted',
    'undo': 'Undo',
    'rename': 'Rename',
    'renameChat': 'Rename chat',
    'renameChatHint': 'Chat name',
    'msgCopy': 'Copy',
    'msgEdit': 'Edit',
    'msgRegenerate': 'Regenerate',
    'msgContinue': 'Continue',
    'msgUseInComposer': 'Use in composer',
    'msgRemember': 'Remember this',
    'msgForgetMemory': 'Forget related memory',
    'msgPinContext': 'Pin to chat context',
    'msgUnpinContext': 'Unpin from chat context',
    'msgCopied': 'Copied',
    'msgRemembered': 'Added to memory',
    'msgForgotten': 'Memory forgotten',
    'msgPinned': 'Pinned to chat context',
    'msgUnpinned': 'Unpinned from chat context',
    'savedMemoriesSection': 'Saved memories',
    'noSavedMemories': 'No saved memories yet.',
    'pinnedMessagesSection': 'Pinned messages',
    'noPinnedMessages': 'No pinned messages yet.',
    'justNow': 'just now',
    'minAgo': 'm ago',
    'hAgo': 'h ago',
    'dAgo': 'd ago',
    'settings': 'Settings',
    'settingsDesc':
        'Personalize EVS, manage device behavior, and review the app details in one place.',
    'sectionApp': 'App',
    'sectionTheme': 'Theme',
    'sectionAbout': 'About',
    'checkForUpdates': 'Check for updates',
    'downloadingUpdate': 'Downloading update…',
    'updateAvailable': 'Update available',
    'upToDate': 'You have the latest version',
    'updateCheckFailed': 'Failed to check for updates',
    'updateDownloadFailed': 'Failed to download update',
    'downloadUpdateNow': 'Download and install',
    'later': 'Later',
    'aboutVersion': 'About version',
    'whatsNewTitle': "What's new in version",
    'gotIt': 'Got it',
    'manageModelsItem': 'Manage models',
    'localModelsItem': 'Local models',
    'localModelsTitle': 'Local models',
    'localModelsDesc':
        'Download a model straight to your device and chat with it without a server connection.',
    'tierLight': 'Light',
    'tierLightDesc': 'For weak/older phones (32-bit ARM, low RAM)',
    'tierMid': 'Mid-range',
    'tierMidDesc': 'For modern mid-range smartphones (e.g. Honor 70)',
    'tierHigh': 'High-end',
    'tierHighDesc': 'For flagships with plenty of RAM (e.g. iPhone 15 Pro Max)',
    'tierRoleplay': 'For roleplay',
    'tierRoleplayDesc':
        'Fine-tunes trained on roleplay/creative-writing dialogue, not just assistant tasks',
    'onDevice': 'on-device',
    'downloadModel': 'Download',
    'downloadingModel': 'Downloading…',
    'cancelDownload': 'Cancel',
    'useModel': 'Use',
    'modelInUse': 'In use',
    'deleteModel': 'Delete',
    'localModelMissing':
        'Model file not found. Download it again from the Local models screen.',
    'modelCrashWarn': 'A local model crashed on load and was disabled:',
    'deleteLocalModelTitle': 'Delete this model?',
    'deleteLocalModelBody':
        'The model file will be removed from your device. You can download it again anytime.',
    'personalization': 'Personalization',
    'memory': 'Memory',
    'rpMode': 'Roleplay mode',
    'rpModeOn': 'Roleplay mode is on for this chat',
    'rpModeOff': 'Roleplay mode is off for this chat',
    'rpEnableDesc':
        "Replaces the regular system prompt with the character from this tab and locks the model to this chat.",
    'stopGeneration': 'Stop generating',
    'tabRoleplay': 'Roleplay',
    'rpDesc':
        'Character names, scenario, generation settings, and the world lorebook for this chat.',
    'rpModelLocked': 'Model is locked for this chat',
    'rpModelLockedToast':
        "This chat's model was locked in when roleplay mode turned on and can't change within the session.",
    'rpMyCharacter': 'My character',
    'rpMyCharacterDesc': 'Who you are in this story — your character\'s name and description.',
    'rpAiRole': "AI's role",
    'rpAiRoleDesc': "Who the AI should be in this chat — the character's name and personality.",
    'rpUserName': 'Your name',
    'rpUserDescription': 'Your character description',
    'rpUserDescriptionDesc':
        'Who your character is — appearance, personality, role in the story. The model takes this into account when addressing you, but does not play as you.',
    'rpUserDescriptionHint':
        'Describe your character. {{user}} and {{char}} are available.',
    'rpAiName': "AI character's name",
    'rpScenarioSection': 'Scenario',
    'systemPrompt': 'System prompt / character personality',
    'systemPromptDesc':
        "The character's core description — voice, personality, way of speaking. Replaces the regular personality system prompt for this chat.",
    'rpSystemPromptHint':
        'Describe the character in first person. {{user}} and {{char}} are available.',
    'rpPlaceholderExampleTitle': 'Example',
    'rpPlaceholderExample':
        '"You are {{char}}, a grizzled starship captain. You call {{user}} the crew\'s newest recruit and speak to them gruffly but warmly." The model will replace {{user}} and {{char}} with the names from the fields above.',
    'scenario': 'Scenario / setting',
    'scenarioDesc':
        'The opening context for the story — the setting the conversation starts in.',
    'rpScenarioHint': 'How does the story begin?',
    'rpSampling': 'Generation settings',
    'rpTemperature': 'Temperature',
    'rpTemperatureDesc':
        'Higher makes replies more random and surprising; lower makes them more predictable.',
    'rpTopP': 'Top-P',
    'rpTopPDesc':
        'Cuts off unlikely word choices; a lower value makes the text more predictable.',
    'rpRepetitionPenalty': 'Repetition penalty',
    'rpRepetitionPenaltyDesc':
        'Lowers the chance the model repeats the same phrases.',
    'rpMaxTokens': 'Reply length',
    'rpMaxTokensDesc': 'Roughly how long a single reply is allowed to be.',
    'rpPresetShort': 'Short (150)',
    'rpPresetMedium': 'Medium (300)',
    'rpPresetLong': 'Novel (600)',
    'rpPresetEpic': 'Epic (1000)',
    'rpLorebook': 'Lorebook',
    'rpLorebookEnable': 'World lorebook',
    'rpLorebookDesc':
        "Entries get mixed into the prompt when their keywords show up in chat.",
    'rpLorebookKeywords': 'Keywords, comma-separated',
    'rpLorebookContent': 'Description for the prompt',
    'rpLorebookAddEntry': 'Add entry',
    'rpStopSequences': 'Stop sequences',
    'rpStopSequencesDesc':
        "Generation stops as soon as the model outputs one of these snippets.",
    'rpStopSequenceHint': 'Type text and press Enter',
    'rpContextWindow': 'Context window limit',
    'rpContextWindowDesc':
        'How many recent messages from this chat fit into a single request to the model.',
    'rpContextFull':
        "This chat's context is almost full — you can compress the older history into a summary.",
    'rpCompressButton': 'Compress chat memory',
    'language': 'Language',
    'serverAddress': 'Server address',
    'showKeyboard': 'Show keyboard on launch',
    'haptics': 'Haptics',
    'themeMode': 'Theme',
    'themeSystem': 'System',
    'themeLight': 'Light',
    'themeDark': 'Dark',
    'themeClaude': 'Claude',
    'themeClaudeDark': 'Claude (dark)',
    'themeGray': 'Gray',
    'appStyle': 'App style',
    'appStyleDialogTitle': 'App style',
    'appStyleStandard': 'Standard',
    'appStyleGlass': 'Liquid Glass',
    'showChips': 'Show prompt chips',
    'fontSize': 'Font size',
    'deleteHistory': 'Delete conversation history',
    'terms': 'Terms & Conditions',
    'privacy': 'Privacy Policy',
    'licenses': 'Licenses',
    'cantUndo': 'This cannot be undone.',
    'cancel': 'Cancel',
    'save': 'Save',
    'done': 'Done',
    'reset': 'Reset',
    'serverDialogTitle': 'AI connection',
    'serverUrlLabel': 'Address (IP:port or https://...)',
    'serverUrlHint': 'e.g. 192.168.1.100:11434 or https://api.site.com',
    'apiKeyOptional': 'API key (optional)',
    'languageDialogTitle': 'Select language',
    'russian': 'Русский',
    'english': 'English',
    'addModelHint': 'Add model manually',
    'attachFile': 'Attach file',
    'fileAttached': 'File attached',
    'imageNotSupportedWarning':
        "This model can't understand images — it will only see the file name.",
    'recentPhotos': 'Recent',
    'noRecentPhotos': 'No recent photos',
    'photoAccessDenied':
        "No access to your photos. Allow photo access in the device settings.",
    'attachTabGallery': 'Gallery',
    'attachTabFile': 'File',
    'serverError': 'Server error',
    'unreachable': 'Could not reach the server',
    'checkAddress': 'Check the address in Settings.',
    'pers': 'Personalization',
    'chatPers': 'This chat\'s settings',
    'tabPersonality': 'Personality',
    'tabMemory': 'Memory',
    'persDesc': "Tailor the assistant's personality, behavior and context.",
    'memoryDesc':
        "Control what EVS remembers about you, and how much conversation context local models can see.",
    'persPersona': 'Character & vibe',
    'persPreset': 'Persona preset',
    'persPresetDesc':
        'A style template — instantly adjusts the traits and tone below.',
    'preset_friend': 'Best friend',
    'preset_mentor': 'Mentor / Coach',
    'preset_expert': 'Expert',
    'preset_creative': 'Creative partner',
    'preset_custom': 'Custom',
    'slidersTitle': 'Character traits',
    'sl_formality': 'Formality',
    'sl_formalityDesc': 'How formal or casual the answer sounds.',
    'sl_empathy': 'Empathy',
    'sl_empathyDesc': 'A warm, supportive tone — or a dry, businesslike one.',
    'sl_verbosity': 'Detail',
    'sl_verbosityDesc':
        'Detailed explanations — or short, to-the-point replies.',
    'sl_humor': 'Humor',
    'sl_humorDesc': 'How much room there is for jokes and playfulness.',
    'sl_creativity': 'Creativity',
    'sl_creativityDesc':
        'Conventional answers — or unconventional ideas and comparisons.',
    'speechStyle': 'Speech style',
    'emojiUsage': 'Emoji',
    'emojiUsageDesc': 'How often emoji show up in replies.',
    'emoji_never': 'Never',
    'emoji_sometimes': 'Sometimes',
    'emoji_always': 'Always',
    'answerFormat': 'Answer format',
    'answerFormatDesc': 'Plain text, lists, or tables, whichever fits the content.',
    'fmt_plain': 'Plain text',
    'fmt_lists': 'Lists',
    'fmt_tables': 'Tables when possible',
    'persBehavior': 'Functionality & behavior',
    'defaultLength': 'Default answer length',
    'defaultLengthDesc':
        'Target reply length unless you ask for something different.',
    'len_short': 'Short',
    'len_normal': 'Standard',
    'len_long': 'Detailed',
    'proactivity': 'Proactivity',
    'proactivityDesc':
        'Answer only what was asked, ask clarifying questions, or suggest related topics.',
    'pro_answer': 'Answer only',
    'pro_clarify': 'Ask clarifying questions',
    'pro_suggest': 'Suggest related topics',
    'useMarkdown': 'Use markdown formatting',
    'useMarkdownDesc': 'Headings, lists, and emphasis in responses.',
    'memorySection': 'Memory & context',
    'longMemory': 'Long-term memory',
    'longMemoryDesc': "Factor the note below into the assistant's answers.",
    'memoryNote': 'Remember about me that…',
    'autoSaveMemories': 'Auto-save useful details',
    'autoSaveMemoriesDesc':
        'After every reply, quietly ask the model whether anything stable is worth remembering: preferences, profile details, ongoing projects.',
    'askBeforeRemembering': 'Ask before remembering',
    'askBeforeRememberingDesc':
        'Choose a memory category when you save a message manually.',
    'deleteAllMemories': 'Delete all memories',
    'deleteAllMemoriesDesc': 'Clear every saved memory from this device.',
    'deleteAllMemoriesConfirm':
        'All saved memories will be permanently deleted.',
    'chooseMemoryCategory': 'Choose a memory category',
    'memCatPreference': 'Preference',
    'memCatProfile': 'Profile',
    'memCatProject': 'Project',
    'memCatOther': 'Other',
    'contextSize': 'Context size',
    'contextSizeDesc':
        "How much of the conversation the local model remembers. Higher means better memory, but more load on the device and slower replies.",
    'contextSizeMaxFor': 'Maximum for',
    'contextSizeMaxForDevice': 'Maximum for this device',
    'contextSizeMovedToRp':
        'For this chat, context size is configured in the "Roleplay" tab — alongside the context limit and generation settings.',
    'persProfile': 'About you',
    'name': 'Name',
    'pronouns': 'Pronouns',
    'profession': 'Profession',
    'interests': 'Interests & hobbies',
    'goals': 'Goals',
    'useMyData': 'Use my data to improve answers',
    'useMyDataDesc': 'Name, profession, interests, and the other fields below.',
    'knowledgeLevel': 'Knowledge level',
    'kl_beginner': 'Beginner',
    'kl_student': 'Student',
    'kl_expert': 'Expert',
    'location': 'Location (city / timezone)',
    'persSafety': 'Safety & limits',
    'avoidTopics': 'Topics to avoid',
    'contentFilter': 'Content filter',
    'cf_strict': 'Strict',
    'cf_balanced': 'Balanced',
    'cf_off': 'No filter',
    'warnUncertain': 'Warn on uncertainty and sensitive topics',
    'warnUncertainDesc': "Be upfront when the assistant isn't sure.",
    'localDataTitle': 'Personalization is stored locally on this device',
    'localDataDesc':
        "Your name, notes, and personality settings never leave the device — they're only used to build the prompt the model sees.",
    'persAdvanced': 'Advanced',
    'reasoning': 'Reasoning style',
    'reasoningDesc':
        'Answer right away, or think step by step and show the reasoning.',
    'rs_fast': 'Fast & intuitive',
    'rs_step': 'Step-by-step reasoning',
    'toneTitle': 'Text tone',
    'toneTitleDesc': 'Overall emotional flavor of the reply text.',
    'tone_neutral': 'Neutral',
    'tone_sarcastic': 'Sarcastic',
    'tone_melancholic': 'Melancholic',
    'tone_excited': 'Excited',
    'customPrompt': 'Custom system prompt',
    'customPromptDesc':
        "Appended to the end of the system prompt — for rules not covered by the settings above.",
    'customPromptHint': 'Direct instruction to the assistant…',
  },
};

/* ============================ МОДЕЛИ ДАННЫХ ============================ */

class ChatMessage {
  final String id;
  final String role;
  // Mutable so a streaming reply can grow this in place (see
  // AppState.sendMessageStreaming) instead of replacing the message object
  // on every chunk.
  String content;
  final DateTime time;
  final List<String> attachments;
  ChatMessage({
    String? id,
    required this.role,
    required this.content,
    DateTime? time,
    List<String>? attachments,
  }) : id = id ?? const Uuid().v4(),
       time = time ?? DateTime.now(),
       attachments = attachments ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'content': content,
    'time': time.toIso8601String(),
    'attachments': attachments,
  };
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: j['id'] as String?,
    role: j['role'] as String? ?? 'user',
    content: j['content'] as String? ?? '',
    time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
    attachments:
        (j['attachments'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [],
  );
}

class Conversation {
  final String id;
  String title;
  bool pinned;
  DateTime updatedAt;
  List<ChatMessage> messages;
  Personalization? persona;
  List<String> pinnedMessageIds;
  // Opt-in per-chat mode for roleplay-oriented features (currently: live
  // streaming with a Stop Generation button instead of waiting silently for
  // the full reply). Off by default so the existing chat flow is untouched
  // unless the user explicitly turns it on for a given conversation.
  bool rpModeEnabled;
  // RP-specific settings for this chat (character names, system prompt,
  // sampling, lorebook, locked model...) — nullable and cloned-while-editing
  // the same way persona is; only ever non-null once rpModeEnabled has been
  // turned on at least once for this conversation.
  RPSessionConfig? rpConfig;

  Conversation({
    required this.id,
    required this.title,
    this.pinned = false,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    this.persona,
    List<String>? pinnedMessageIds,
    this.rpModeEnabled = false,
    this.rpConfig,
  }) : updatedAt = updatedAt ?? DateTime.now(),
       messages = messages ?? [],
       pinnedMessageIds = pinnedMessageIds ?? [];

  // Pinned messages stay part of the prompt for every reply in this chat,
  // no matter how long the conversation grows — appended after the regular
  // personalization prompt so it isn't buried/ignored like the rest.
  String pinnedContextBlock() {
    final pinnedMsgs = messages.where((m) => pinnedMessageIds.contains(m.id));
    if (pinnedMsgs.isEmpty) return '';
    final b = StringBuffer('Pinned context — always keep this in mind:\n');
    for (final m in pinnedMsgs) {
      b.writeln('- ${m.content}');
    }
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'pinned': pinned,
    'updatedAt': updatedAt.toIso8601String(),
    'messages': messages.map((m) => m.toJson()).toList(),
    'persona': persona?.toJson(),
    'pinnedMessageIds': pinnedMessageIds,
    'rpModeEnabled': rpModeEnabled,
    'rpConfig': rpConfig?.toJson(),
  };
  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    id: j['id'] as String? ?? '',
    title: j['title'] as String? ?? '',
    pinned: j['pinned'] as bool? ?? false,
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    messages:
        (j['messages'] as List<dynamic>?)
            ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [],
    persona: j['persona'] is Map<String, dynamic>
        ? Personalization.fromJson(j['persona'] as Map<String, dynamic>)
        : null,
    pinnedMessageIds:
        (j['pinnedMessageIds'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [],
    rpModeEnabled: j['rpModeEnabled'] as bool? ?? false,
    rpConfig: j['rpConfig'] is Map<String, dynamic>
        ? RPSessionConfig.fromJson(j['rpConfig'] as Map<String, dynamic>)
        : null,
  );
}

class Personalization {
  Personalization();

  String preset = 'preset_custom';
  double formality = 0.5;
  double empathy = 0.5;
  double verbosity = 0.5;
  double humor = 0.3;
  double creativity = 0.5;
  String emoji = 'emoji_sometimes';
  String answerFormat = 'fmt_plain';
  String defaultLength = 'len_normal';
  String proactivity = 'pro_clarify';
  bool useMarkdown = true;
  bool longMemory = true;
  String memoryNote = '';
  // Individual snippets saved via the "Remember this" action on a chat
  // message, as opposed to memoryNote which is one freeform note the user
  // types by hand.
  List<String> savedMemories = [];
  bool askBeforeRemembering = true;
  // When on, after every assistant reply a small silent follow-up request
  // asks the same model to extract one durable fact worth remembering (or
  // "NONE"), so savedMemories grows without the user tapping "Remember".
  bool autoSaveMemories = true;
  String name = '';
  String pronouns = '';
  String profession = '';
  String interests = '';
  String goals = '';
  bool useMyData = true;
  String knowledgeLevel = 'kl_student';
  String location = '';
  String avoidTopics = '';
  String contentFilter = 'cf_balanced';
  bool warnUncertain = true;
  String reasoning = 'rs_fast';
  String tone = 'tone_neutral';
  String customPrompt = '';
  // Name the assistant refers to itself by (used at the top of the system
  // prompt). Editable in the desktop Personality settings; defaults to EVS.
  String assistantName = 'EVS';
  // Effective context window (in tokens) handed to local on-device models.
  // fllama internally hardcodes n_parallel=4 and splits the requested
  // contextSize across 4 slots, so callers must request 4x this value to
  // actually get this much usable context — see _sendLocalMessage.
  int localContextSize = 2048;

  Map<String, dynamic> toJson() => {
    'preset': preset,
    'formality': formality,
    'empathy': empathy,
    'verbosity': verbosity,
    'humor': humor,
    'creativity': creativity,
    'emoji': emoji,
    'answerFormat': answerFormat,
    'defaultLength': defaultLength,
    'proactivity': proactivity,
    'useMarkdown': useMarkdown,
    'longMemory': longMemory,
    'memoryNote': memoryNote,
    'savedMemories': savedMemories,
    'askBeforeRemembering': askBeforeRemembering,
    'autoSaveMemories': autoSaveMemories,
    'name': name,
    'pronouns': pronouns,
    'profession': profession,
    'interests': interests,
    'goals': goals,
    'useMyData': useMyData,
    'knowledgeLevel': knowledgeLevel,
    'location': location,
    'avoidTopics': avoidTopics,
    'contentFilter': contentFilter,
    'warnUncertain': warnUncertain,
    'reasoning': reasoning,
    'tone': tone,
    'customPrompt': customPrompt,
    'assistantName': assistantName,
    'localContextSize': localContextSize,
  };

  factory Personalization.fromJson(Map<String, dynamic> j) {
    final p = Personalization();
    p.preset = (j['preset'] as String?) ?? p.preset;
    p.formality = (j['formality'] as num?)?.toDouble() ?? p.formality;
    p.empathy = (j['empathy'] as num?)?.toDouble() ?? p.empathy;
    p.verbosity = (j['verbosity'] as num?)?.toDouble() ?? p.verbosity;
    p.humor = (j['humor'] as num?)?.toDouble() ?? p.humor;
    p.creativity = (j['creativity'] as num?)?.toDouble() ?? p.creativity;
    p.emoji = (j['emoji'] as String?) ?? p.emoji;
    p.answerFormat = (j['answerFormat'] as String?) ?? p.answerFormat;
    p.defaultLength = (j['defaultLength'] as String?) ?? p.defaultLength;
    p.proactivity = (j['proactivity'] as String?) ?? p.proactivity;
    p.useMarkdown = (j['useMarkdown'] as bool?) ?? p.useMarkdown;
    p.longMemory = (j['longMemory'] as bool?) ?? p.longMemory;
    p.memoryNote = (j['memoryNote'] as String?) ?? p.memoryNote;
    p.savedMemories =
        (j['savedMemories'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        p.savedMemories;
    p.askBeforeRemembering =
        (j['askBeforeRemembering'] as bool?) ?? p.askBeforeRemembering;
    p.autoSaveMemories =
        (j['autoSaveMemories'] as bool?) ?? p.autoSaveMemories;
    p.name = (j['name'] as String?) ?? p.name;
    p.pronouns = (j['pronouns'] as String?) ?? p.pronouns;
    p.profession = (j['profession'] as String?) ?? p.profession;
    p.interests = (j['interests'] as String?) ?? p.interests;
    p.goals = (j['goals'] as String?) ?? p.goals;
    p.useMyData = (j['useMyData'] as bool?) ?? p.useMyData;
    p.knowledgeLevel = (j['knowledgeLevel'] as String?) ?? p.knowledgeLevel;
    p.location = (j['location'] as String?) ?? p.location;
    p.avoidTopics = (j['avoidTopics'] as String?) ?? p.avoidTopics;
    p.contentFilter = (j['contentFilter'] as String?) ?? p.contentFilter;
    p.warnUncertain = (j['warnUncertain'] as bool?) ?? p.warnUncertain;
    p.reasoning = (j['reasoning'] as String?) ?? p.reasoning;
    p.tone = (j['tone'] as String?) ?? p.tone;
    p.customPrompt = (j['customPrompt'] as String?) ?? p.customPrompt;
    p.assistantName = (j['assistantName'] as String?) ?? p.assistantName;
    p.localContextSize =
        (j['localContextSize'] as num?)?.toInt() ?? p.localContextSize;
    return p;
  }

  Personalization clone() => Personalization.fromJson(toJson());

  void applyPreset(String preset) {
    this.preset = preset;
    switch (preset) {
      case 'preset_friend':
        formality = 0.15;
        empathy = 0.8;
        verbosity = 0.4;
        humor = 0.8;
        creativity = 0.6;
        emoji = 'emoji_always';
        tone = 'tone_excited';
        break;
      case 'preset_mentor':
        formality = 0.5;
        empathy = 0.7;
        verbosity = 0.6;
        humor = 0.3;
        creativity = 0.5;
        emoji = 'emoji_sometimes';
        proactivity = 'pro_clarify';
        tone = 'tone_neutral';
        break;
      case 'preset_expert':
        formality = 0.9;
        empathy = 0.2;
        verbosity = 0.7;
        humor = 0.05;
        creativity = 0.2;
        emoji = 'emoji_never';
        answerFormat = 'fmt_lists';
        tone = 'tone_neutral';
        break;
      case 'preset_creative':
        formality = 0.3;
        empathy = 0.6;
        verbosity = 0.6;
        humor = 0.7;
        creativity = 0.95;
        emoji = 'emoji_sometimes';
        tone = 'tone_excited';
        break;
    }
  }

  // Plain declarative sentences instead of a dense "name: X; pronouns: Y; ..."
  // list — small/mid local models tend to skim past or ignore facts packed
  // into one compressed key:value sentence, but pick up on short individual
  // statements much more reliably (the same reason buildLocalSystemPrompt
  // below uses plain sentences for tone/emoji instead of a directive line).
  void _writeProfileFacts(StringBuffer b) {
    if (name.isNotEmpty) b.writeln("The user's name is $name.");
    if (pronouns.isNotEmpty) {
      b.writeln("The user's pronouns are $pronouns.");
    }
    if (profession.isNotEmpty) b.writeln('The user works as $profession.');
    if (interests.isNotEmpty) {
      b.writeln('The user is interested in $interests.');
    }
    if (goals.isNotEmpty) b.writeln("The user's goal: $goals.");
    if (location.isNotEmpty) b.writeln('The user is located in $location.');
  }

  void _writeMemoryFacts(StringBuffer b) {
    if (!longMemory) return;
    if (memoryNote.isNotEmpty) {
      b.writeln('Remember about the user: $memoryNote');
    }
    for (final mem in savedMemories) {
      b.writeln('Also remember: $mem');
    }
  }

  // Same reasoning as _writeProfileFacts: one sentence per trait that's
  // actually away from the neutral middle, instead of a single dense
  // "Style: formality medium, empathy medium, ..." line — models were
  // visibly ignoring the personality sliders entirely with the old format.
  //
  // Thresholds at 0.4/0.6 (not 0.33/0.66) and a second, stronger tier past
  // 0.15/0.85 — the old 0.33-0.66 dead zone covered the sliders' own 0.5
  // default, so a moderate drag in either direction produced no directive
  // at all and the setting looked like it did nothing.
  void _writeStyleFacts(StringBuffer b) {
    if (formality >= 0.85) {
      b.writeln('Write very formally, like an official document.');
    } else if (formality >= 0.6) {
      b.writeln('Write formally and professionally.');
    } else if (formality < 0.15) {
      b.writeln('Write very casually, like texting a close friend; slang is fine.');
    } else if (formality < 0.4) {
      b.writeln('Write casually and informally, like talking to a friend.');
    }
    if (empathy >= 0.85) {
      b.writeln('Be deeply warm and emotionally supportive; validate feelings.');
    } else if (empathy >= 0.6) {
      b.writeln('Be warm and emotionally supportive in your responses.');
    } else if (empathy < 0.15) {
      b.writeln('Be strictly factual and blunt; skip emotional commentary entirely.');
    } else if (empathy < 0.4) {
      b.writeln(
        'Stay matter-of-fact and businesslike, without emotional commentary.',
      );
    }
    if (verbosity >= 0.85) {
      b.writeln('Give thorough, in-depth answers with examples and context.');
    } else if (verbosity >= 0.6) {
      b.writeln('Elaborate with extra detail and explanation.');
    } else if (verbosity < 0.15) {
      b.writeln('Be extremely terse; answer in as few words as possible.');
    } else if (verbosity < 0.4) {
      b.writeln('Be concise; avoid unnecessary elaboration.');
    }
    if (humor >= 0.85) {
      b.writeln('Be consistently witty and playful; jokes are welcome often.');
    } else if (humor >= 0.6) {
      b.writeln('Feel free to be playful and use humor.');
    } else if (humor < 0.15) {
      b.writeln('Stay strictly serious; do not joke at all.');
    } else if (humor < 0.4) {
      b.writeln('Keep a serious tone, avoid jokes.');
    }
    if (creativity >= 0.85) {
      b.writeln('Favor bold, unconventional ideas and unexpected angles.');
    } else if (creativity >= 0.6) {
      b.writeln('Be imaginative and creative in how you answer.');
    } else if (creativity < 0.15) {
      b.writeln('Stick strictly to the safest, most conventional answer.');
    } else if (creativity < 0.4) {
      b.writeln('Stick to straightforward, conventional answers.');
    }
  }

  String buildSystemPrompt() {
    final b = StringBuffer();
    final who = assistantName.trim().isEmpty ? 'EVS' : assistantName.trim();
    b.writeln('You are $who, a helpful AI assistant.');

    _writeStyleFacts(b);

    b.writeln(
      emoji == 'emoji_never'
          ? 'Never use emoji.'
          : emoji == 'emoji_always'
          ? 'Use emoji frequently.'
          : 'Use emoji occasionally.',
    );

    if (answerFormat == 'fmt_lists') {
      b.writeln('Prefer structured bullet lists.');
    } else if (answerFormat == 'fmt_tables') {
      b.writeln('Use tables whenever data fits a table.');
    }

    b.writeln(
      defaultLength == 'len_short'
          ? 'Keep answers very short (max 2 sentences).'
          : defaultLength == 'len_long'
          ? 'Give detailed, thorough answers.'
          : 'Give standard-length answers.',
    );

    if (proactivity == 'pro_clarify') {
      b.writeln('Ask clarifying questions when the task is unclear.');
    } else if (proactivity == 'pro_suggest') {
      b.writeln('Proactively suggest interesting related topics.');
    } else {
      b.writeln('Only answer what is asked.');
    }

    if (useMarkdown) b.writeln('Use markdown formatting.');

    b.writeln(
      'Reasoning: ${reasoning == 'rs_step' ? 'think step by step and show your reasoning' : 'answer directly and intuitively'}.',
    );

    if (tone != 'tone_neutral') {
      b.writeln('Overall tone of text: ${tone.replaceFirst('tone_', '')}.');
    }

    if (useMyData) {
      _writeProfileFacts(b);
      b.writeln(
        'Explain things at a ${knowledgeLevel.replaceFirst('kl_', '')} level.',
      );
    }

    _writeMemoryFacts(b);

    if (avoidTopics.isNotEmpty) {
      b.writeln('Avoid these topics: $avoidTopics.');
    }
    b.writeln(
      contentFilter == 'cf_strict'
          ? 'Apply a strict safety filter; block adult and violent content.'
          : contentFilter == 'cf_off'
          ? 'Minimal content filtering for an adult, private conversation.'
          : 'Apply a balanced content filter.',
    );
    if (warnUncertain) {
      b.writeln(
        'Warn the user when you are uncertain or the topic is sensitive (medical, financial, legal).',
      );
    }

    if (customPrompt.trim().isNotEmpty) {
      b.writeln('Additional user instruction: ${customPrompt.trim()}');
    }
    return b.toString();
  }

  // Small on-device models reliably break down when given the full
  // multi-directive prompt above (formality/empathy/verbosity/tone/etc.) —
  // they tend to start mimicking its "key: value" structure instead of
  // actually answering. Keep only what's simple enough for them to follow
  // and important enough to be worth the tokens.
  String buildLocalSystemPrompt() {
    final b = StringBuffer();
    b.writeln(
      'You are EVS, a helpful assistant. Answer naturally and directly.',
    );
    if (defaultLength == 'len_short') {
      b.writeln('Keep answers short.');
    } else if (defaultLength == 'len_long') {
      b.writeln('Give detailed answers.');
    }
    _writeStyleFacts(b);
    if (emoji == 'emoji_never') {
      b.writeln('Never use emoji.');
    } else if (emoji == 'emoji_always') {
      b.writeln('Use emoji frequently.');
    }
    if (tone != 'tone_neutral') {
      final toneWord = switch (tone) {
        'tone_sarcastic' => 'sarcastic',
        'tone_melancholic' => 'melancholic',
        'tone_excited' => 'excited and energetic',
        _ => null,
      };
      if (toneWord != null) b.writeln('Write in a $toneWord tone.');
    }
    if (useMyData) _writeProfileFacts(b);
    _writeMemoryFacts(b);
    if (avoidTopics.isNotEmpty) {
      b.writeln('Avoid these topics: $avoidTopics.');
    }
    if (contentFilter == 'cf_strict') {
      b.writeln('Avoid adult and violent content.');
    }
    if (customPrompt.trim().isNotEmpty) {
      b.writeln('Additional instruction: ${customPrompt.trim()}');
    }
    return b.toString();
  }

  // "Never use emoji" is a plain-language system-prompt instruction like
  // every other personality setting, but unlike formality/tone/verbosity it
  // has a hard, checkable answer (an emoji is either there or it isn't) —
  // and models reliably keep using emoji anyway when earlier turns in the
  // same chat already established that pattern, no matter how the system
  // prompt is worded. So for this one setting only, enforce it directly on
  // the model's output instead of just hoping the prompt is followed.
  static final RegExp _emojiPattern = RegExp(
    '[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F1E6}-\u{1F1FF}\u{2300}-\u{23FF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]',
    unicode: true,
  );

  String enforceEmojiPolicy(String text) {
    if (emoji != 'emoji_never') return text;
    return text
        .replaceAll(_emojiPattern, '')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .trim();
  }
}

/* ============================ РЕЖИМ РОЛЕВОЙ ИГРЫ (RP) ============================ */

// Sampling-параметры генерации для RP-режима. mirostatMode/tfsZ из исходного
// ТЗ сознательно не добавлены — у закреплённой версии fllama (OpenAiRequest,
// см. package:fllama/misc/openai.dart) просто нет таких полей; добавлять их
// в данные, которые ни на что не влияют, было бы нечестным UI.
class RPSamplingConfig {
  RPSamplingConfig();

  double temperature = 0.9;
  double topP = 0.90;
  // Маппится на fllama presencePenalty / remote repeat_penalty — это и есть
  // репетишн-пенальти, отдельного поля под него не нужно.
  double repetitionPenalty = 1.10;
  int maxResponseTokens = 300;

  Map<String, dynamic> toJson() => {
    'temperature': temperature,
    'topP': topP,
    'repetitionPenalty': repetitionPenalty,
    'maxResponseTokens': maxResponseTokens,
  };

  factory RPSamplingConfig.fromJson(Map<String, dynamic> j) {
    final c = RPSamplingConfig();
    c.temperature = (j['temperature'] as num?)?.toDouble() ?? c.temperature;
    c.topP = (j['topP'] as num?)?.toDouble() ?? c.topP;
    c.repetitionPenalty =
        (j['repetitionPenalty'] as num?)?.toDouble() ?? c.repetitionPenalty;
    c.maxResponseTokens =
        (j['maxResponseTokens'] as num?)?.toInt() ?? c.maxResponseTokens;
    return c;
  }

  RPSamplingConfig clone() => RPSamplingConfig.fromJson(toJson());
}

// Одна статья "блокнота мира" — keywords через запятую, матчится
// регистронезависимо против последних N сообщений чата (см.
// RPMemoryManager.scanLorebook).
class LoreEntry {
  String keywords;
  String content;
  LoreEntry({this.keywords = '', this.content = ''});

  Map<String, dynamic> toJson() => {'keywords': keywords, 'content': content};
  factory LoreEntry.fromJson(Map<String, dynamic> j) => LoreEntry(
    keywords: j['keywords'] as String? ?? '',
    content: j['content'] as String? ?? '',
  );
}

// Настройки RP-режима для конкретного чата — нестандартное nullable поле
// Conversation.rpConfig, по образцу уже существующего Conversation.persona.
class RPSessionConfig {
  RPSessionConfig();

  String userCharacterName = '';
  // Описание персонажа пользователя — кто он в этой истории. Передаётся
  // модели как справочный контекст (см. RPMemoryManager.buildSystemPrompt),
  // в отличие от systemPrompt, который описывает персонажа ИИ и задаёт его
  // голос.
  String userCharacterDescription = '';
  String aiCharacterName = '';
  // Свободный текст с {{user}}/{{char}} — в отличие от Personalization,
  // которая собирает промпт программно из отдельных директив, RP-режим
  // использует один авторский шаблон (см. RPMemoryManager.buildSystemPrompt).
  String systemPrompt = '';
  String scenario = '';
  RPSamplingConfig sampling = RPSamplingConfig();
  bool isLorebookEnabled = false;
  List<LoreEntry> lorebook = [];
  List<String> stopSequences = [];
  // Снимок AppState.selectedModel в момент первого включения RP для этого
  // чата — дальше не меняется (см. AppState.toggleRpMode).
  String? lockedModel;
  int contextWindowLimit = 4096;
  // Сгенерированное резюме старой истории чата (контекстная компрессия по
  // запросу пользователя) — null, пока пользователь не нажал "Сжать".
  String? rollingSummary;
  int? summaryCoversUpToMessageIndex;

  Map<String, dynamic> toJson() => {
    'userCharacterName': userCharacterName,
    'userCharacterDescription': userCharacterDescription,
    'aiCharacterName': aiCharacterName,
    'systemPrompt': systemPrompt,
    'scenario': scenario,
    'sampling': sampling.toJson(),
    'isLorebookEnabled': isLorebookEnabled,
    'lorebook': lorebook.map((e) => e.toJson()).toList(),
    'stopSequences': stopSequences,
    'lockedModel': lockedModel,
    'contextWindowLimit': contextWindowLimit,
    'rollingSummary': rollingSummary,
    'summaryCoversUpToMessageIndex': summaryCoversUpToMessageIndex,
  };

  factory RPSessionConfig.fromJson(Map<String, dynamic> j) {
    final c = RPSessionConfig();
    c.userCharacterName = j['userCharacterName'] as String? ?? '';
    c.userCharacterDescription =
        j['userCharacterDescription'] as String? ?? '';
    c.aiCharacterName = j['aiCharacterName'] as String? ?? '';
    c.systemPrompt = j['systemPrompt'] as String? ?? '';
    c.scenario = j['scenario'] as String? ?? '';
    c.sampling = j['sampling'] is Map<String, dynamic>
        ? RPSamplingConfig.fromJson(j['sampling'] as Map<String, dynamic>)
        : RPSamplingConfig();
    c.isLorebookEnabled = j['isLorebookEnabled'] as bool? ?? false;
    c.lorebook =
        (j['lorebook'] as List<dynamic>?)
            ?.map((e) => LoreEntry.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    c.stopSequences =
        (j['stopSequences'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    c.lockedModel = j['lockedModel'] as String?;
    c.contextWindowLimit =
        (j['contextWindowLimit'] as num?)?.toInt() ?? c.contextWindowLimit;
    c.rollingSummary = j['rollingSummary'] as String?;
    c.summaryCoversUpToMessageIndex =
        (j['summaryCoversUpToMessageIndex'] as num?)?.toInt();
    return c;
  }

  RPSessionConfig clone() => RPSessionConfig.fromJson(toJson());
}

// Assembles the RP-mode system prompt (system prompt + scenario + rolling
// summary + lorebook + pinned context) and manages what actually gets sent
// to the model as history (lorebook scan, sliding-window trim). Pure static
// functions, no AppState dependency — operates only on Conversation/
// RPSessionConfig/ChatMessage.
class RPMemoryManager {
  static String _substitutePlaceholders(String text, RPSessionConfig cfg) {
    var out = text;
    if (cfg.userCharacterName.trim().isNotEmpty) {
      out = out.replaceAll('{{user}}', cfg.userCharacterName.trim());
    }
    if (cfg.aiCharacterName.trim().isNotEmpty) {
      out = out.replaceAll('{{char}}', cfg.aiCharacterName.trim());
    }
    return out;
  }

  // Replaces persona.buildSystemPrompt() entirely for RP-mode chats — RP
  // uses one author-written template instead of Personalization's
  // programmatically-assembled sentences. conv.pinnedContextBlock() is
  // still appended so pinned messages keep working in RP mode too.
  static String buildSystemPrompt(Conversation conv) {
    final cfg = conv.rpConfig!;
    final b = StringBuffer();
    final aiName = cfg.aiCharacterName.trim();
    final userName = cfg.userCharacterName.trim();
    if (cfg.systemPrompt.trim().isNotEmpty) {
      b.writeln(_substitutePlaceholders(cfg.systemPrompt.trim(), cfg));
      // The substitution above only fills in a name where the user's own
      // prompt text happens to use {{user}}/{{char}} — a freeform custom
      // prompt that never does leaves the model with no idea what to call
      // the user (the AI's own name tends to come through anyway, since
      // the prompt is written in its voice). State both names explicitly
      // so a forgotten {{user}} token can't silently drop it.
      if (userName.isNotEmpty || aiName.isNotEmpty) {
        final who = [
          if (userName.isNotEmpty) 'the user is $userName',
          if (aiName.isNotEmpty) 'you are $aiName',
        ].join(' and ');
        b.writeln('(For reference: $who.)');
      }
    } else {
      final ai = aiName.isNotEmpty ? aiName : 'a character';
      b.writeln(
        'You are roleplaying as $ai${userName.isNotEmpty ? " opposite $userName" : ""}. '
        'Stay in character and respond only as your character would.',
      );
    }
    if (cfg.userCharacterDescription.trim().isNotEmpty) {
      final who = userName.isNotEmpty ? userName : 'the user';
      b.writeln(
        'About $who (the human player, not you): '
        '${_substitutePlaceholders(cfg.userCharacterDescription.trim(), cfg)}',
      );
    }
    if (cfg.scenario.trim().isNotEmpty) {
      b.writeln(
        'Scenario: ${_substitutePlaceholders(cfg.scenario.trim(), cfg)}',
      );
    }
    if (cfg.rollingSummary != null && cfg.rollingSummary!.isNotEmpty) {
      b.writeln('Summary of earlier events: ${cfg.rollingSummary}');
    }
    if (cfg.isLorebookEnabled) {
      final lore = scanLorebook(conv, cfg);
      if (lore.isNotEmpty) b.writeln(lore);
    }
    final pinned = conv.pinnedContextBlock();
    if (pinned.isNotEmpty) b.writeln(pinned);
    return b.toString();
  }

  static String scanLorebook(
    Conversation conv,
    RPSessionConfig cfg, {
    int lastN = 10,
  }) {
    final recent = conv.messages.length > lastN
        ? conv.messages.sublist(conv.messages.length - lastN)
        : conv.messages;
    final haystack = recent.map((m) => m.content.toLowerCase()).join(' ');
    final matched = <String>[];
    for (final entry in cfg.lorebook) {
      final kws = entry.keywords
          .split(',')
          .map((k) => k.trim().toLowerCase())
          .where((k) => k.isNotEmpty);
      if (kws.any(haystack.contains)) matched.add(entry.content);
    }
    return matched.join('\n');
  }

  // FIFO sliding window: once history is over budget, keep the first
  // message (greeting/scenario opener) plus the last [keepLastN], drop the
  // rest. Only affects what's SENT to the model — conv.messages (UI) is
  // never touched here.
  static List<ChatMessage> trimForContext(
    List<ChatMessage> history,
    int contextWindowLimit, {
    int keepLastN = 8,
  }) {
    if (history.length <= keepLastN + 1) return history;
    final estTokens = history.fold<int>(
      0,
      (sum, m) => sum + TokenCounter.estimate(m.content),
    );
    if (estTokens <= contextWindowLimit) return history;
    final greeting = [history.first];
    final tail = history.sublist(history.length - keepLastN);
    return [...greeting, ...tail];
  }

  // Context-compression-on-demand (ТЗ-4): true once estimated tokens cross
  // 80% of the chat's contextWindowLimit.
  static bool checkContextThreshold(
    List<ChatMessage> history,
    RPSessionConfig cfg,
  ) {
    final estTokens = history.fold<int>(
      0,
      (sum, m) => sum + TokenCounter.estimate(m.content),
    );
    return estTokens > cfg.contextWindowLimit * 0.8;
  }

  static const _summarizationPrompt =
      'Summarize the following roleplay conversation history concisely, '
      'preserving key plot points, character states, and facts established. '
      'Write the summary in plain prose, third person, no preamble.';

  // Reuses the conversation's own ILLMService (the locked model, passed in
  // by the caller) via a one-off synthetic exchange — NOT the chat's real
  // persona/RP config, so the summarizer doesn't inherit the character's
  // tone instructions.
  static Future<String> summarizeOldContext(
    ILLMService service,
    List<ChatMessage> oldMessages,
  ) async {
    final transcript = oldMessages
        .map((m) => '${m.role}: ${m.content}')
        .join('\n');
    final synthetic = Conversation(
      id: 'rp-summary-temp',
      title: '',
      persona: Personalization(),
    );
    final history = [
      ChatMessage(
        role: 'user',
        content: '$_summarizationPrompt\n\n$transcript',
      ),
    ];
    return service.generateResponse(synthetic, history);
  }
}

// Post-processing safety nets applied to a finished RP reply (after
// streaming completes, never mid-stream — closing a `*` early then having
// more text arrive would look broken).
class RPGuardFilters {
  // Native stop-sequence support only exists for the remote backend (see
  // RemoteLLMService._buildBody); this regex is the only defense for local
  // models, and a backstop for remote ones too. Cuts the reply at the start
  // of a line that looks like the model writing the user's own dialogue.
  static String antiImpersonationFilter(String text, RPSessionConfig cfg) {
    final patterns = <String>[
      r'\{\{user\}\}\s*:',
      if (cfg.userCharacterName.trim().isNotEmpty)
        '${RegExp.escape(cfg.userCharacterName.trim())}\\s*:',
      // Deliberately not \b-bounded: Dart/JS regex \b treats Cyrillic
      // letters as non-word characters, so it doesn't reliably bound
      // Cyrillic text — requiring trailing whitespace instead sidesteps that.
      r'\*?Вы\s',
    ];
    final combined = RegExp(
      '^(${patterns.join('|')})',
      multiLine: true,
      caseSensitive: false,
    );
    final match = combined.firstMatch(text);
    if (match == null) return text;
    return text.substring(0, match.start).trimRight();
  }

  // RP replies often use *asterisks* for actions/thoughts — if the model
  // cuts off mid-italics, auto-close the trailing one instead of leaving
  // broken markdown in the chat UI.
  static String formatEnforcer(String text) {
    final count = '*'.allMatches(text).length;
    return count.isOdd ? '$text*' : text;
  }

  static String apply(String text, RPSessionConfig cfg) =>
      formatEnforcer(antiImpersonationFilter(text, cfg));
}

/* ============================ ЛОКАЛЬНЫЕ МОДЕЛИ ============================ */

enum LocalModelTier { light, mid, high, roleplay }

class LocalModelSpec {
  final String id;
  final String displayName;
  // Short, recognizable label without "Instruct"/version/quant suffixes —
  // shown anywhere the user just needs to know which model is active (chat
  // header, model picker, RP locked-model card). The full displayName stays
  // on the Local Models download screen, where the extra precision actually
  // helps pick what to download.
  final String shortName;
  final int sizeBytes;
  final String url;
  final String fileName;
  final LocalModelTier tier;
  // Native context window the model was actually trained/released with (not
  // a device-RAM guess) — the per-model ceiling shown on the context-size
  // control. fllama hardcodes n_parallel=4 and splits the requested
  // contextSize across 4 slots (see localContextSize * 4 at the call site),
  // so the slider's real usable max is this divided by 4, not the raw value.
  final int maxContextTokens;
  // None of the catalog entries below are vision/multimodal GGUF builds —
  // fllama is given plain OpenAiRequest.messages text, no image bytes — so
  // this defaults to false rather than requiring every entry to spell it
  // out. Flip it on a per-entry basis if a real vision GGUF is ever added.
  final bool isVisionCapable;

  const LocalModelSpec({
    required this.id,
    required this.displayName,
    required this.shortName,
    required this.sizeBytes,
    required this.url,
    required this.fileName,
    required this.tier,
    required this.maxContextTokens,
    this.isVisionCapable = false,
  });

  String get modelKey => 'local:$id';

  int get maxLocalContextSize => maxContextTokens ~/ 4;
}

const List<LocalModelSpec> kLocalModels = [
  // Средние — современные смартфоны среднего класса (например, Honor 70)
  LocalModelSpec(
    id: 'qwen2.5-1.5b',
    displayName: 'Qwen2.5 1.5B Instruct',
    shortName: 'Qwen 1.5B',
    sizeBytes: 1117320736,
    url:
        'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true',
    fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 32768,
  ),
  LocalModelSpec(
    id: 'gemma2-2b',
    displayName: 'Gemma 2 2B Instruct',
    shortName: 'Gemma 2B',
    sizeBytes: 1708582752,
    url:
        'https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf?download=true',
    fileName: 'gemma-2-2b-it-Q4_K_M.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 8192,
  ),
  LocalModelSpec(
    id: 'qwen2.5-3b',
    displayName: 'Qwen2.5 3B Instruct',
    shortName: 'Qwen 3B',
    sizeBytes: 2104932768,
    url:
        'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf?download=true',
    fileName: 'qwen2.5-3b-instruct-q4_k_m.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 32768,
  ),
  LocalModelSpec(
    id: 'phi-3-mini-4k',
    displayName: 'Phi-3 Mini 4K Instruct',
    shortName: 'Phi-3 Mini',
    sizeBytes: 2393231072,
    url:
        'https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf?download=true',
    fileName: 'Phi-3-mini-4k-instruct-q4.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 4096,
  ),
  // 7B/8B-классу (Mistral 7B, Qwen2.5 7B, Llama 3.1 8B, EVA-Qwen2.5 7B) тут
  // больше нет места — на практике эти модели слишком тяжёлые для типичного
  // телефона и стабильно приводили к падениям приложения (нехватка памяти
  // под n_ctx*4 из-за квирка fllama, см. maxLocalContextSize). Каталог
  // сознательно ограничен моделями среднего размера с большим нативным
  // контекстом — оптимальный баланс качества письма/ролевой игры и
  // надёжности на устройстве.
  LocalModelSpec(
    id: 'llama-3.2-3b',
    displayName: 'Llama 3.2 3B Instruct',
    shortName: 'Llama 3B',
    sizeBytes: 2019377696,
    url:
        'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true',
    fileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 131072,
  ),
  LocalModelSpec(
    id: 'phi-3.5-mini',
    displayName: 'Phi-3.5 Mini Instruct',
    shortName: 'Phi-3.5 Mini',
    sizeBytes: 2393232672,
    url:
        'https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf?download=true',
    fileName: 'Phi-3.5-mini-instruct-Q4_K_M.gguf',
    tier: LocalModelTier.mid,
    maxContextTokens: 131072,
  ),
];

String formatBytes(int bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  return '${(bytes / mb).toStringAsFixed(0)} MB';
}

/* ============================ ИСТОРИЯ ИЗМЕНЕНИЙ ============================ */
// Keep in sync with CHANGELOG.md — this is the in-app copy shown on the
// "About version" screen and in the post-update "what's new" dialog.

class ChangelogEntry {
  final String version;
  final List<String> changes;
  const ChangelogEntry(this.version, this.changes);
}

const List<ChangelogEntry> kChangelog = [
  ChangelogEntry('2.3.0', [
    'Темы теперь управляют и семантическими цветами: в палитру добавлены роли info/warn, а статусы подключения, полосы CPU/RAM/VRAM, тона баннеров, цвета типов команд и состояния визуализации следуют теме (success/danger/info/warn/accent) — новая тема перекрашивает эти элементы целиком.',
    'Убрана последняя остаточная лаванда (состояние «думает» у визуализации и мелкие иконки).',
  ]),
  ChangelogEntry('2.2.1', [
    'Исправлены невидимые на светлых темах рамки во всех карточках настроек, диалогах, полях ввода и разделителях — единый токен обводки следует теме.',
    'Выбранные состояния (движок распознавания и др.) и метки разделов теперь следуют акценту/теме, без жёстко-синего и «слепого» серого на кремовом.',
  ]),
  ChangelogEntry('2.2.0', [
    'Единая дизайн-система: общие токены цвета/типографики/отступов; карточки, строки, кнопки, слайдеры, переключатели и radio переведены на токены — корректные рамки и контраст на светлых темах во всём приложении.',
    'Темы курированы до трёх: Тёмная, Claude и Claude (тёмная). Steam/Apple/Discord убраны (сохранённая ранее из них тема автоматически переключается на Тёмную).',
    'Полностью убран остаточный фиолетовый — все акценты следуют текущей теме; цвет визуализации по умолчанию — терракота.',
    'Растушёвка краёв визуализации: волна на плавающем виджете больше не обрывается жёстким квадратом, а мягко растворяется по всем сторонам.',
    'Пузыри чата, меню моделей и баннер статуса распознавания переведены на токены (мягкие тени, тональные статусы, читаемость).',
  ]),
  ChangelogEntry('2.1.5', [
    'Добавлено: тёмная версия темы Claude (тёплый графит, кремовый текст, терракотовый акцент) — в списке тем «Claude (тёмная)».',
    'Улучшено: боковая колонка теперь кремовая/тёмная от самого верха до низа, а верх окна двухцветный (рейка слева, фон справа) — без «уступа» сверху.',
    'Исправлено: на светлых темах не было рамок вокруг метрик (CPU/RAM/VRAM) и панели микрофона; значение CPU было фиолетовым, логотип EVS — белым на кремовом.',
    'Исправлено: убран остаточный фиолет на светлых темах (бейдж «Слушаю», ссылки «Подробнее», иконки).',
  ]),
  ChangelogEntry('2.1.4', [
    'Исправлено: голосовой движок иногда не запускался («голосовой движок не запущен»), если при старте не удавалось загрузить манифест компонентов (нет сети) — выбирался старый сайдкар, не понимающий новых параметров. Теперь манифест кэшируется локально (работает офлайн), а при его отсутствии выбирается актуальный сайдкар.',
    'Исправлено: «Открыть папку моделей» открывала «Документы» вместо папки с моделями (из-за смешанных слэшей в пути).',
    'Улучшено: убраны оставшиеся фиолетовые тексты/иконки на светлых темах (ссылка «Подробнее» и др.) — теперь по цвету выбранной темы.',
  ]),
  ChangelogEntry('2.1.3', [
    'Дочерние процессы теперь различимы в диспетчере задач (вкладка «Подробности»): виджет визуализации запускается как evs_widget.exe — отдельно от evs.exe (главное приложение) и evs_sidecar.exe (голосовой движок), видно, за что отвечает каждый.',
  ]),
  ChangelogEntry('2.1.2', [
    'Исправлено: обновление не устанавливалось, а приложение уходило в петлю перезапуска — установщик обновления не переживал закрытие приложения и фактически не запускался (лог установки не появлялся ни разу). Теперь установка идёт отдельным самостоятельным процессом через планировщик задач и переживает выход приложения; каждый шаг пишется в update-runner.log.',
    'Примечание: этот фикс живёт ВНУТРИ обновления, поэтому текущую (сломанную) версию он вылечить не может — эту сборку нужно один раз установить вручную, дальше авто-обновления заработают штатно.',
  ]),
  ChangelogEntry('2.1.1', [
    'Акценты интерфейса теперь следуют выбранной теме (Claude — терракота, Apple — синий, Steam/Discord — свои): пузыри чата, визуализация, переключатели и выбранные пункты больше не фиолетовые по умолчанию.',
    'Светлые темы: текст стал читаемо-тёмным везде, включая выбранные (обведённые) настройки.',
    'Убрана кнопка голосового ввода из строки ввода — микрофон и так слушает команды постоянно.',
    'Настройки CosyVoice (голос/пресет, клонирование по образцу WAV, скорость, эмоция, устройство) теперь видны всегда — можно настроить заранее, до подъёма сервера.',
  ]),
  ChangelogEntry('2.1.0', [
    'Добавлено: светлые темы оформления — Apple (светлая) и Claude (кремовая), плюс Discord; выбираются в «Оформление». Интерфейс перекрашен под светлый фон: текст, рамки, диалоги и панели корректно читаются на белом.',
    'Добавлено: подсказка настройки голосовых команд при первом запуске — можно сразу предложить команды запуска для ваших приложений.',
    'Исправлено: окно обновления могло появляться при каждом запуске (петля перезапуска) — установщик теперь ставит новую версию поверх запущенной копии, и версия корректно обновляется.',
  ]),
  ChangelogEntry('2.0.3', [
    'Добавлено: приём команд с телефонов по сети (Tailscale/LAN) — раздел «Телефоны». Привязка по одноразовому коду или QR, у каждого телефона свои права (голос/текст) и токен; ответ озвучивается на десктопе и/или возвращается на телефон.',
    'Добавлено: выбор движка озвучки — Piper (офлайн) или CosyVoice (когда его сервер доступен); проверка соединения с CosyVoice.',
  ]),
  ChangelogEntry('2.0.2', [
    'Добавлено: умный подбор голосовых команд — ассистент сам предлагает команды запуска для ваших приложений (по частоте использования), фразы придумывает ИИ, пути берутся из системы.',
    'Добавлено: управление громкостью приложения голосом — «громкость на 30» ставит уровень конкретной программы (число можно словами).',
    'Добавлено: интерпретатор озвучки — перед синтезом убирает эмодзи и разметку, приводит текст к произносимому виду (правилами или через модель).',
    'Добавлено: раздел «Модель и инференс» — проверка соединения, обновление списка моделей, модель отдельно для поиска и чата, параметры (num_ctx, temperature, keep_alive) в блоке «Дополнительно».',
    'Добавлено: быстрые профили одним нажатием — Быстро / Качество / Поиск / Чат.',
    'Улучшено: раскладка настроек подстраивается под ширину окна (1/2/3 колонки), без пустот и «уехавших» карточек.',
  ]),
  ChangelogEntry('2.0.1', [
    'Исправлено: GigaAM, шумоподавление и голоса Piper не включались (ошибка «ORT Version» / «модель не найдена») — движок пересобран, конфликт библиотек устранён.',
    'Исправлено: Whisper иногда не открывался («Unable to open file model.bin») при переключении движков — теперь дожидается докачки модели.',
    'Исправлено: разъезжалась сетка настроек — большие пустоты и «уехавшие» карточки. Колонки набиваются независимо и подстраиваются под ширину окна.',
    'Исправлено: бейдж голосового движка всегда показывал «Whisper» — теперь показывает активную модель (GigaAM или Whisper).',
    'Улучшено: понятнее выбор распознавания — «Windows STT» или «Локальный (EVS)»; модели Whisper/GigaAM относятся только к локальному движку.',
    'Улучшено: визуализация «волна» больше не резкий квадрат (мягкие края) и меняет цвет по состоянию ассистента, как остальные визуализации.',
  ]),
  ChangelogEntry('2.0.0', [
    'Добавлено: шумоподавление микрофона (лёгкое/сильное), как в Discord — по умолчанию включено.',
    'Добавлено: новый движок распознавания GigaAM (лучшая точность для русского) + выбор движка и модели Whisper, у каждого варианта — «Подробнее».',
    'Добавлено: естественные голоса ассистента (Piper) — Ирина, Денис, Дмитрий, Руслан: скачать, прослушать образец, выбрать.',
    'Добавлено: менеджер моделей — скачивание/удаление движков распознавания, шумоподавления и голосов с прогрессом.',
    'Добавлено: выбор CPU/GPU для распознавания и игровой режим — авто-разгрузка видеокарты в полноэкранных играх и при нехватке видеопамяти (с голосовым уведомлением).',
    'Добавлено: несколько микрофонов одновременно (например, в разных комнатах) — своё шумоподавление на каждый, одна фраза выполняется один раз.',
    'Добавлено: голосовое уведомление «Готова слушать» при запуске и индикатор загрузки — ассистент больше не «глохнет» после старта.',
    'Добавлено: единая тема; окно и виджет запоминают размер и положение (в т.ч. на втором мониторе) и переживают обновление; кнопка «Сохранить/Отменить» в настройках; новые визуализаторы.',
    'Убрано: клонирование голоса (XTTS) — заменено естественными голосами Piper.',
  ]),
  ChangelogEntry('1.1.2', [
    'Исправлены «кракозябры» в названиях приложений из Microsoft Store (кодировка UTF-8).',
    'Тумблер «Чат» больше не растягивается на всю ширину.',
    'При неудачной команде показывается распознанный текст («Команда не найдена: …») — видно, что именно услышано.',
    'Ещё надёжнее установка обновлений: перед заменой файлов принудительно завершаются все процессы приложения (виджет/движки).',
  ]),
  ChangelogEntry('1.1.1', [
    'Надёжнее установка обновлений: перед заменой файлов приложение дожидается полного закрытия всех своих процессов (включая виджет), а затем само перезапускается. Если что-то пошло не так — пишется подробный лог установки (update-install.log) для диагностики.',
  ]),
  ChangelogEntry('1.1.0', [
    'Режим «только команды»: тумблер «Чат» в настройках — выключите, чтобы ассистент выполнял только команды. Нераспознанная фраза не уходит в чат, а отвечает «Команда не найдена»; текстовый ввод при этом отключается.',
    'Редактирование команд: у каждой команды появилась кнопка-карандаш — открывает мастер с уже заполненными полями.',
    'Приложения из Microsoft Store теперь попадают в список (включая Яндекс Музыку и другие Store-приложения/PWA) и запускаются командой.',
    'Точнее распознавание команд: убрана лишняя пунктуация и добавлено совпадение по словам (лишние слова/порядок больше не мешают). При уходе фразы в чат в лог пишется балл совпадения — для диагностики.',
    'Тест распознавания: распознанный текст можно выделить и скопировать, добавлена кнопка «Очистить».',
  ]),
  ChangelogEntry('1.0.13', [
    'Фраза-озвучка команды: при добавлении команды можно вписать фразу, которую ассистент произнесёт при её выполнении (например «Открываю Яндекс Музыку»). Работает при включённых голосовых ответах.',
    'В список программ для команд добавлены приложения из Microsoft Store — их теперь можно назначать на голосовые команды и запускать.',
    'В списке приложений при добавлении команды показываются их иконки.',
    'Портативный режим: если папка программы доступна для записи, все данные (движки, модели, чаты, настройки, логи) хранятся рядом с программой, а не в системной папке. Существующие данные переносятся автоматически.',
    'Удаление чатов на компьютере: правый клик по чату в боковой панели (или кнопка «⋮») открывает меню — переименовать, закрепить, удалить (с отменой).',
  ]),
  ChangelogEntry('1.0.12', [
    'Веб-поиск: ассистент сам ищет свежие данные в интернете (курс валют, погода, новости), когда вопрос этого требует, и отвечает по ним. Включается в «Модель», работает без ключа (DuckDuckGo) или с ключом Tavily/Brave.',
    'Исправлен микрофон, который «переставал слышать» после перезапуска: распознавание теперь надёжно перезапускается при каждом переподключении голосового движка. Тест распознавания снова показывает текст.',
    'Обновление больше не предлагается при каждом запуске и надёжнее устанавливается (закрытие старой версии перед заменой файлов); если установка не удалась — приложение сообщит об этом.',
    'Виджет запоминает своё положение: где оставили — там и появится после перезапуска.',
    'Удаление чата теперь можно отменить (кнопка «Отменить»). Раздел настроек распознавания больше не «съезжает».',
  ]),
  ChangelogEntry('1.0.11', [
    'Тест распознавания в настройках: произнесите фразу и сразу увидите, как её записал распознаватель — удобно подбирать фразу-триггер.',
    'Добавление команды переделано в пошаговый мастер: выбор типа (программа / файл / сайт / система / медиа) → для программы список установленных приложений → фраза-триггер.',
    'Убраны «встроенные» команды: теперь выполняются ТОЛЬКО добавленные вами команды. «Открой калькулятор/браузер/музыку» без добавления больше ничего не запускает.',
    'Виджет без текстовых плашек: прозрачная область больше, а реакции («услышал», «думаю», «выполняю») показываются сменой цвета с возвратом к исходному.',
  ]),
  ChangelogEntry('1.0.10', [
    'Один экземпляр приложения: повторный запуск ярлыка больше не открывает вторую копию, а разворачивает уже запущенное окно.',
    'Удаление чата правой кнопкой мыши: клик ПКМ по чату в списке открывает меню (переименовать / закрепить / удалить).',
    'Сфера Siri теперь с мягким, растушёванным краем вместо жёсткой линии по окружности.',
    'Быстрее озвучка ответов: ассистент начинает говорить первое предложение почти сразу, не дожидаясь генерации всего ответа (фразы идут подряд без обрыва).',
  ]),
  ChangelogEntry('1.0.9', [
    'Исправлен запуск голосового движка (иногда показывал «Не запущен»): фоновый процесс распознавания больше не зависает на старте.',
    'Все вспомогательные процессы (движок распознавания, виджет, синтез голоса) теперь гарантированно закрываются вместе с приложением — даже при аварийном завершении или снятии через диспетчер задач, ничего не остаётся висеть в фоне.',
  ]),
  ChangelogEntry('1.0.8', [
    'Лучше распознавание речи: подсказка распознавателю (слово-активатор + словарь команд) и более точный разбор завершённых фраз (шире поиск + перебор температур) — короткие команды слышатся стабильнее.',
    'Остановка голосом: скажите «стоп», «хватит» (или «EVS, стоп») — ассистент сразу прервёт озвучку и текущую генерацию ответа. Набор стоп-слов редактируется в настройках.',
    'Несколько адресов серверов: сохраняйте адреса локального/удалённого сервера и переключайтесь между ними в один тап (настройки → подключение).',
    'Плашка статуса больше не залипает: показывает только состояние (Слушаю / услышал активатор / ошибка), без зависающих распознанных фраз.',
    'Понимание команд улучшено: после активатора команды выполняются точнее (расширенный список действий и примеры для интерпретатора), а обычные вопросы по-прежнему уходят в чат.',
  ]),
  ChangelogEntry('1.0.7', [
    'Виджет стал отдельным окном (собственный процесс): чат и виджет видны одновременно, виджет всегда поверх окон, приложение стартует только виджетом у правого края.',
    'Починено распознавание речи: фразы теперь корректно завершаются и обрабатываются за секунды (VAD + шумовой гейт + сброс отстающей очереди), отфильтрованы галлюцинации Whisper («Субтитры…»), выбранный микрофон реально передаётся распознавателю, medium автоматически заменён на small (на CPU он обрабатывал фразу ~минуту).',
    'Голосовые команды больше не попадают в чат: каталог → нейросеть-интерпретатор (теперь реально работает: «открой…», «найди…» и т.п.) → выполнение; результат — голосом и бейджем на виджете.',
    'Стадии ассистента видны на виджете и в шапке: «услышал» → «Говорите команду…» (активатор без команды ждёт её отдельной фразой 8 секунд) → «Думаю…» → «Выполняю…» → «Выполнено».',
    'Виджет и визуализации реагируют только на голос ассистента; «Бары» и «Кольцо» двигаются строго вверх-вниз/по радиусу, без прокрутки и вращения.',
    'Логи commands/chat/errors в папке данных приложения.',
  ]),
  ChangelogEntry('1.0.6', [
    'EVS теперь открывается плавающим виджетом у правого края экрана: маленькое прозрачное окно поверх всех окон, перетаскивается мышью, двойной клик разворачивает чат, закрытие чата возвращает виджет.',
    'Два новых стиля визуализации — Siri Orb (цветные блобы с бликом) и Полоски (LiveKit-стиль), оба реагируют на реальный звук.',
    'Новый раздел настроек «Виджеты»: живой предпросмотр с имитацией голоса, выбор стиля, акцентный цвет, размер/скорость орба, число полосок и настройки плавающего виджета.',
    'Подключение модели теперь только через сервер: локальный (Ollama) по адресу или удалённый по адресу с API-ключом; загрузка локальных моделей убрана.',
    'Исправлен вылет при запуске с выбранной локальной моделью: сбойная модель теперь гарантированно отключается после первого падения.',
  ]),
  ChangelogEntry('1.0.5', [
    'Живые визуализации голоса: три варианта виджета (сфера, кольцо, бары) — реагируют на реальный звук с микрофона и на озвучку ответов, переключаются в настройках («Тип визуализации»).',
    'Видимая реакция на слово-активатор: при «EVS…» плашка вспыхивает «услышал, говорите!», визуализация даёт импульс.',
    'Окно обновления в стиле EVS: тёмный диалог со списком изменений и кнопками «Перезапустить»/«Позже» (появляется, когда обновление уже скачано).',
    'Озвучка ответов теперь транслирует уровень звука в интерфейс (виджеты «дышат» голосом ассистента).',
    'Обновлён список изменений (история версий EVS).',
  ]),
  ChangelogEntry('1.0.4', [
    'Обновления как в Discord: скачиваются в фоне, в приложении появляется плашка «Обновление · Перезапустить» — один клик, и новая версия открывается сама.',
    'Виджет микрофона на главном экране снова реагирует на звук (волна была заморожена из-за ошибки).',
    'Убраны пер-чатовые настройки и ролевая игра из десктопного чата — ассистент настраивается глобально в настройках EVS.',
    'Тогл «Автопроверка обновлений» стал рабочим.',
  ]),
  ChangelogEntry('1.0.3', [
    'Исправлен вылет приложения при запуске после скачивания локальной модели (сбойная модель отключается автоматически).',
    'Голосовые команды и кнопка запуска в каталоге теперь открывают приложения, ярлыки (.lnk) и ссылки.',
    'Виден отклик ассистента: что услышано, статус движка, уведомления о выполнении команд.',
    'Слово-активатор «EVS» распознаётся и в русской речи (транслитерация).',
  ]),
  ChangelogEntry('1.0.2', [
    'Голосовой ассистент «как у Алисы»: постоянное прослушивание со словом-активатором, выполнение команд из каталога, озвучка ответов.',
    'Клонирование голоса (XTTS): ответы вашим голосом из образца WAV 6–10 секунд, офлайн.',
    'Тонкие обновления: установщик ~15 МБ, тяжёлые компоненты (голосовой движок, клонирование) догружаются отдельно по требованию.',
    'Рабочий выбор модели Whisper, реальная плашка статуса нейросети с окном ошибки, настройки во всю ширину.',
  ]),
  ChangelogEntry('1.0.1', [
    'Автообновления через собственный канал (appcast + подписанные установщики).',
    'Первый цикл обновления проверен: 1.0.0 → 1.0.1.',
  ]),
  ChangelogEntry('1.0.0', [
    'Проект переименован из «Mirai» в «EVS» (Enhanced Voice System — система усовершенствованного голосового управления): новое отображаемое имя, заголовок окна, имя ассистента и метаданные приложения; исполняемый файл теперь evs.exe.',
    'EVS — это десктоп-ответвление (только Windows) от разработки Mirai; нумерация версий начинается заново с 1.0.0.',
  ]),
  ChangelogEntry('2.14.2', [
    'Экран «Подготовка модели»: при открытии чата с локальной моделью она заранее прогревается — видна карточка загрузки, поле ввода блокируется до готовности (первый ответ быстрее).',
    'Все всплывающие окна в стеклянном стиле теперь оформлены как Liquid Glass (полупрозрачные с размытием).',
    'Окно «Управление моделями» теперь открывается по центру экрана в общем стиле, а не выезжает снизу.',
    'Размер контекста локальной модели автоматически ограничивается под объём ОЗУ устройства — защита от вылетов при слишком большом контексте.',
    '«Жидкое стекло» переименовано в «Liquid Glass».',
  ]),
  ChangelogEntry('2.14.1', [
    'На iPhone — системный шрифт iOS (San Francisco), как в самой системе. На Android/ПК остаётся Nunito.',
    'Мелкие правки оформления: точки «печатает…» выровнены по центру пузыря; область названия модели в шапке — по размеру текста.',
  ]),
  ChangelogEntry('2.14.0', [
    'Под последним ответом нейросети — три кнопки (во всех чатах): Редактировать (правка прямо в пузыре), Перегенерировать (заново сгенерировать ответ), Продолжить (следующий ход ассистента по контексту, без вашей реплики).',
  ]),
  ChangelogEntry('2.13.2', [
    'Вкладки «Память»/«Ролевая игра» в стеклянном стиле — капсула с «парящей» пилюлей (сегмент-контрол iOS 26) вместо подчёркивания.',
    'Экран «Настройки этого чата» в стеклянном стиле получил собственный мягкий цветной фон вместо размытия живого чата за ним.',
  ]),
  ChangelogEntry('2.13.1', [
    'Лимит контекста в ролевой игре предлагает все значения до максимума модели (раньше обрезалось на 8192).',
    'Контекстные меню (⋮ у чата, долгое нажатие на сообщение) — в стиле «Жидкое стекло» с размытием.',
    'Экран «Настройки этого чата» в стеклянном стиле открывается полупрозрачным слоем поверх чата.',
    'Между строками настроек добавлены тонкие разделители.',
    'Уведомления всплывают по центру стеклянной «пилюлей», а не белой полосой снизу.',
    'Плитка чата в списке стала немного уже.',
    'Исправлено: свайп-открытие списка чатов больше не поднимает клавиатуру.',
  ]),
  ChangelogEntry('2.13.0', [
    'Список чатов открывается свайпом от левого края (полноэкранно); кнопка чатов из шапки убрана, настройки чата — справа, название модели по центру.',
    'Новый стиль «Жидкое стекло» (iOS 26) — в настройках под «Темой» пункт «Стиль приложения». Переоформлен весь интерфейс, включая тумблеры. Работает поверх любой темы.',
    'Чаты можно переименовывать — пункт «Переименовать» в меню чата (⋮).',
    'При запуске играет анимация: сфера приближается и растворяется, открывая чат. Тапом можно пропустить. Старый статичный сплэш убран.',
    'В ролевой игре у своего персонажа можно задать описание (внешность, характер, роль), не только имя.',
    'Обводка вокруг названия модели в шапке — тоньше, того же цвета, что у круглых кнопок, с отступом.',
  ]),
  ChangelogEntry('2.12.0', [
    'Переключатель ролевой игры убран из шапки чата — теперь он внутри вкладки «Ролевая игра», которая всегда видна рядом с «Память».',
    'В описание системного промпта ролевой игры добавлен пример использования {{user}} и {{char}}.',
    'Размер контекста для ролевых чатов больше не дублируется в двух вкладках — единственный лимит теперь на вкладке «Ролевая игра».',
    'Название модели в шапке чата — без «(на устройстве)», с акцентной обводкой.',
    'При прикреплении фото — миниатюра прямо в поле ввода, а не отдельный блок с именем файла.',
    'Из каталога локальных моделей убраны тяжёлые 7B/8B модели — часто приводили к нехватке памяти и падению приложения. Добавлены Llama 3.2 3B и Phi-3.5 Mini с контекстом 128K токенов.',
  ]),
  ChangelogEntry('2.11.1', [
    'Исправлен статус-бар на iOS (время, сеть, заряд батареи пропадали).',
    'В ролевой игре добавлен пресет длины ответа «Эпопея» (1000 токенов).',
    'Имена персонажей в ролевой игре надёжнее доходят до модели, даже при своём системном промпте без {{user}}.',
    'Настройки персонажей переразложены: «Мой персонаж» отдельно от «Роль ИИ».',
  ]),
  ChangelogEntry('2.11.0', [
    'Новая иконка приложения — светящийся синий орб с частицами вместо прежнего волнистого узора.',
    'Сплэш-экран при запуске теперь показывает тот же орб на фирменном фоне, для светлой и тёмной темы.',
  ]),
  ChangelogEntry('2.10.2', [
    'В конце настроек теперь видна версия приложения (номер версии и сборки).',
  ]),
  ChangelogEntry('2.10.1', [
    'Вкладка «Личность» временно скрыта из настроек персонализации — её слайдеры и переключатели всё ещё не давали заметной разницы в ответах модели.',
    'Дублирующий пункт «Персонализация» в общих настройках убран — он открывал тот же экран, что и «Память».',
  ]),
  ChangelogEntry('2.10.0', [
    'В каталог локальных моделей добавлена EVA-Qwen2.5 7B — файнтюн под ролевую игру, в отдельной категории «Для ролевой игры».',
    'Контроль размера контекста для локальных моделей перенесён из вкладки «Личность» в «Память»; максимум подстраивается под реально выбранную модель.',
    'Названия моделей в шапке чата и меню выбора стали короче, без версий и квантования.',
    'В шапке чата кнопки режима ролевой игры и настроек чата расположены друг под другом, область с названием модели стала заметно шире.',
    'В настройках персонализации и списке диалогов тап по пустому месту экрана скрывает клавиатуру — как и в самом чате.',
    'При прикреплении изображения — предупреждение, если выбранная модель не может видеть содержимое картинки.',
  ]),
  ChangelogEntry('2.9.2', [
    'Настройка «Эмодзи: Никогда» теперь гарантированно убирает эмодзи из ответа, а не просто намекает модели в системном промпте.',
  ]),
  ChangelogEntry('2.9.1', [
    'Ползунки личности (формальность, эмпатия, детализация, юмор, креативность) заметнее влияют на ответы — раньше движение в средней трети шкалы вообще ничего не меняло.',
    'У каждой настройки на вкладках «Личность» и «Ролевая игра» теперь есть короткое описание того, что именно она меняет.',
  ]),
  ChangelogEntry('2.9.0', [
    'Новый режим «Ролевая игра» для отдельного чата — модель фиксируется за этим чатом в момент включения.',
    'Вкладка «Ролевая игра»: имена персонажа и пользователя, системный промпт и сценарий, тонкая настройка генерации, блокнот мира, стоп-фразы и лимит контекста.',
    'Ответ модели в режиме ролевой игры появляется построчно по мере генерации, с кнопкой остановки.',
    'Баннер «Сжать память чата», когда история приближается к лимиту контекста.',
    'Защита от типичных для ролевых диалогов сбоев: модель не пишет реплики от имени пользователя, незакрытая разметка автоматически закрывается.',
  ]),
  ChangelogEntry('2.8.1', [
    'Проверка обновлений на Android больше не путает Android- и iOS-релизы репозитория при поиске последней версии.',
  ]),
  ChangelogEntry('2.8.0', [
    'В чате: тап по пустой области экрана скрывает клавиатуру; на iOS статус-бар и Dynamic Island больше не перекрываются содержимым чата.',
    'Настройки персонализации теперь реально применяются к локальным моделям среднего и мощного тиров, а не только к удалённым.',
    'Лёгкий тир локальных моделей убран из каталога — был слишком слабым для системного промпта.',
    'Вкладки «Личность»/«Память» переоформлены; для локальных моделей добавлен контроль размера контекста.',
    'Долгое нажатие на сообщение открывает меню: Копировать / В поле ввода / Запомнить / Забыть / Закрепить в контексте.',
    'В «Памяти»: сохранённые воспоминания и закреплённые сообщения чата, «Спрашивать перед сохранением», «Автосохранение полезных деталей».',
    'Прикрепление файлов — шторка снизу с реальной сеткой недавних фото из галереи и вкладкой «Файл».',
    'Кнопка отправки подсвечивается зелёным, когда есть текст или прикреплённый файл.',
    'Новый вариант темы «Серая» — нейтральная палитра без сине-фиолетового оттенка.',
    'В списке диалогов — карточка «Продолжить» с последним чатом и кнопкой «Возобновить».',
    'Шрифт по всему приложению заменён на Nunito.',
    'Голосовой ввод больше не выключает микрофон во время пауз в речи — сессия остаётся активной всё время на экране, выключается только по кнопке микрофона или при выходе с экрана.',
  ]),
  ChangelogEntry('2.7.3', [
    'На экране голосового ввода вокруг анимированной рамки добавлен мягкий рассеивающийся свет того же сине-фиолетового градиента, расходящийся к центру экрана.',
  ]),
  ChangelogEntry('2.7.2', [
    'Пока нейросеть генерирует ответ, вместо «Думаю…» — зацикленная анимация из трёх волнообразно подпрыгивающих точек.',
  ]),
  ChangelogEntry('2.7.1', [
    'Пузыри сообщений нейросети в чате окрашены тем же синим градиентом, что и акцентные кнопки.',
  ]),
  ChangelogEntry('2.7.0', [
    'Голосовой ввод больше не "засыпает" молча после паузы — распознавание автоматически перезапускается, а уже распознанный текст не теряется.',
    'Если микрофон не удаётся подключить вообще, экран голосового ввода теперь явно показывает ошибку с кнопкой «Повторить» вместо бесконечного «Подключение микрофона…».',
  ]),
  ChangelogEntry('2.6.1', [
    'Вкладки «Личность»/«Память» в настройках персонализации перенесены с левой боковой панели наверх, под заголовок экрана.',
  ]),
  ChangelogEntry('2.6.0', [
    'Экран «Память» (заметки, профиль «о вас», запретные темы/безопасность) объединён с экраном персонализации как вкладка сбоку — раньше «Память» всегда редактировала только общие настройки, даже если открыта из конкретного чата. Теперь обе вкладки сохраняются туда же, куда и настройки личности.',
  ]),
  ChangelogEntry('2.5.0', [
    'Настройки персонализации снова применяются к локальным моделям среднего и мощного тиров — раньше все локальные модели получали урезанный промпт, теперь это ограничение касается только самых слабых (лёгкий тир).',
    'Даже для лёгкого тира добавилась реакция на тон ответа и частоту эмодзи.',
  ]),
  ChangelogEntry('2.4.0', [
    'Подключён Shorebird Code Push: обычные обновления теперь прилетают в фоне небольшим патчем и применяются при следующем перезапуске приложения, без скачивания нового APK целиком. Крупные изменения по-прежнему идут через полный APK с GitHub.',
  ]),
  ChangelogEntry('2.3.2', [
    'Описание тира («Для слабых/старых телефонов…» и т.д.) на экране «Локальные модели» больше не обрезается посередине строки — теперь идёт на отдельной строке под названием тира и переносится целиком.',
  ]),
  ChangelogEntry('2.3.1', [
    'Убрана картинка со сплэш-экрана — теперь это просто фон фирменного цвета (светлый/тёмный), без изображения.',
  ]),
  ChangelogEntry('2.3.0', [
    'Локальные модели теперь получают сильно укороченный системный промпт (имя ассистента, длина ответа, запретные темы, кастомная инструкция) вместо полного набора директив персонализации — маленькие модели не справлялись с длинным промптом и путали его структуру с содержанием ответа.',
    'Проверка обновлений в настройках теперь показывает результат во всплывающем диалоговом окне (ошибка / последняя версия / доступно обновление с кнопкой «Скачать и установить») вместо короткого уведомления внизу экрана.',
  ]),
  ChangelogEntry('2.2.0', [
    'Убрана модель TinyLlama 1.1B Chat из каталога локальных моделей — слишком слабая, не справлялась с системным промптом и выдавала бессвязные ответы.',
    'Добавлена Gemma 2 2B Instruct (средний тир) — известна хорошим качеством именно обычного диалога при небольшом размере.',
    'Исправлен визуальный баг: пункт «Создать изображение» в меню выбора модели мог выходить за границы меню на узких экранах вместо аккуратной обрезки текста.',
  ]),
  ChangelogEntry('2.1.0', [
    'Сфера на экране голосового ввода теперь реагирует на громкость с микрофона в реальном времени: пульсирует сильнее, ярче светится и быстрее дрожит при громком звуке, и успокаивается в тишине.',
    'На Windows-сборке эффект не виден — нативный SAPI-плагин речи не передаёт уровень громкости; полноценно работает на Android (и должно — на iOS).',
  ]),
  ChangelogEntry('2.0.0', [
    'Приложение и репозиторий переименованы из «Alice AI» в «Mirai»: новое отображаемое имя, системный промпт ассистента, package name и applicationId/bundle id на всех платформах.',
    'Важно: из-за смены applicationId/bundle id уже установленные копии Alice AI не обновятся поверх — Mirai ставится как отдельное приложение, старое нужно удалить вручную.',
  ]),
  ChangelogEntry('1.7.1', [
    'Исправлена ошибка «exceeds the available context size» при разговоре с локальной моделью (TinyLlama и др.) — fllama делит запрошенный размер контекста на 4 параллельных слота, из-за чего модели реально доставалось только 512 токенов вместо 2048.',
    'Кнопка отправки в поле ввода больше не меняет размер при переходе в состояние «отправляется».',
  ]),
  ChangelogEntry('1.7.0', [
    'Новый пункт «О версии» в настройках («О приложении») — открывает экран со списком изменений по всем версиям приложения.',
    'После обновления приложения при первом запуске показывается всплывающее окно с описанием того, что изменилось в новой версии.',
  ]),
  ChangelogEntry('1.6.0', [
    'Экран голосового ввода: добавлена анимированная светящаяся рамка по краям экрана (тот же вращающийся синий/фиолетовый градиент, что и вокруг поля ввода текста).',
    'Цветовая гамма экрана голосового ввода (фон, сфера, акценты) перекрашена из бирюзовой в сине-фиолетовую, чтобы сочетаться с новой рамкой.',
  ]),
  ChangelogEntry('1.5.2', [
    'Исправлена миграция старых данных: заглушка «Alice Nano» и адрес сервера по умолчанию (192.168.1.100:11434), сохранённые версиями приложения до 1.4.1, теперь автоматически вычищаются при загрузке вместо того, чтобы выглядеть как настоящие сохранённые значения.',
    'Поле адреса сервера пустое по умолчанию и показывает серый пример-подсказку, пока пользователь не введёт свой адрес.',
  ]),
  ChangelogEntry('1.5.1', [
    'Единый синий градиент применён ко всем акцентным кнопкам («Новый чат», CTA в пустом списке чатов) и ползункам (размер шрифта, параметры персонализации).',
    'Шрифт по всему приложению стал на ступень менее жирным (w800→w700, w700→w600, w600→w500).',
    'Масштаб текста теперь учитывает системную настройку размера шрифта устройства, а не только внутренний слайдер приложения.',
  ]),
  ChangelogEntry('1.5.0', [
    'Настройки поведения модели теперь можно задать индивидуально для каждого чата: новая кнопка (значок «человек+шестерёнка») в верхней панели открывает экран персонализации именно для текущего чата. Если для чата заданы свои настройки, общие настройки приложения на него больше не влияют.',
  ]),
  ChangelogEntry('1.4.1', [
    'Убрана несуществующая модель-заглушка «Alice Nano»: при отсутствии подключения к серверу и нескачанных локальных моделей теперь честно показывается «Нет доступных моделей» вместо фейкового названия.',
  ]),
  ChangelogEntry('1.4.0', [
    'Проверка обновлений в настройках («О приложении» → «Проверить обновления»): сравнивает версию с последним релизом на GitHub, скачивает APK и запускает установку — без переходов по ссылкам (Android).',
    'Сфера на главном экране теперь по-настоящему разлетается на частицы при появлении клавиатуры и собирается обратно при скрытии (раньше — простое затухание/уменьшение).',
    'Увеличено количество частиц в сфере, добавлена случайная яркость каждой частицы — силуэт выглядит менее "идеально круглым".',
  ]),
  ChangelogEntry('1.3.0', [
    'Нативный сплэш-экран при запуске (свой дизайн вместо чёрного/белого экрана), отдельно для светлой и тёмной темы — Android (включая Android 12+), iOS, Web.',
    'Минимальная длительность показа сплэша (1.2с), чтобы он не "мигал" на быстрых устройствах.',
  ]),
  ChangelogEntry('1.2.0', [
    'Каталог локальных моделей расширен с 2 до 9: добавлены лёгкие (Qwen2.5 0.5B, Llama 3.2 1B), средние (Qwen2.5 3B, Phi-3 Mini) и мощные (Mistral 7B, Qwen2.5 7B, Llama 3.1 8B) варианты.',
    'Модели в экране «Локальные модели» сгруппированы по категориям устройств (лёгкие/средние/мощные) с разделителями.',
    'Список моделей сделан компактнее (карточки в одну строку вместо нескольких).',
  ]),
  ChangelogEntry('1.1.0', [
    'Локальный инференс на устройстве через fllama (llama.cpp/GGUF) — чат работает офлайн без сервера.',
    'Экран «Локальные модели»: скачивание с прогрессом, выбор, удаление.',
    'Исправления голосового ввода: разрешения микрофона на Android, надёжность переподключения, кнопка «Отправить».',
    'Новая иконка приложения (закруглённые углы, обрезка лишних полей).',
  ]),
  ChangelogEntry('1.0.0', [
    'Базовая версия: переименование приложения в Alice AI.',
  ]),
];

/* ============================ LLM PROVIDER PATTERN ============================ */
//
// Unifies the local (fllama) and remote (Ollama/OpenAI-compatible HTTP)
// backends behind one interface, so AppState.sendMessage() doesn't have to
// branch on isLocalModel() itself. Both implementations need a handful of
// AppState fields (selectedModel, serverUrl, persona...) and helpers
// (t(), buildSystemPrompt() via persona, _extractContent) — passed in via
// the AppState reference rather than duplicated, since these services
// aren't meant to be used outside AppState's own call path. Kept as plain
// classes in this file rather than split into their own files/packages —
// the project is deliberately single-file (see CLAUDE.md).

abstract class ILLMService {
  /// No-op placeholder for both backends today: fllama loads/caches GGUF
  /// weights lazily on the first fllamaChat() call (there's no separate
  /// "load" step to await), and the remote backend has nothing to connect
  /// ahead of time either. Kept on the interface for whichever backend
  /// eventually needs real setup (e.g. a local engine with an explicit
  /// load step) without having to change callers.
  Future<void> initialize();

  /// Local: the model file is actually downloaded. Remote: the server
  /// responds to a lightweight reachability check. Neither is a guarantee
  /// the next generateResponse/generateStream call will succeed (a local
  /// model can still fail to load, a server can still time out) — it's a
  /// best-effort check, not a hard contract.
  Future<bool> isAvailable();

  /// [history] is the conversation so far, NOT including the reply being
  /// generated (callers must not have appended a placeholder for it yet).
  Future<String> generateResponse(Conversation conv, List<ChatMessage> history);

  /// Same contract as [generateResponse], but emits the cumulative reply
  /// text so far on every update instead of waiting for the final string.
  Stream<String> generateStream(Conversation conv, List<ChatMessage> history);

  /// Best-effort interrupt for whichever generateResponse/generateStream
  /// call is currently in flight on this instance. Safe to call when
  /// nothing is running.
  Future<void> stopGeneration();

  /// Proactively load the model into memory so the first real reply is fast
  /// (and so the UI can show a "preparing model" state). Local: runs a tiny
  /// 1-token inference to force the GGUF to load. Remote: no-op (nothing to
  /// preload). Resolves when the model is ready (or immediately on failure).
  Future<void> warmUp(String modelKey);
}

// RP-mode chats lock in whichever model was selected the first time RP
// turned on for them (Conversation.rpConfig.lockedModel) — once locked, that
// chat keeps using it regardless of whatever AppState.selectedModel is set
// to globally afterwards. Non-RP chats always just follow the global model.
// Voice interpreter (settings TZ §3.2 / §7): clean the assistant's text before
// it is handed to TTS. The "rules" mode is a pure offline sanitizer — strip the
// markup a speech engine would read literally (`* # _ ~ ` | > [ ] { } \`) plus
// emoji, while KEEPING sentence punctuation (. , ! ? —) that drives pauses.
class VoiceInterpreter {
  static final RegExp _markup = RegExp(r'[*#_~`|>\[\]{}\\]');
  static final RegExp _emoji = RegExp(
    '[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F1E6}-\u{1F1FF}\u{2300}-\u{23FF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]',
    unicode: true,
  );
  // A markdown link's brackets are stripped by _markup, leaving "text(url)";
  // drop the bare URL tail so TTS does not spell out "h-t-t-p-s…".
  static final RegExp _url = RegExp(r'\(?https?://\S+\)?');
  static final RegExp _spaces = RegExp(r'[ \t]{2,}');

  static String rules(String text) {
    var s = text.replaceAll(_emoji, '');
    s = s.replaceAll(_url, ' ');
    s = s.replaceAll(_markup, '');
    s = s.replaceAll(_spaces, ' ');
    // Trim each line, collapse 3+ blank lines to one, drop leading/trailing ws.
    s = s.split('\n').map((l) => l.trim()).join('\n');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  // System prompt for the "model" mode. The model rewrites for the ear: numbers
  // and dates as words, no emoji/markup, punctuation preserved. Reply is the
  // cleaned text only.
  static const String modelSystemPrompt =
      'Ты — нормализатор текста для синтеза речи. Перепиши текст так, чтобы его '
      'было естественно произнести вслух: числа и даты словами, убери эмодзи и '
      'разметку (* # _ ~ ` | > [ ] { }), сохрани знаки . , ! ? — для пауз. Ничего '
      'не добавляй и не комментируй — верни ТОЛЬКО очищенный текст.';
}

// Extract a number from a spoken phrase — digits ("на 30") or spelled-out
// Russian ("тридцать", "двадцать пять") — for parametric voice commands like
// "громкость на {N}" (new-features Ф2 §2.3, §2.7). Range is not enforced here;
// the caller clamps. Returns null when the phrase has no number.
class NumberWords {
  static const Map<String, int> _units = {
    'ноль': 0, 'один': 1, 'одна': 1, 'одну': 1, 'два': 2, 'две': 2, 'три': 3,
    'четыре': 4, 'пять': 5, 'шесть': 6, 'семь': 7, 'восемь': 8, 'девять': 9,
    'десять': 10, 'одиннадцать': 11, 'двенадцать': 12, 'тринадцать': 13,
    'четырнадцать': 14, 'пятнадцать': 15, 'шестнадцать': 16, 'семнадцать': 17,
    'восемнадцать': 18, 'девятнадцать': 19,
  };
  static const Map<String, int> _tens = {
    'двадцать': 20, 'тридцать': 30, 'сорок': 40, 'пятьдесят': 50,
    'шестьдесят': 60, 'семьдесят': 70, 'восемьдесят': 80, 'девяносто': 90,
    'сто': 100,
  };

  static int? extract(String text) {
    final lower = text.toLowerCase();
    final d = RegExp(r'\d+').firstMatch(lower);
    if (d != null) return int.tryParse(d.group(0)!);
    final words = lower.split(RegExp(r'[^а-яё]+')).where((w) => w.isNotEmpty);
    int? acc;
    for (final w in words) {
      final t = _tens[w];
      final u = _units[w];
      if (t != null) {
        acc = (acc ?? 0) + t;
      } else if (u != null) {
        acc = (acc ?? 0) + u;
      } else if (acc != null) {
        break; // the numeral run ended
      }
    }
    return acc;
  }
}

String _effectiveModelFor(AppState app, Conversation conv) {
  if (conv.rpModeEnabled) {
    final locked = conv.rpConfig?.lockedModel;
    if (locked != null && locked.isNotEmpty) return locked;
  }
  return app.selectedModel;
}

class LocalLLMService implements ILLMService {
  LocalLLMService(this.app);
  final AppState app;
  int? _activeRequestId;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isAvailable() async {
    final spec = app.localSpecFor(app.selectedModel);
    if (spec == null) return false;
    final dir = await localModelsDirPath();
    return localModelFileExists('$dir/${spec.fileName}');
  }

  // Shared by generateResponse/generateStream so the prompt-construction
  // logic (system prompt + tier-based prompt builder + pinned context)
  // only lives in one place.
  Future<(String modelPath, List<Message> messages)?> _prepare(
    Conversation conv,
    List<ChatMessage> history,
  ) async {
    final key = _effectiveModelFor(app, conv);
    // Refuse a model that hard-crashed the native loader (would crash again).
    if (app.crashedLocalModels.contains(key)) return null;
    final spec = app.localSpecFor(key);
    if (spec == null) return null;
    final dir = await localModelsDirPath();
    final modelPath = '$dir/${spec.fileName}';
    if (!await localModelFileExists(modelPath)) return null;

    final rpActive = conv.rpModeEnabled && conv.rpConfig != null;
    final effectivePersona = conv.persona ?? app.persona;
    // Only the weakest (light-tier) models reliably break down on the full
    // multi-directive prompt — mid/high tier local models are capable
    // instruct models in their own right and should get full
    // personalization, same as remote models. RP mode always bypasses this
    // tier check: its own prompt (RPMemoryManager.buildSystemPrompt) is
    // short and user-authored by nature, so the problem buildLocalSystemPrompt
    // exists to solve doesn't really apply the same way.
    final systemPrompt = (rpActive
            ? RPMemoryManager.buildSystemPrompt(conv)
            : (spec.tier == LocalModelTier.light
                      ? effectivePersona.buildLocalSystemPrompt()
                      : effectivePersona.buildSystemPrompt()) +
                  conv.pinnedContextBlock()) +
        app.pendingWebContext; // live web results for this turn (may be empty)
    final effectiveHistory = rpActive
        ? RPMemoryManager.trimForContext(
            history,
            conv.rpConfig!.contextWindowLimit,
          )
        : history;

    final messages = <Message>[
      Message(Role.system, systemPrompt),
      ...effectiveHistory.map(
        (m) => Message(
          m.role == 'user' ? Role.user : Role.assistant,
          m.content.isNotEmpty
              ? m.content
              : '[Attached files: ${m.attachments.join(', ')}]',
        ),
      ),
    ];
    return (modelPath, messages);
  }

  OpenAiRequest _buildRequest(
    Conversation conv,
    String modelPath,
    List<Message> messages,
  ) {
    final effectivePersona = conv.persona ?? app.persona;
    final rpActive = conv.rpModeEnabled && conv.rpConfig != null;
    final sampling = rpActive ? conv.rpConfig?.sampling : null;
    // Defensive re-clamp: the UI control already keeps the relevant size
    // within the live model's range, but this guards the actual request too
    // in case the stored value predates a model switch. RP chats use their
    // own contextWindowLimit (Roleplay tab) as the single source of truth
    // instead of the persona's localContextSize (Memory tab) -- showing both
    // controls for the same chat used to let them disagree.
    final spec = app.localSpecFor(_effectiveModelFor(app, conv));
    // Clamp to the smaller of the model's native ceiling and what the device's
    // RAM can safely hold — this also rescues an already-saved oversized value
    // (e.g. 16384/32768 from before this cap existed) that would OOM-crash.
    final maxLocalContextSize = math.min(
      spec?.maxLocalContextSize ?? 4096,
      app.ramContextCeiling,
    );
    final requestedContextSize = rpActive
        ? conv.rpConfig!.contextWindowLimit
        : effectivePersona.localContextSize;
    final clampedContextSize = requestedContextSize > maxLocalContextSize
        ? maxLocalContextSize
        : requestedContextSize;
    return OpenAiRequest(
      messages: messages,
      modelPath: modelPath,
      // fllama hardcodes n_parallel=4 natively and ignores nParallel on
      // native platforms, splitting contextSize into 4 slots internally
      // (n_ctx_seq = n_ctx / 4). Requesting 4x the user-facing/effective
      // size gives back that much usable context.
      contextSize: clampedContextSize * 4,
      maxTokens: sampling?.maxResponseTokens ?? 512,
      temperature: sampling?.temperature ?? 0.7,
      topP: sampling?.topP ?? 1.0,
      presencePenalty: sampling?.repetitionPenalty ?? 1.1,
    );
  }

  @override
  Future<String> generateResponse(
    Conversation conv,
    List<ChatMessage> history,
  ) async {
    final prepared = await _prepare(conv, history);
    if (prepared == null) return app.t('localModelMissing');
    final (modelPath, messages) = prepared;

    final completer = Completer<String>();
    await setModelLoadingFlag(modelPath);
    // NB: fllamaChat returns as soon as the request is QUEUED — the native
    // load/inference continues on its own thread. The sentinel must stay on
    // disk until the first callback (= survived the crash-prone load), NOT
    // until fllamaChat returns, or a native crash leaves no trace.
    var cleared = false;
    try {
      await fllamaChat(_buildRequest(conv, modelPath, messages), (
        response,
        openaiJson,
        done,
      ) {
        if (!cleared) {
          cleared = true;
          unawaited(clearModelLoadingFlag());
        }
        if (done && !completer.isCompleted) completer.complete(response);
      });
    } catch (e) {
      if (!cleared) {
        cleared = true;
        unawaited(clearModelLoadingFlag());
      }
      if (!completer.isCompleted) {
        completer.complete('${app.t('unreachable')} ($e)');
      }
    }
    return completer.future;
  }

  @override
  Stream<String> generateStream(Conversation conv, List<ChatMessage> history) {
    final controller = StreamController<String>();
    () async {
      final prepared = await _prepare(conv, history);
      if (prepared == null) {
        controller.add(app.t('localModelMissing'));
        await controller.close();
        return;
      }
      final (modelPath, messages) = prepared;
      await setModelLoadingFlag(modelPath);
      var cleared = false;
      try {
        final requestId = await fllamaChat(
          _buildRequest(conv, modelPath, messages),
          (response, openaiJson, done) {
            // First callback = native side loaded past the crash-prone point.
            if (!cleared) {
              cleared = true;
              unawaited(clearModelLoadingFlag());
            }
            if (!controller.isClosed) controller.add(response);
            if (done && !controller.isClosed) controller.close();
          },
        );
        _activeRequestId = requestId;
      } catch (e) {
        if (!controller.isClosed) {
          controller.add('${app.t('unreachable')} ($e)');
          await controller.close();
        }
      } finally {
        if (!cleared) await clearModelLoadingFlag();
      }
    }();
    return controller.stream;
  }

  @override
  Future<void> stopGeneration() async {
    final id = _activeRequestId;
    if (id != null) fllamaCancelInference(id);
  }

  @override
  Future<void> warmUp(String modelKey) async {
    final spec = app.localSpecFor(modelKey);
    if (spec == null) return;
    final dir = await localModelsDirPath();
    final modelPath = '$dir/${spec.fileName}';
    if (!await localModelFileExists(modelPath)) return;
    final completer = Completer<void>();
    // Native load can hard-crash the process — mark it so a crash is detected
    // on the next launch (see AppState.load / crashed-model handling).
    // fllamaChat only QUEUES the request (the load happens on a native
    // thread), so the sentinel is cleared on the first callback — clearing
    // right after fllamaChat returns would erase it before the crash.
    await setModelLoadingFlag(modelKey);
    var cleared = false;
    try {
      // Minimal 1-token request just to force the GGUF to load into memory
      // (and warm the OS file cache). We don't care about the output.
      await fllamaChat(
        OpenAiRequest(
          messages: [Message(Role.user, '.')],
          modelPath: modelPath,
          contextSize: 2048,
          maxTokens: 1,
        ),
        (response, openaiJson, done) {
          if (!cleared) {
            cleared = true;
            unawaited(clearModelLoadingFlag());
          }
          if (done && !completer.isCompleted) completer.complete();
        },
      );
    } catch (_) {
      if (!cleared) {
        cleared = true;
        unawaited(clearModelLoadingFlag());
      }
      if (!completer.isCompleted) completer.complete();
    }
    return completer.future;
  }
}

class RemoteLLMService implements ILLMService {
  RemoteLLMService(this.app);
  final AppState app;
  http.Client? _activeClient;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isAvailable() async {
    if (app.serverUrl.trim().isEmpty) return false;
    try {
      final headers = <String, String>{};
      if (app.apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${app.apiKey}';
      }
      final res = await http
          .get(Uri.parse('${app.baseUrl}/api/tags'), headers: headers)
          .timeout(const Duration(seconds: 6));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  List<Map<String, dynamic>> _buildMessages(
    Conversation conv,
    List<ChatMessage> history,
  ) {
    final rpActive = conv.rpModeEnabled && conv.rpConfig != null;
    final systemPrompt = (rpActive
            ? RPMemoryManager.buildSystemPrompt(conv)
            : (conv.persona ?? app.persona).buildSystemPrompt() +
                  conv.pinnedContextBlock()) +
        app.pendingWebContext; // live web results for this turn (may be empty)
    final effectiveHistory = rpActive
        ? RPMemoryManager.trimForContext(
            history,
            conv.rpConfig!.contextWindowLimit,
          )
        : history;
    return [
      {'role': 'system', 'content': systemPrompt},
      ...effectiveHistory.map(
        (m) => {
          'role': m.role,
          'content': m.content.isNotEmpty
              ? m.content
              : '[Attached files: ${m.attachments.join(', ')}]',
        },
      ),
    ];
  }

  // RP mode forwards RPSamplingConfig/stopSequences as Ollama's `options` and
  // keeps full control of sampling; everything else uses the user's global
  // inference options from Settings, which are omitted field-by-field when left
  // blank so the model default applies.
  Map<String, dynamic> _buildBody(
    Conversation conv,
    List<ChatMessage> history,
    bool stream,
  ) {
    final body = <String, dynamic>{
      // Per-mode override: a turn with live web results uses the search model,
      // everything else the chat model (both fall back to the global model when
      // unset). RP-locked chats keep their pinned model — handled inside.
      'model': app.modelForTurn(conv,
          isSearch: app.pendingWebContext.trim().isNotEmpty),
      'stream': stream,
      'messages': _buildMessages(conv, history),
    };
    if (conv.rpModeEnabled && conv.rpConfig != null) {
      final s = conv.rpConfig!.sampling;
      body['options'] = {
        'temperature': s.temperature,
        'top_p': s.topP,
        'repeat_penalty': s.repetitionPenalty,
        'num_predict': s.maxResponseTokens,
        if (conv.rpConfig!.stopSequences.isNotEmpty)
          'stop': conv.rpConfig!.stopSequences,
      };
    } else {
      final opts = app.llmOptions();
      if (opts.isNotEmpty) body['options'] = opts;
    }
    // Top-level in Ollama's API, not an `options` entry. It only controls how
    // long the model stays resident, so it is orthogonal to sampling and
    // applies to roleplay requests too.
    final ka = app.llmKeepAlive.trim();
    if (ka.isNotEmpty) body['keep_alive'] = ka;
    return body;
  }

  @override
  Future<String> generateResponse(
    Conversation conv,
    List<ChatMessage> history,
  ) async {
    final client = http.Client();
    _activeClient = client;
    try {
      final headers = {'Content-Type': 'application/json'};
      if (app.apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${app.apiKey}';
      }
      final res = await client
          .post(
            Uri.parse('${app.baseUrl}/api/chat'),
            headers: headers,
            body: jsonEncode(_buildBody(conv, history, false)),
          )
          .timeout(const Duration(seconds: 60));
      if (res.statusCode == 200) {
        try {
          final data = jsonDecode(res.body);
          if (data is Map<String, dynamic>) {
            return app._extractContent(data) ?? '—';
          }
          return '—';
        } catch (_) {
          return '—';
        }
      }
      return '${app.t('serverError')} ${res.statusCode}: ${res.body}';
    } catch (e) {
      // A cancel-triggered client.close() lands here too; the caller checks
      // _genCancelled and drops this string rather than showing it.
      return '${app.t('unreachable')} ${app.baseUrl}.\n($e)\n\n${app.t('checkAddress')}';
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  @override
  Stream<String> generateStream(Conversation conv, List<ChatMessage> history) {
    final controller = StreamController<String>();
    () async {
      final headers = {'Content-Type': 'application/json'};
      if (app.apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${app.apiKey}';
      }
      final client = http.Client();
      _activeClient = client;
      final buffer = StringBuffer();
      try {
        final request = http.Request('POST', Uri.parse('${app.baseUrl}/api/chat'))
          ..headers.addAll(headers)
          ..body = jsonEncode(_buildBody(conv, history, true));
        final streamedResponse = await client
            .send(request)
            .timeout(const Duration(seconds: 60));
        if (streamedResponse.statusCode != 200) {
          final body = await streamedResponse.stream.bytesToString();
          controller.add(
            '${app.t('serverError')} ${streamedResponse.statusCode}: $body',
          );
          return;
        }
        await streamedResponse.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach((line) {
              if (line.trim().isEmpty) return;
              try {
                final data = jsonDecode(line);
                if (data is Map<String, dynamic>) {
                  final delta = app._extractContent(data);
                  if (delta != null && delta.isNotEmpty) {
                    buffer.write(delta);
                    controller.add(buffer.toString());
                  }
                }
              } catch (_) {
                // Partial/garbled line (e.g. mid-chunk on a slow
                // connection) — skip it, the stream keeps arriving.
              }
            });
      } catch (e) {
        // A cancel-triggered client.close() also lands here; only show an
        // error if nothing actually streamed yet, otherwise keep the
        // partial reply that's already on screen.
        if (buffer.isEmpty) {
          controller.add(
            '${app.t('unreachable')} ${app.baseUrl}.\n($e)\n\n${app.t('checkAddress')}',
          );
        }
      } finally {
        client.close();
        if (!controller.isClosed) await controller.close();
      }
    }();
    return controller.stream;
  }

  @override
  Future<void> stopGeneration() async {
    _activeClient?.close();
  }

  @override
  Future<void> warmUp(String modelKey) async {}
}

/// Picks the active backend purely off [isLocal] — re-evaluated on every
/// access, so it always reflects the model currently selected in settings.
class LLMServiceFactory {
  LLMServiceFactory({
    required AppState app,
    required LocalLLMService local,
    required RemoteLLMService remote,
    required bool Function() isLocal,
  }) : _app = app,
       _local = local,
       _remote = remote,
       _isLocal = isLocal;

  final AppState _app;
  final LocalLLMService _local;
  final RemoteLLMService _remote;
  final bool Function() _isLocal;

  ILLMService get current => _isLocal() ? _local : _remote;

  // RP chats may have locked in a model of a different type (local/remote)
  // than whatever is currently selected globally — `current` alone isn't
  // enough for them, it only reflects the global selector.
  ILLMService forConversation(Conversation conv) =>
      _app.isLocalModel(_effectiveModelFor(_app, conv)) ? _local : _remote;

  Future<void> warmUp(String key) =>
      _app.isLocalModel(key) ? _local.warmUp(key) : _remote.warmUp(key);
}

/// Lightweight token-count approximation for context-budget purposes —
/// deliberately cheap (no I/O), since it's meant to be safe to call on
/// every keystroke rather than just once per request. English/Latin text
/// runs roughly 4 chars/token; Cyrillic tokenizes denser (smaller share of
/// most vocabs, more multi-byte UTF-8), roughly 2.5 chars/token. Both are
/// heuristics, not exact counts — for an exact local count, use
/// [estimateForLocalModel] instead.
class TokenCounter {
  static final RegExp _cyrillic = RegExp(r'[Ѐ-ӿ]');

  static int estimate(String text) {
    if (text.isEmpty) return 0;
    final cyrillicChars = _cyrillic.allMatches(text).length;
    final charsPerToken = cyrillicChars > text.length / 2 ? 2.5 : 4.0;
    return (text.length / charsPerToken).ceil();
  }

  /// Exact count via fllama's own tokenizer for the given local GGUF —
  /// only meaningful for the local backend. Remote APIs only report token
  /// counts after the fact, in their response usage stats, so there's
  /// nothing equivalent to call ahead of a request for them. Falls back to
  /// [estimate] if the model can't be tokenized (e.g. not downloaded).
  static Future<int> estimateForLocalModel(String text, String modelPath) async {
    try {
      return await fllamaTokenize(
        FllamaTokenizeRequest(input: text, modelPath: modelPath),
      );
    } catch (_) {
      return estimate(text);
    }
  }
}

/* ============================ СОСТОЯНИЕ ============================ */

// Selectable themes. Dark palettes (dark/steam/discord) ride the color seams +
// ThemeData cleanly. Light palettes (apple/claude) also switch, but their full
// readability over the remaining hardcoded dark-assuming colors is a
// compiler-in-the-loop pass (see APPLE-THEME-TODO.md).
// Curated theme set: a neutral dark plus the two Claude editorial palettes.
// (apple/steam/discord were dropped in the design-system consolidation; a saved
// legacy value migrates to `dark` via the orElse in the prefs load.)
enum AppThemeMode { dark, claude, claudeDark }

// Liquid Glass was removed — only the standard (solid) style remains. Kept as a
// single-value enum so the appStyle field / prefs migration stay graceful.
enum AppStyle { standard }

// Real connection/readiness state of the selected model, shown by the desktop
// status badge (and its detail dialog).
enum ConnectionStatus { connecting, connected, noModel, disconnected, error }

// ---- Asset models (STT / denoise / TTS voices) — TZ2 model manager ----
// Registry of downloadable non-GGUF models. Each lives in its own dir under
// <userdata>/models/<id>/; downloads reuse downloadFileWithProgress per file.
class AssetFile {
  final String name; // filename under models/<id>/
  final String url;
  final int size; // bytes — progress weighting + display
  const AssetFile(this.name, this.url, this.size);
}

class AssetModelSpec {
  final String id; // dir under <userdata>/models/
  final String family; // 'stt' | 'denoise' | 'tts-voice'
  final String name;
  final String descKey; // i18n key, short description
  final int ramMb; // RAM estimate for display
  final List<AssetFile> files;
  final String? voiceId; // Piper voice id (tts-voice family only)
  const AssetModelSpec({
    required this.id,
    required this.family,
    required this.name,
    required this.descKey,
    required this.ramMb,
    required this.files,
    this.voiceId,
  });
  int get totalSize => files.fold(0, (a, f) => a + f.size);
}

const String _hfGigaam =
    'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-giga-am-v3-russian-2025-12-16/resolve/main';
const String _sherpaEnh =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/speech-enhancement-models';
// Self-contained Piper voice bundles (model.onnx + tokens.txt + espeak-ng-data),
// downloaded as a .tar.bz2 the sidecar extracts on first load (TZ2 block 5).
const String _sherpaTts =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';

const List<AssetModelSpec> kAssetModels = [
  AssetModelSpec(
    id: 'gigaam-v3',
    family: 'stt',
    name: 'GigaAM-v3',
    descKey: 'engGigaamShort',
    ramMb: 800,
    files: [
      AssetFile('encoder.int8.onnx', '$_hfGigaam/encoder.int8.onnx', 224570814),
      AssetFile('decoder.onnx', '$_hfGigaam/decoder.onnx', 3331651),
      AssetFile('joiner.onnx', '$_hfGigaam/joiner.onnx', 1440448),
      AssetFile('tokens.txt', '$_hfGigaam/tokens.txt', 196),
    ],
  ),
  AssetModelSpec(
    id: 'denoise-gtcrn',
    family: 'denoise',
    name: 'GTCRN (лёгкое)',
    descKey: 'dnLightShort',
    ramMb: 60,
    files: [AssetFile('gtcrn_simple.onnx', '$_sherpaEnh/gtcrn_simple.onnx', 535638)],
  ),
  AssetModelSpec(
    id: 'denoise-df',
    family: 'denoise',
    name: 'DeepFilterNet (сильное)',
    descKey: 'dnStrongShort',
    ramMb: 200,
    files: [
      AssetFile('dpdfnet_baseline.onnx',
          '$_sherpaEnh/dpdfnet_baseline.onnx', 8791035),
    ],
  ),
  // Piper TTS voices (ru_RU). Each is a self-contained sherpa bundle.
  AssetModelSpec(
    id: 'tts-irina',
    family: 'tts-voice',
    name: 'Ирина',
    descKey: 'voiceIrina',
    ramMb: 120,
    voiceId: 'ru_RU-irina-medium',
    files: [
      AssetFile('vits-piper-ru_RU-irina-medium.tar.bz2',
          '$_sherpaTts/vits-piper-ru_RU-irina-medium.tar.bz2', 67153308),
    ],
  ),
  AssetModelSpec(
    id: 'tts-denis',
    family: 'tts-voice',
    name: 'Денис',
    descKey: 'voiceDenis',
    ramMb: 120,
    voiceId: 'ru_RU-denis-medium',
    files: [
      AssetFile('vits-piper-ru_RU-denis-medium.tar.bz2',
          '$_sherpaTts/vits-piper-ru_RU-denis-medium.tar.bz2', 67190991),
    ],
  ),
  AssetModelSpec(
    id: 'tts-dmitri',
    family: 'tts-voice',
    name: 'Дмитрий',
    descKey: 'voiceDmitri',
    ramMb: 120,
    voiceId: 'ru_RU-dmitri-medium',
    files: [
      AssetFile('vits-piper-ru_RU-dmitri-medium.tar.bz2',
          '$_sherpaTts/vits-piper-ru_RU-dmitri-medium.tar.bz2', 67188551),
    ],
  ),
  AssetModelSpec(
    id: 'tts-ruslan',
    family: 'tts-voice',
    name: 'Руслан',
    descKey: 'voiceRuslan',
    ramMb: 120,
    voiceId: 'ru_RU-ruslan-medium',
    files: [
      AssetFile('vits-piper-ru_RU-ruslan-medium.tar.bz2',
          '$_sherpaTts/vits-piper-ru_RU-ruslan-medium.tar.bz2', 67210684),
    ],
  ),
];


final ValueNotifier<(String, String, int)?> vizNotice = ValueNotifier(null);


/* ----------------------- EVS DESKTOP SETTINGS ----------------------------
   Left-nav settings with 7 sections (evs_s1..s7.html). Controls bind to the
   existing AppState/Personalization; genuinely-new areas are shown as UI with
   stub state until their native phase lands. */

// A user-defined voice command (Voice Commands catalog). Execution comes in
// the native phase; the type maps to how `value` is interpreted.
// A phone authorized to send remote commands (TZ §14). The token is a secret —
// shown masked in the UI, matched verbatim by the server. lastSeen is ISO-8601
// or '' if never seen.
