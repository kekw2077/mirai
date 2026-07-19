part of '../main.dart';

String _evsRelTime(AppState app, DateTime dt) {
  final now = DateTime.now();
  if (now.difference(dt).inMinutes < 1) return app.t('justNow');
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(dt.year, dt.month, dt.day);
  String two(int n) => n.toString().padLeft(2, '0');
  if (that == today) return '${two(dt.hour)}:${two(dt.minute)}';
  if (that == today.subtract(const Duration(days: 1))) return app.t('yesterday');
  return '${dt.day}.${two(dt.month)}';
}

// Executes user-defined voice commands on Windows. Launching apps/files/URLs
// and running shell commands go through dart:io Process; media and volume keys
// use Win32 keybd_event (user32) via FFI. Phrase matching is deterministic
// (exact -> contains -> token overlap); semantic matching is the sidecar's job.

class _RootHome extends StatelessWidget {
  const _RootHome();
  @override
  Widget build(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.windows
      ? const DesktopHome()
      : const ChatScreen();
}

class DesktopHome extends StatelessWidget {
  const DesktopHome({super.key});
  @override
  Widget build(BuildContext context) {
    // Subscribe the shell to theme changes. Every colour token resolves through
    // `_pal(context)` which uses `context.read` (no subscription), and this
    // widget is `const`, so without an explicit dependency the shell background
    // (_bg / _evsShellBg) was computed once and never repainted when themeMode
    // changed (live theme switch, or the async prefs load right after startup) —
    // leaving a stale dark shell behind the transparent chat area while the
    // sidebar/content (which do watch) followed the theme. Rebuild on themeMode.
    context.select<AppState, AppThemeMode>((a) => a.themeMode);
    return Scaffold(
      backgroundColor: _bg(context),
      body: Container(
        decoration: _evsShellBg(context),
        // The sidebar spans the FULL window height (its themed surface reaches
        // the very top), and the window title bar sits only over the main
        // content — so the top of the window reads as two colours (cream rail on
        // the left, the page background on the right) instead of one strip above
        // a shorter sidebar.
        child: const Row(
          children: [
            _DesktopSidebar(),
            Expanded(
              child: Column(
                children: [
                  _WindowTitleBar(),
                  Expanded(child: ChatScreen(desktop: true)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar();

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DesktopSettings()),
    );
  }

  Widget _iconBtn(BuildContext context, IconData icon, VoidCallback onTap,
      {String? tooltip}) {
    final btn = InkResponse(
      radius: 22,
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _overlayFill(context, 0.042),
          border: Border.all(color: _stroke(context)),
        ),
        child: Icon(icon, size: 15, color: _sub(context)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final convs = app.conversations;
    return Container(
      width: 264,
      decoration: _evsRailBg(context),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 20, 14, 16),
              child: Row(
                children: [
                  // The sidebar now reaches the top of the window, so its header
                  // doubles as the drag area (the window title bar sits only over
                  // the main content). Buttons stay outside the drag region.
                  Expanded(
                    child: DragToMoveArea(
                      child: Row(
                        children: [
                          const _EvsLogoMark(),
                          const SizedBox(width: 9),
                          Text(
                            'EVS',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                              color: _txt(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _iconBtn(context, Icons.settings_outlined,
                      () => _openSettings(context),
                      tooltip: app.t('settings')),
                  const SizedBox(width: 8),
                  _iconBtn(context, Icons.add, () {
                    app.buzz();
                    app.newChat();
                  }, tooltip: app.t('newChat')),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: Text(
                'ИСТОРИЯ',
                style: EvsType.sectionLabel
                    .copyWith(letterSpacing: 0.9, color: _sectionLabel(context)),
              ),
            ),
            Expanded(
              child: convs.isEmpty
                  ? const SizedBox.shrink()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      itemCount: convs.length,
                      itemBuilder: (_, i) {
                        final c = convs[i];
                        final active = c.id == app.current?.id;
                        return _historyItem(context, app, c, active);
                      },
                    ),
            ),
            Divider(color: _divider(context), height: 1, indent: 10, endIndent: 10),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 14, 10, 0),
              child: _DesktopSystemWidget(),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 10, 10, 12),
              child: _DesktopMicWidget(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyItem(
      BuildContext context, AppState app, Conversation c, bool active) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      // Right-click anywhere on the row → context menu (rename / pin / delete).
      // Desktop uses mouse, so this replaces the old mobile long-press.
      child: GestureDetector(
        onSecondaryTapDown: (d) =>
            showChatContextMenu(context, d.globalPosition, c, app),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              app.buzz();
              app.openChat(c);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: active
                    ? _accent(context).withValues(alpha: 0.10)
                    : Colors.transparent,
                border: Border.all(
                  color: active ? _accent(context).withValues(alpha: 0.2) : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(9),
                      color: _overlayFill(context, 0.042),
                    ),
                    child: Icon(
                        c.pinned
                            ? Icons.push_pin
                            : Icons.chat_bubble_outline,
                        size: 13,
                        color: _sub(context)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: _txt(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _evsRelTime(app, c.updatedAt),
                          style: TextStyle(fontSize: 11.5, color: _faint(context)),
                        ),
                      ],
                    ),
                  ),
                  // Visible affordance for users who don't try right-click.
                  Builder(
                    builder: (btnCtx) => InkResponse(
                      radius: 16,
                      onTap: () {
                        final box =
                            btnCtx.findRenderObject() as RenderBox?;
                        final pos = box != null
                            ? box.localToGlobal(box.size.center(Offset.zero))
                            : Offset.zero;
                        showChatContextMenu(context, pos, c, app);
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(Icons.more_vert,
                            size: 16, color: _faint(context)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Shared chat context menu (rename / pin / delete-with-undo), anchored at [pos]
// (global coords). Top-level so both the ConversationsSheet rows AND the
// desktop sidebar history items can use it. Glass mode uses the blurred glass
// menu; standard mode uses showMenu.
Future<void> showChatContextMenu(
    BuildContext ctx, Offset pos, Conversation c, AppState app) async {
  void handle(String? v) {
    if (v == 'rename') promptRenameChat(ctx, c, app);
    if (v == 'pin') app.togglePin(c);
    if (v == 'delete') deleteChatWithUndo(ctx, c, app);
  }

  if (_isGlass(ctx)) {
    final v = await showGlassMenu(
      ctx,
      position: pos,
      items: [
        GlassMenuItem('rename', app.t('rename')),
        GlassMenuItem('pin', c.pinned ? app.t('unpin') : app.t('pin')),
        GlassMenuItem('delete', app.t('delete'), color: Colors.redAccent),
      ],
    );
    handle(v);
    return;
  }
  final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox?;
  final v = await showMenu<String>(
    context: ctx,
    color: _card(ctx),
    position: RelativeRect.fromRect(
      Rect.fromPoints(pos, pos),
      Offset.zero & (overlay?.size ?? const Size(0, 0)),
    ),
    items: [
      PopupMenuItem(
        value: 'rename',
        child: Text(app.t('rename'), style: TextStyle(color: _txt(ctx))),
      ),
      PopupMenuItem(
        value: 'pin',
        child: Text(c.pinned ? app.t('unpin') : app.t('pin'),
            style: TextStyle(color: _txt(ctx))),
      ),
      PopupMenuItem(
        value: 'delete',
        child: Text(app.t('delete'),
            style: const TextStyle(color: Colors.redAccent)),
      ),
    ],
  );
  handle(v);
}

// Delete a chat but offer a few seconds to undo (deletes are otherwise
// irreversible — easy to hit by accident from the context menu).
void deleteChatWithUndo(BuildContext ctx, Conversation c, AppState app) {
  app.deleteChat(c);
  final messenger = ScaffoldMessenger.of(ctx);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    backgroundColor: _card(ctx),
    duration: const Duration(seconds: 4),
    content: Text(app.t('chatDeleted'), style: TextStyle(color: _txt(ctx))),
    action: SnackBarAction(
      label: app.t('undo'),
      textColor: _accent(ctx),
      onPressed: () => app.undoDeleteChat(),
    ),
  ));
}

// Rename dialog for a chat. Pre-fills the current title; saving an empty title
// is a no-op (keeps the old one).
void promptRenameChat(BuildContext ctx, Conversation c, AppState app) {
  final ctrl = TextEditingController(text: c.title);
  showDialog(
    context: ctx,
    builder: (dialogContext) => _AppDialog(
      backgroundColor:
          _isGlass(ctx) ? _card(ctx).withValues(alpha: 0.9) : _card(ctx),
      title: Text(app.t('renameChat'), style: TextStyle(color: _txt(ctx))),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        style: TextStyle(color: _txt(ctx)),
        decoration: InputDecoration(
          hintText: app.t('renameChatHint'),
          hintStyle: TextStyle(color: _sub(ctx)),
        ),
        onSubmitted: (_) {
          app.renameChat(c, ctrl.text);
          Navigator.pop(dialogContext);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(app.t('cancel')),
        ),
        TextButton(
          onPressed: () {
            app.renameChat(c, ctrl.text);
            Navigator.pop(dialogContext);
          },
          child: Text(app.t('save')),
        ),
      ],
    ),
  );
}

// System monitor widget — live CPU/RAM from SystemMonitor (Win32 FFI). VRAM
// has no reliable cross-vendor API, so it stays "—".
class _DesktopSystemWidget extends StatelessWidget {
  const _DesktopSystemWidget();

  String _gb(int bytes, {int digits = 1}) =>
      (bytes / (1024 * 1024 * 1024)).toStringAsFixed(digits);

  Widget _bar(BuildContext context, String name, String value, double frac,
      List<Color> grad, Color numColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(name,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _sub(context))),
              Text(value,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: numColor)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 5,
              backgroundColor: _overlayFill(context, 0.1),
              valueColor: AlwaysStoppedAnimation(grad.first),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: _overlayFill(context, 0.042),
        border: Border.all(color: _stroke(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Text('СИСТЕМА',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: _sub(context))),
          ),
          ValueListenableBuilder<SystemStats>(
            valueListenable: SystemMonitor.instance.stats,
            builder: (_, s, __) {
              final active = s.totalRamBytes > 0;
              final ramTxt = active
                  ? '${_gb(s.usedRamBytes)} / ${_gb(s.totalRamBytes, digits: 0)} GB'
                  : '—';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _bar(context, 'CPU',
                      active ? '${(s.cpu * 100).round()}%' : '—', s.cpu,
                      [_accent(context)], _accent(context)),
                  _bar(context, 'RAM', ramTxt, s.ram,
                      [_info(context)], _info(context)),
                  _bar(context, 'VRAM', '—', 0.0, [_warn(context)],
                      _warn(context)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// Combined live audio level driving every voice visualization: microphone
// input (MicMeter) + TTS playback level (`tts.level` events streamed by the
// sidecars while the assistant speaks). Keeps a short rolling history so the
// bar/ring visualizers show a real moving waveform, not a canned loop.
/// Transient notice shown on the floating widget (command executed/failed …):
/// (text, kind 'ok'|'err'|'info', timestamp-ms). Set by the widget process's
/// WS client on `note` messages; auto-expires in _VaStageBadge.
