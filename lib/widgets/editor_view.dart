import 'package:flutter/material.dart';
import '../theme/omni_theme.dart';

class OpenFile {
  final String path;
  final String name;
  String content;
  OpenFile({required this.path, required this.name, required this.content});
}

class EditorView extends StatefulWidget {
  final List<OpenFile> files;
  final int activeIndex;
  final Function(int) onTabTap;
  final Function(int) onTabClose;

  const EditorView({
    super.key,
    required this.files,
    required this.activeIndex,
    required this.onTabTap,
    required this.onTabClose,
  });

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, ScrollController> _scrolls = {};

  TextEditingController _ctrl(OpenFile f) {
    return _ctrls.putIfAbsent(
      f.path,
      () => TextEditingController(text: f.content),
    );
  }

  ScrollController _scroll(OpenFile f) {
    return _scrolls.putIfAbsent(f.path, () => ScrollController());
  }

  @override
  void didUpdateWidget(EditorView old) {
    super.didUpdateWidget(old);
    // Clean controllers for closed files
    final openPaths = widget.files.map((f) => f.path).toSet();
    _ctrls.keys.toList().forEach((k) {
      if (!openPaths.contains(k)) {
        _ctrls[k]?.dispose();
        _ctrls.remove(k);
        _scrolls[k]?.dispose();
        _scrolls.remove(k);
      }
    });
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final s in _scrolls.values) {
      s.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) {
      return const WelcomeView();
    }
    final active = widget.files[widget.activeIndex];
    return Column(
      children: [
        _TabStrip(
          files: widget.files,
          active: widget.activeIndex,
          onTap: widget.onTabTap,
          onClose: widget.onTabClose,
        ),
        Container(height: 1, color: T.border),
        Expanded(
          child: _CodeCanvas(
            key: ValueKey(active.path),
            ctrl: _ctrl(active),
            scroll: _scroll(active),
          ),
        ),
      ],
    );
  }
}

// ── Tab strip ────────────────────────────────────────────────────────────
class _TabStrip extends StatelessWidget {
  final List<OpenFile> files;
  final int active;
  final Function(int) onTap;
  final Function(int) onClose;

  const _TabStrip({
    required this.files,
    required this.active,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      color: T.s1,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: files.length,
        itemBuilder: (_, i) => _Tab(
          file: files[i],
          active: i == active,
          onTap: () => onTap(i),
          onClose: () => onClose(i),
        ),
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  final OpenFile file;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  const _Tab({
    required this.file,
    required this.active,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: T.dFast,
          padding: const EdgeInsets.symmetric(horizontal: T.s_3),
          decoration: BoxDecoration(
            color: widget.active ? T.bg : (_hover ? T.s2 : Colors.transparent),
            border: Border(
              bottom: BorderSide(
                color: widget.active ? T.accent : Colors.transparent,
                width: 1.5,
              ),
              right: const BorderSide(color: T.border),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(T.fileIcon(widget.file.name),
                  size: 12, color: T.fileColor(widget.file.name)),
              const SizedBox(width: 7),
              Text(
                widget.file.name,
                style: T.mono(
                  size: 12,
                  color: widget.active ? T.text : T.dim,
                ),
              ),
              const SizedBox(width: T.s_2),
              GestureDetector(
                onTap: widget.onClose,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: _hover ? T.s3 : Colors.transparent,
                    borderRadius: BorderRadius.circular(T.r_sm),
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 11,
                    color: widget.active ? T.dim : T.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Code canvas ──────────────────────────────────────────────────────────
class _CodeCanvas extends StatelessWidget {
  final TextEditingController ctrl;
  final ScrollController scroll;
  const _CodeCanvas({super.key, required this.ctrl, required this.scroll});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: T.bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Gutter(ctrl: ctrl),
          Container(width: 1, color: T.border),
          Expanded(
            child: TextField(
              controller: ctrl,
              scrollController: scroll,
              maxLines: null,
              expands: true,
              style: T.mono(size: 13, color: T.text, height: 1.6),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.fromLTRB(14, 12, 14, 12),
              ),
              keyboardType: TextInputType.multiline,
              cursorColor: T.accent,
              cursorWidth: 2,
            ),
          ),
        ],
      ),
    );
  }
}

class _Gutter extends StatefulWidget {
  final TextEditingController ctrl;
  const _Gutter({required this.ctrl});

  @override
  State<_Gutter> createState() => _GutterState();
}

class _GutterState extends State<_Gutter> {
  int _lines = 1;

  @override
  void initState() {
    super.initState();
    widget.ctrl.addListener(_update);
    _update();
  }

  void _update() {
    final n = '\n'.allMatches(widget.ctrl.text).length + 1;
    if (n != _lines) setState(() => _lines = n);
  }

  @override
  void dispose() {
    widget.ctrl.removeListener(_update);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      color: T.s1,
      padding: const EdgeInsets.only(top: 12, right: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(
          _lines,
          (i) => Text(
            '${i + 1}',
            style: T.mono(size: 11.5, color: T.faint, height: 1.82),
          ),
        ),
      ),
    );
  }
}

// ── Welcome (no files open) ──────────────────────────────────────────────
class WelcomeView extends StatelessWidget {
  const WelcomeView({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: T.bg,
      child: Stack(
        children: [
          // Background grain dots
          Positioned.fill(
            child: CustomPaint(painter: _DotGrid()),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(T.s_5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'a pocket-sized',
                    style: T.ui(size: 12, color: T.muted, letterSpacing: 2),
                  ),
                  const SizedBox(height: T.s_2),
                  RichText(
                    text: TextSpan(children: [
                      TextSpan(
                        text: 'development ',
                        style: T.display(
                          size: 42,
                          weight: FontWeight.w500,
                          color: T.text,
                        ),
                      ),
                      TextSpan(
                        text: 'environment.',
                        style: T.display(
                          size: 42,
                          weight: FontWeight.w400,
                          color: T.accent,
                          style: FontStyle.italic,
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: T.s_4),
                  Container(
                    width: 220,
                    height: 1,
                    color: T.border,
                  ),
                  const SizedBox(height: T.s_4),
                  _HintRow(
                    label: 'open a file',
                    hint: 'from the sidebar',
                  ),
                  _HintRow(
                    label: 'ask the agent',
                    hint: 'panel below',
                  ),
                  _HintRow(
                    label: 'configure keys',
                    hint: 'settings · top right',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HintRow extends StatelessWidget {
  final String label;
  final String hint;
  const _HintRow({required this.label, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 1,
            color: T.accent,
          ),
          const SizedBox(width: T.s_3),
          Text(label,
              style: T.ui(size: 13, weight: FontWeight.w500, color: T.text)),
          const SizedBox(width: T.s_3),
          Text(hint, style: T.mono(size: 11, color: T.muted)),
        ],
      ),
    );
  }
}

class _DotGrid extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = T.border.withOpacity(0.5);
    const step = 28.0;
    for (double x = step; x < size.width; x += step) {
      for (double y = step; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.6, p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
