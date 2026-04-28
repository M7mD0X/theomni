import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import '../theme/omni_theme.dart';
import '../services/native_file_service.dart';

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
  final Function(String path, String content)? onSave;
  final Function(String path, String newContent)? onContentChanged;

  const EditorView({
    super.key,
    required this.files,
    required this.activeIndex,
    required this.onTabTap,
    required this.onTabClose,
    this.onSave,
    this.onContentChanged,
  });

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> with WidgetsBindingObserver {
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, ScrollController> _scrolls = {};
  final Map<String, String> _originalContent = {};
  final Map<String, Timer> _autoSaveTimers = {};

  TextEditingController _ctrl(OpenFile f) {
    return _ctrls.putIfAbsent(
      f.path,
      () {
        final ctrl = TextEditingController(text: f.content);
        _originalContent[f.path] = f.content;
        ctrl.addListener(() => _onContentChanged(f, ctrl));
        return ctrl;
      },
    );
  }

  ScrollController _scroll(OpenFile f) {
    return _scrolls.putIfAbsent(f.path, () => ScrollController());
  }

  bool _isDirty(String path) {
    final ctrl = _ctrls[path];
    if (ctrl == null) return false;
    final original = _originalContent[path] ?? '';
    return ctrl.text != original;
  }

  void _onContentChanged(OpenFile f, TextEditingController ctrl) {
    // Debounce auto-save (2 seconds after typing stops)
    _autoSaveTimers[f.path]?.cancel();
    _autoSaveTimers[f.path] = Timer(const Duration(seconds: 2), () {
      if (mounted && _isDirty(f.path)) {
        _saveFile(f, ctrl);
      }
    });
    widget.onContentChanged?.call(f.path, ctrl.text);
  }

  Future<void> _saveFile(OpenFile f, TextEditingController ctrl) async {
    final content = ctrl.text;
    final success = await NativeFileService.writeFile(f.path, content);
    if (success) {
      _originalContent[f.path] = content;
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Saved'),
            backgroundColor: T.sage,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to save'),
            backgroundColor: T.coral,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
    widget.onSave?.call(f.path, content);
  }

  void _saveCurrentFile() {
    if (widget.files.isEmpty) return;
    final active = widget.files[widget.activeIndex];
    final ctrl = _ctrls[active.path];
    if (ctrl != null) {
      _saveFile(active, ctrl);
    }
  }

  @override
  void didUpdateWidget(EditorView old) {
    super.didUpdateWidget(old);
    // Clean controllers for closed files
    final openPaths = widget.files.map((f) => f.path).toSet();
    _ctrls.keys.toList().forEach((k) {
      if (!openPaths.contains(k)) {
        _autoSaveTimers[k]?.cancel();
        _autoSaveTimers.remove(k);
        _ctrls[k]?.dispose();
        _ctrls.remove(k);
        _scrolls[k]?.dispose();
        _scrolls.remove(k);
        _originalContent.remove(k);
      }
    });

    // Fix memory leak: if a file was reopened with the same path after being
    // closed, refresh controller text with the new content from the OpenFile.
    for (final f in widget.files) {
      final ctrl = _ctrls[f.path];
      if (ctrl != null && _originalContent[f.path] != null) {
        // If the file object's content differs from our original but matches
        // (meaning it was re-opened from disk), refresh.
        if (f.content != _originalContent[f.path] && f.content == ctrl.text) {
          _originalContent[f.path] = f.content;
        }
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final t in _autoSaveTimers.values) {
      t.cancel();
    }
    _autoSaveTimers.clear();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final s in _scrolls.values) {
      s.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkForExternalChanges();
    }
  }

  Future<void> _checkForExternalChanges() async {
    for (final f in widget.files) {
      try {
        final result = await NativeFileService.readFile(f.path);
        if (result['error'] == null) {
          final diskContent = result['content']?.toString() ?? '';
          final ctrl = _ctrls[f.path];
          final original = _originalContent[f.path] ?? '';
          // Only prompt if disk differs from what we last saved (not from live edits)
          if (diskContent != original && mounted) {
            final shouldReload = await showDialog<bool>(
              context: context,
              barrierColor: Colors.black54,
              builder: (_) => AlertDialog(
                backgroundColor: T.s1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(T.r_lg),
                  side: const BorderSide(color: T.border),
                ),
                title: const Text('File changed on disk'),
                content: Text(
                  '${f.name} was modified externally. Reload from disk?',
                  style: T.ui(size: 13, color: T.dim),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('keep mine', style: T.ui(size: 12, color: T.muted)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('reload', style: T.ui(size: 12, color: T.accent, weight: FontWeight.w600)),
                  ),
                ],
              ),
            );
            if (shouldReload == true && ctrl != null) {
              ctrl.text = diskContent;
              _originalContent[f.path] = diskContent;
            }
          }
        }
      } catch (_) {
        // File might not be readable, ignore
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) {
      return const WelcomeView();
    }
    final active = widget.files[widget.activeIndex];
    final dirty = _isDirty(active.path);
    return Column(
      children: [
        _TabStrip(
          files: widget.files,
          active: widget.activeIndex,
          dirtyFiles: widget.files.map((f) => _isDirty(f.path)).toList(),
          onTap: widget.onTabTap,
          onClose: widget.onTabClose,
          onSaveCurrent: _saveCurrentFile,
        ),
        Container(height: 1, color: T.border),
        Expanded(
          child: _CodeCanvas(
            key: ValueKey(active.path),
            ctrl: _ctrl(active),
            scroll: _scroll(active),
            fileName: active.name,
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
  final List<bool> dirtyFiles;
  final Function(int) onTap;
  final Function(int) onClose;
  final VoidCallback onSaveCurrent;

  const _TabStrip({
    required this.files,
    required this.active,
    required this.dirtyFiles,
    required this.onTap,
    required this.onClose,
    required this.onSaveCurrent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      color: T.s1,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: files.length,
              itemBuilder: (_, i) => _Tab(
                file: files[i],
                active: i == active,
                dirty: dirtyFiles.length > i ? dirtyFiles[i] : false,
                onTap: () => onTap(i),
                onClose: () => onClose(i),
              ),
            ),
          ),
          // Save button in tab strip
          if (files.isNotEmpty)
            GestureDetector(
              onTap: onSaveCurrent,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    border: Border(left: BorderSide(color: T.border)),
                  ),
                  child: const Icon(Icons.save_outlined, size: 16, color: T.dim),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Tab extends StatefulWidget {
  final OpenFile file;
  final bool active;
  final bool dirty;
  final VoidCallback onTap;
  final VoidCallback onClose;
  const _Tab({
    required this.file,
    required this.active,
    required this.dirty,
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
              // Dirty indicator dot
              if (widget.dirty)
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(left: 5),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: T.accent,
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
  final String fileName;

  const _CodeCanvas({
    super.key,
    required this.ctrl,
    required this.scroll,
    required this.fileName,
  });

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
          const Positioned.fill(
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
                  const _HintRow(
                    label: 'open a file',
                    hint: 'from the sidebar',
                  ),
                  const _HintRow(
                    label: 'ask the agent',
                    hint: 'panel below',
                  ),
                  const _HintRow(
                    label: 'configure keys',
                    hint: 'settings \u00b7 top right',
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
