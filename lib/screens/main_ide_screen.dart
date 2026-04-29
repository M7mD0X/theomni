import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/app_mode_service.dart';
import '../services/agent_service.dart';
import '../theme/omni_theme.dart';
import '../widgets/top_bar.dart';
import '../widgets/sidebar.dart';
import '../widgets/editor_view.dart';
import '../widgets/agent_panel.dart';
import 'settings_screen.dart';

class MainIDEScreen extends StatefulWidget {
  const MainIDEScreen({super.key});

  @override
  State<MainIDEScreen> createState() => _MainIDEScreenState();
}

class _MainIDEScreenState extends State<MainIDEScreen>
    with TickerProviderStateMixin {
  static const _guardian = MethodChannel('com.omniide/guardian');

  bool _sidebarOpen = false;
  bool _guardianOn = false;
  bool _agentPanelVisible = true;
  double _splitFraction = 0.58;

  final List<OpenFile> _files = [];
  int _activeFile = 0;

  // Track dirty state for each file
  final Set<String> _dirtyFiles = {};

  late AnimationController _sidebarCtrl;
  late AnimationController _entryCtrl;

  // Save trigger — EditorView listens to this
  final ValueNotifier<int> _saveNotifier = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _sidebarCtrl = AnimationController(
      vsync: this,
      duration: T.dMed,
      value: 0.0,
    );
    _entryCtrl = AnimationController(
      vsync: this,
      duration: T.dSlow,
    )..forward();
    _startGuardian();
  }

  @override
  void dispose() {
    _sidebarCtrl.dispose();
    _entryCtrl.dispose();
    _saveNotifier.dispose();
    super.dispose();
  }

  Future<void> _startGuardian() async {
    try {
      final modeSvc = context.read<AppModeService>();
      await _guardian.invokeMethod('startGuardian', {
        'localMode': modeSvc.mode == AppMode.local,
      });
      if (mounted) setState(() => _guardianOn = true);
    } catch (_) {}
  }

  void _toggleSidebar() {
    setState(() => _sidebarOpen = !_sidebarOpen);
    _sidebarOpen ? _sidebarCtrl.forward() : _sidebarCtrl.reverse();
  }

  void _toggleAgentPanel() {
    setState(() => _agentPanelVisible = !_agentPanelVisible);
  }

  void _openFile(String path, String name, String content) {
    final idx = _files.indexWhere((f) => f.path == path);
    if (idx >= 0) {
      setState(() => _activeFile = idx);
      return;
    }
    setState(() {
      _files.add(OpenFile(path: path, name: name, content: content));
      _activeFile = _files.length - 1;
      if (MediaQuery.of(context).size.width < 720) {
        _sidebarOpen = false;
        _sidebarCtrl.reverse();
      }
    });
  }

  void _closeFile(int i) {
    setState(() {
      _dirtyFiles.remove(_files[i].path);
      _files.removeAt(i);
      if (_activeFile >= _files.length) {
        _activeFile = _files.length - 1;
      }
    });
  }

  void _handleContentChanged(String path, String newContent) {
    final idx = _files.indexWhere((f) => f.path == path);
    if (idx >= 0) {
      final isDirty = newContent != _files[idx].content;
      final wasDirty = _dirtyFiles.contains(path);
      // Only setState when dirty state actually changes — avoids per-keystroke rebuild
      if (isDirty && !wasDirty) {
        _dirtyFiles.add(path);
        if (mounted) setState(() {});
      } else if (!isDirty && wasDirty) {
        _dirtyFiles.remove(path);
        if (mounted) setState(() {});
      }
    }
  }

  bool get _hasDirtyFile =>
      _files.isNotEmpty && _dirtyFiles.contains(_files[_activeFile].path);

  void _saveCurrentFile() {
    _saveNotifier.value++;
  }

  Future<bool> _onWillPop() async {
    final hasUnsaved = _dirtyFiles.isNotEmpty;
    if (!hasUnsaved) return true;

    final dirtyNames = _dirtyFiles
        .map((p) => _files.where((f) => f.path == p).map((f) => f.name))
        .expand((names) => names)
        .join(', ');

    final result = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => AlertDialog(
        backgroundColor: T.s1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.r_lg),
          side: const BorderSide(color: T.border),
        ),
        title: const Text('Unsaved changes', style: TextStyle(color: T.coral)),
        content: Text(
          'You have unsaved changes in: $dirtyNames.\nDiscard and exit?',
          style: T.ui(size: 13, color: T.dim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('cancel', style: T.ui(size: 12, color: T.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('discard', style: T.ui(size: 12, color: T.coral, weight: FontWeight.w600)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    const double sidebarWidth = 296;
    final overlayWidth =
        width < sidebarWidth + 80 ? width * 0.86 : sidebarWidth.toDouble();

    // Account for status bar in the app bar preferred size
    final topInset = MediaQuery.of(context).padding.top;

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: T.bg,
        resizeToAvoidBottomInset: false,
        appBar: PreferredSize(
          preferredSize: Size.fromHeight(52 + topInset),
          child: TopBar(
            filename: _files.isEmpty ? null : _files[_activeFile].name,
            guardianRunning: _guardianOn,
            sidebarOpen: _sidebarOpen,
            hasDirtyFile: _hasDirtyFile,
            onMenuTap: _toggleSidebar,
            onSave: _files.isNotEmpty ? _saveCurrentFile : null,
            onSettingsTap: () => Navigator.push(
              context,
              PageRouteBuilder(
                transitionDuration: T.dSlow,
                pageBuilder: (_, a, __) => const SettingsScreen(),
                transitionsBuilder: (_, anim, __, child) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.04),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(parent: anim, curve: T.eOut)),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
        body: FadeTransition(
          opacity: _entryCtrl,
          child: LayoutBuilder(
            builder: (ctx, c) {
              final totalH = c.maxHeight;
              final editorH = totalH * _splitFraction;
              return Stack(
                children: [
                  // When agent panel is hidden, editor takes full height
                  if (!_agentPanelVisible)
                    SizedBox.expand(
                      child: EditorView(
                        files: _files,
                        activeIndex: _activeFile,
                        onTabTap: (i) => setState(() => _activeFile = i),
                        onTabClose: _closeFile,
                        onContentChanged: _handleContentChanged,
                        saveNotifier: _saveNotifier,
                      ),
                    )
                  else
                    Column(
                      children: [
                        SizedBox(
                          height: editorH,
                          child: EditorView(
                            files: _files,
                            activeIndex: _activeFile,
                            onTabTap: (i) => setState(() => _activeFile = i),
                            onTabClose: _closeFile,
                            onContentChanged: _handleContentChanged,
                            saveNotifier: _saveNotifier,
                          ),
                        ),
                        _SplitHandle(
                          onDrag: (dy) {
                            setState(() {
                              _splitFraction =
                                  (_splitFraction + dy / totalH).clamp(0.22, 0.82);
                            });
                          },
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Container(
                                height: 36,
                                color: T.s1,
                                child: Row(
                                  children: [
                                    const SizedBox(width: T.s_4),
                                    Text(
                                      'AGENT',
                                      style: T.label(color: T.accent),
                                    ),
                                    const Spacer(),
                                  ],
                                ),
                              ),
                              Container(height: 1, color: T.border),
                              const Expanded(
                                child: AgentPanel(key: ValueKey('a')),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                  // Scrim behind the floating sidebar
                  // Only listen to animation while sidebar is transitioning
                  IgnorePointer(
                    ignoring: !_sidebarOpen,
                    child: _sidebarCtrl.isAnimating || _sidebarOpen
                        ? AnimatedBuilder(
                            animation: _sidebarCtrl,
                            builder: (_, __) => GestureDetector(
                              onTap: _toggleSidebar,
                              child: Container(
                                color: Colors.black
                                    .withValues(alpha: 0.42 * _sidebarCtrl.value),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),

                  // Sliding sidebar overlay
                  _sidebarOpen || _sidebarCtrl.isAnimating
                      ? AnimatedBuilder(
                          animation: _sidebarCtrl,
                          builder: (_, child) {
                            final t = Curves.easeOutCubic.transform(_sidebarCtrl.value);
                            return Transform.translate(
                              offset: Offset(-overlayWidth * (1 - t), 0),
                              child: child,
                            );
                          },
                          child: SizedBox(
                            width: overlayWidth,
                            height: totalH,
                            child: Material(
                              elevation: 14,
                              color: T.s1,
                              shadowColor: Colors.black.withValues(alpha: 0.6),
                              child: SidebarWidget(onFileOpen: _openFile),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),

                  // Floating toggle button for agent panel
                  Positioned(
                    bottom: 16,
                    right: 16,
                    child: GestureDetector(
                      onTap: _toggleAgentPanel,
                      child: AnimatedContainer(
                        duration: T.dFast,
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _agentPanelVisible ? T.s2 : T.accent,
                          borderRadius: BorderRadius.circular(T.r_md),
                          border: Border.all(
                            color: _agentPanelVisible ? T.border : T.accent,
                            width: 0.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          _agentPanelVisible
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.smart_toy_rounded,
                          size: 20,
                          color: _agentPanelVisible ? T.dim : T.bg,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ── Split handle ─────────────────────────────────────────────────────────
class _SplitHandle extends StatefulWidget {
  final Function(double dy) onDrag;
  const _SplitHandle({required this.onDrag});

  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: (d) => widget.onDrag(d.delta.dy),
        child: AnimatedContainer(
          duration: T.dFast,
          height: 8,
          color: _hover ? T.s2 : T.s1,
          child: Center(
            child: Container(
              width: 36,
              height: 2,
              decoration: BoxDecoration(
                color: _hover ? T.accent : T.border,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
