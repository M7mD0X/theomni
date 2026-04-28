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
  double _splitFraction = 0.58;

  final List<OpenFile> _files = [];
  int _activeFile = 0;

  // Track dirty state for each file
  final Set<String> _dirtyFiles = {};

  late AnimationController _sidebarCtrl;
  late AnimationController _entryCtrl;

  // Keep a reference to the EditorView's state for save support
  final GlobalKey<EditorViewExposedState> _editorKey = GlobalKey();

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
      if (isDirty) {
        _dirtyFiles.add(path);
      } else {
        _dirtyFiles.remove(path);
      }
      if (mounted) setState(() {});
    }
  }

  bool get _hasDirtyFile =>
      _files.isNotEmpty && _dirtyFiles.contains(_files[_activeFile].path);

  void _saveCurrentFile() {
    _editorKey.currentState?.saveCurrentFile();
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
            child: const Text('cancel', style: T.ui(size: 12, color: T.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('discard', style: T.ui(size: 12, color: T.coral, weight: FontWeight.w600)),
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

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: T.bg,
        appBar: TopBar(
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
        body: FadeTransition(
          opacity: _entryCtrl,
          child: LayoutBuilder(
            builder: (ctx, c) {
              final totalH = c.maxHeight;
              final editorH = totalH * _splitFraction;
              return Stack(
                children: [
                  Column(
                    children: [
                      SizedBox(
                        height: editorH,
                        child: EditorViewExposed(
                          key: _editorKey,
                          files: _files,
                          activeIndex: _activeFile,
                          onTabTap: (i) => setState(() => _activeFile = i),
                          onTabClose: _closeFile,
                          onContentChanged: _handleContentChanged,
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
                            // Single "Agent" tab — terminal hidden until functional
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
                  IgnorePointer(
                    ignoring: !_sidebarOpen,
                    child: AnimatedBuilder(
                      animation: _sidebarCtrl,
                      builder: (_, __) => GestureDetector(
                        onTap: _toggleSidebar,
                        child: Container(
                          color: Colors.black
                              .withOpacity(0.42 * _sidebarCtrl.value),
                        ),
                      ),
                    ),
                  ),

                  // Sliding sidebar overlay
                  AnimatedBuilder(
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
                        shadowColor: Colors.black.withOpacity(0.6),
                        child: SidebarWidget(onFileOpen: _openFile),
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

// ── Editor wrapper that exposes save method ──────────────────────────────
class EditorViewExposed extends StatefulWidget {
  final List<OpenFile> files;
  final int activeIndex;
  final Function(int) onTabTap;
  final Function(int) onTabClose;
  final void Function(String path, String newContent)? onContentChanged;

  const EditorViewExposed({
    super.key,
    required this.files,
    required this.activeIndex,
    required this.onTabTap,
    required this.onTabClose,
    this.onContentChanged,
  });

  @override
  State<EditorViewExposed> createState() => EditorViewExposedState();
}

class EditorViewExposedState extends State<EditorViewExposed> {
  @override
  Widget build(BuildContext context) {
    return EditorView(
      files: widget.files,
      activeIndex: widget.activeIndex,
      onTabTap: widget.onTabTap,
      onTabClose: widget.onTabClose,
      onContentChanged: widget.onContentChanged,
    );
  }

  /// Public method that forwards to the inner EditorView's save logic.
  /// This is a simplified approach — the real save happens inside
  /// EditorView's state via NativeFileService.
  void saveCurrentFile() {
    // The EditorView handles its own save via NativeFileService.
    // This method can be extended if we need external trigger.
    // For now the save button is wired inside EditorView's tab strip.
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
