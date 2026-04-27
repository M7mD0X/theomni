import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/app_mode_service.dart';
import '../theme/omni_theme.dart';
import '../widgets/top_bar.dart';
import '../widgets/sidebar.dart';
import '../widgets/editor_view.dart';
import '../widgets/agent_panel.dart';
import '../widgets/terminal_panel.dart';
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
  int _bottomTab = 1; // 0 = terminal, 1 = agent
  double _splitFraction = 0.58; // editor takes this share, agent panel rest

  final List<OpenFile> _files = [];
  int _activeFile = 0;

  late AnimationController _sidebarCtrl;
  late AnimationController _entryCtrl;

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
      // Only spawn the agent process when the user has explicitly opted into
      // Local Mode. In Cloud Mode the foreground service still starts (so the
      // app is properly user-visible), but no Node process is launched.
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
      _files.removeAt(i);
      if (_activeFile >= _files.length) {
        _activeFile = _files.length - 1;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    // Sidebar should overlay (not push) on phones AND tablets — keeps the editor
    // canvas full-width at all times. On very wide desktops we still overlay,
    // matching the user's request "sidebar shows over the editor".
    const double sidebarWidth = 296; // 48 rail + 248 content
    final overlayWidth =
        width < sidebarWidth + 80 ? width * 0.86 : sidebarWidth.toDouble();

    return Scaffold(
      backgroundColor: T.bg,
      appBar: TopBar(
        filename: _files.isEmpty ? null : _files[_activeFile].name,
        guardianRunning: _guardianOn,
        sidebarOpen: _sidebarOpen,
        onMenuTap: _toggleSidebar,
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
                // ── Editor + bottom-panel column (full width, never pushed) ─
                Column(
                  children: [
                    SizedBox(
                      height: editorH,
                      child: EditorView(
                        files: _files,
                        activeIndex: _activeFile,
                        onTabTap: (i) => setState(() => _activeFile = i),
                        onTabClose: _closeFile,
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
                          _PanelTabBar(
                            selected: _bottomTab,
                            onTap: (i) => setState(() => _bottomTab = i),
                          ),
                          Container(height: 1, color: T.border),
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: T.dMed,
                              switchInCurve: T.eOut,
                              child: _bottomTab == 0
                                  ? const TerminalPanel(key: ValueKey('t'))
                                  : const AgentPanel(key: ValueKey('a')),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // ── Scrim behind the floating sidebar ─────────────────────
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

                // ── Sliding sidebar overlay ────────────────────────────────
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

// ── Panel tab bar ────────────────────────────────────────────────────────
class _PanelTabBar extends StatelessWidget {
  final int selected;
  final Function(int) onTap;
  const _PanelTabBar({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      color: T.s1,
      child: Row(
        children: [
          _PTab(label: 'TERMINAL', index: 0, selected: selected, onTap: onTap),
          _PTab(label: 'AGENT', index: 1, selected: selected, onTap: onTap),
          const Spacer(),
        ],
      ),
    );
  }
}

class _PTab extends StatefulWidget {
  final String label;
  final int index;
  final int selected;
  final Function(int) onTap;
  const _PTab({
    required this.label,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_PTab> createState() => _PTabState();
}

class _PTabState extends State<_PTab> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final active = widget.selected == widget.index;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => widget.onTap(widget.index),
        child: AnimatedContainer(
          duration: T.dFast,
          padding: const EdgeInsets.symmetric(horizontal: T.s_4),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? T.accent : Colors.transparent,
                width: 1.5,
              ),
            ),
          ),
          child: Center(
            child: Text(
              widget.label,
              style: T.label(
                color: active ? T.accent : (_hover ? T.dim : T.muted),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
