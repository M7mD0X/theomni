import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/app_mode_service.dart';
import '../services/native_file_service.dart';
import '../theme/omni_theme.dart';

enum SidebarTab { files, search, agent }

class SidebarWidget extends StatefulWidget {
  /// Called with (absolutePath, fileName, content)
  final Function(String absPath, String name, String content) onFileOpen;

  const SidebarWidget({super.key, required this.onFileOpen});

  @override
  State<SidebarWidget> createState() => _SidebarWidgetState();
}

class _SidebarWidgetState extends State<SidebarWidget> {
  SidebarTab _tab = SidebarTab.files;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: T.s1,
        border: Border(right: BorderSide(color: T.border)),
      ),
      child: Row(
        children: [
          _Rail(
            selected: _tab,
            onTap: (t) => setState(() => _tab = t),
          ),
          Container(width: 1, color: T.border),
          SizedBox(
            width: 248,
            child: AnimatedSwitcher(
              duration: T.dMed,
              switchInCurve: T.eOut,
              child: _tab == SidebarTab.files
                  ? FileExplorerTree(
                      key: const ValueKey('files'),
                      onFileOpen: widget.onFileOpen,
                    )
                  : _tab == SidebarTab.search
                      ? SearchPane(
                          key: const ValueKey('search'),
                          onFileOpen: widget.onFileOpen,
                        )
                      : const _ComingSoon(
                          key: ValueKey('agent'),
                          label: 'Agent tasks',
                        ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Activity rail ────────────────────────────────────────────────────────
class _Rail extends StatelessWidget {
  final SidebarTab selected;
  final Function(SidebarTab) onTap;
  const _Rail({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      color: T.s2,
      child: Column(
        children: [
          const SizedBox(height: T.s_3),
          _RailBtn(
            icon: Icons.folder_open_rounded,
            active: selected == SidebarTab.files,
            onTap: () => onTap(SidebarTab.files),
            tip: 'Files',
          ),
          _RailBtn(
            icon: Icons.search_rounded,
            active: selected == SidebarTab.search,
            onTap: () => onTap(SidebarTab.search),
            tip: 'Search',
          ),
          _RailBtn(
            icon: Icons.auto_awesome_outlined,
            active: selected == SidebarTab.agent,
            onTap: () => onTap(SidebarTab.agent),
            tip: 'Agent',
          ),
        ],
      ),
    );
  }
}

class _RailBtn extends StatefulWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final String tip;
  const _RailBtn({
    required this.icon,
    required this.active,
    required this.onTap,
    required this.tip,
  });

  @override
  State<_RailBtn> createState() => _RailBtnState();
}

class _RailBtnState extends State<_RailBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 48,
            height: 44,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: widget.active ? T.accent : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Icon(
              widget.icon,
              size: 19,
              color: widget.active ? T.accent : (_hover ? T.text : T.muted),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Root model ───────────────────────────────────────────────────────────
class _Root {
  final String id;
  final String label;
  final String path;
  const _Root({required this.id, required this.label, required this.path});
}

// ── File explorer ────────────────────────────────────────────────────────
class FileExplorerTree extends StatefulWidget {
  final Function(String absPath, String name, String content) onFileOpen;
  const FileExplorerTree({super.key, required this.onFileOpen});

  @override
  State<FileExplorerTree> createState() => _FileExplorerTreeState();
}

class _FileExplorerTreeState extends State<FileExplorerTree> {
  static const _agent = 'http://localhost:8080';

  List<_Root> _roots = const [];
  _Root? _root;

  /// Stack of breadcrumbs relative to the current root
  final List<String> _crumbs = [];
  List<_FItem> _items = [];
  bool _loading = true;
  String? _error;
  String? _selected;
  bool _agentReachable = false;

  String get _relPath => _crumbs.join('/');
  String get _absDir {
    if (_root == null) return '';
    if (_crumbs.isEmpty) return _root!.path;
    return '${_root!.path}/${_crumbs.join('/')}';
  }

  @override
  void initState() {
    super.initState();
    _loadRoots();
  }

  /// Always-available default roots, even when the agent is offline.
  /// These match the spec exactly:
  ///   • OmniIDE workspace  → /storage/emulated/0/OmniIDE
  ///   • Full Device        → /storage/emulated/0
  ///   • Termux Home        → /data/data/com.termux/files/home
  List<_Root> _defaultRoots() {
    final mode = context.read<AppModeService>();
    final ws = mode.workspacePath;
    final out = <_Root>[
      _Root(id: 'omniide',  label: 'OmniIDE',     path: ws),
      _Root(id: 'sdcard',   label: 'Device',      path: '/storage/emulated/0'),
    ];
    // Only show Termux root if it exists.
    if (Directory('/data/data/com.termux/files/home').existsSync()) {
      out.add(const _Root(
          id: 'termux',
          label: 'Termux Home',
          path: '/data/data/com.termux/files/home'));
    }
    return out;
  }

  Future<void> _loadRoots() async {
    // Try the agent first; if it's not reachable we silently fall back to
    // the native explorer with sane defaults — the UX is the same either way.
    try {
      final res = await http
          .get(Uri.parse('$_agent/roots'))
          .timeout(const Duration(seconds: 2));
      final data = jsonDecode(res.body);
      final roots = (data['roots'] as List)
          .map((r) => _Root(
              id: r['id'] as String,
              label: r['label'] as String,
              path: r['path'] as String))
          .toList();
      setState(() {
        _agentReachable = true;
        _roots = roots;
        _root = roots.isNotEmpty ? roots.first : null;
      });
    } catch (_) {
      final defaults = _defaultRoots();
      setState(() {
        _agentReachable = false;
        _roots = defaults;
        _root = defaults.isNotEmpty ? defaults.first : null;
      });
    }
    if (_root != null) await _load();
  }

  Future<void> _load() async {
    if (_root == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (_agentReachable) {
      await _loadFromAgent();
    } else {
      await _loadFromNative();
    }
  }

  Future<void> _loadFromAgent() async {
    try {
      final uri = Uri.parse('$_agent/files').replace(queryParameters: {
        'root': _root!.id,
        if (_relPath.isNotEmpty) 'path': _relPath,
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      final data = jsonDecode(res.body);
      if (data['error'] != null) {
        setState(() { _error = data['error']; _loading = false; });
        return;
      }
      final items = (data['items'] as List)
          .map((i) => _FItem(
                name: i['name'],
                isDir: i['isDir'],
                relPath:
                    _relPath.isEmpty ? i['name'] : '$_relPath/${i['name']}',
              ))
          .toList()
        ..sort(_sortItems);
      setState(() { _items = items; _loading = false; });
    } catch (_) {
      // Agent died mid-session — flip into native mode and retry.
      setState(() => _agentReachable = false);
      await _loadFromNative();
    }
  }

  Future<void> _loadFromNative() async {
    try {
      final raw = await NativeFileService.listDir(_absDir);
      final items = raw
          .map((m) => _FItem(
                name: m['name'] as String,
                isDir: m['isDir'] as bool,
                relPath: _relPath.isEmpty
                    ? m['name'] as String
                    : '$_relPath/${m['name']}',
              ))
          .toList()
        ..sort(_sortItems);
      setState(() { _items = items; _loading = false; _error = null; });
    } catch (e) {
      setState(() {
        _error = 'Cannot read $_absDir — grant storage permission in Settings';
        _loading = false;
      });
    }
  }

  int _sortItems(_FItem a, _FItem b) {
    if (a.isDir && !b.isDir) return -1;
    if (!a.isDir && b.isDir) return 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  Future<void> _openFile(_FItem item) async {
    if (_root == null) return;
    setState(() => _selected = item.relPath);
    if (_agentReachable) {
      try {
        final uri = Uri.parse('$_agent/file').replace(queryParameters: {
          'root': _root!.id,
          'path': item.relPath,
        });
        final res = await http.get(uri).timeout(const Duration(seconds: 4));
        final data = jsonDecode(res.body);
        if (data['error'] != null) {
          _toast(data['error']);
          return;
        }
        widget.onFileOpen(
            data['absPath'] ?? item.relPath, item.name, data['content']);
        return;
      } catch (_) {
        setState(() => _agentReachable = false);
      }
    }
    // Native fallback
    try {
      final abs = '${_root!.path}/${item.relPath}';
      final result = await NativeFileService.readFile(abs);
      if (result['error'] != null) {
        _toast(result['error'].toString());
        return;
      }
      widget.onFileOpen(
          result['absPath']?.toString() ?? abs,
          item.name,
          result['content']?.toString() ?? '');
    } catch (_) {
      _toast('Failed to open file');
    }
  }

  void _goUp() {
    if (_crumbs.isNotEmpty) {
      setState(() => _crumbs.removeLast());
      _load();
    }
  }

  void _enter(_FItem item) {
    setState(() => _crumbs.add(item.name));
    _load();
  }

  void _switchRoot(_Root r) {
    setState(() {
      _root = r;
      _crumbs.clear();
      _selected = null;
    });
    _load();
  }

  // ── Mutations ──────────────────────────────────────────────────────────
  Future<void> _newItem({required bool isDir}) async {
    final name = await _prompt(
      title: isDir ? 'New folder' : 'New file',
      hint: isDir ? 'folder name' : 'filename.ext',
    );
    if (name == null || name.trim().isEmpty || _root == null) return;
    final clean = name.trim();
    final relPath = _relPath.isEmpty ? clean : '$_relPath/$clean';

    if (_agentReachable) {
      try {
        final body = jsonEncode({'root': _root!.id, 'path': relPath});
        final res = await http
            .post(
              Uri.parse('$_agent/${isDir ? 'mkdir' : 'file'}'),
              headers: const {'Content-Type': 'application/json'},
              body: isDir
                  ? body
                  : jsonEncode(
                      {'root': _root!.id, 'path': relPath, 'content': ''}),
            )
            .timeout(const Duration(seconds: 4));
        final data = jsonDecode(res.body);
        if (data['error'] != null) {
          _toast(data['error']);
        } else {
          await _load();
        }
        return;
      } catch (_) {
        setState(() => _agentReachable = false);
      }
    }
    // Native fallback
    try {
      final abs = '${_root!.path}/$relPath';
      if (isDir) {
        await NativeFileService.mkdir(abs);
      } else {
        await NativeFileService.writeFile(abs, '');
      }
      await _load();
    } catch (_) {
      _toast('Failed to create');
    }
  }

  Future<void> _renameItem(_FItem item) async {
    if (_root == null) return;
    final newName = await _prompt(
      title: 'Rename',
      hint: 'new name',
      initial: item.name,
    );
    if (newName == null || newName.trim().isEmpty || newName == item.name) {
      return;
    }
    final newRel =
        _relPath.isEmpty ? newName.trim() : '$_relPath/${newName.trim()}';

    if (_agentReachable) {
      try {
        final res = await http
            .post(
              Uri.parse('$_agent/rename'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'root': _root!.id,
                'from': item.relPath,
                'to': newRel,
              }),
            )
            .timeout(const Duration(seconds: 4));
        final data = jsonDecode(res.body);
        if (data['error'] != null) {
          _toast(data['error']);
        } else {
          await _load();
        }
        return;
      } catch (_) {
        setState(() => _agentReachable = false);
      }
    }
    try {
      final from = '${_root!.path}/${item.relPath}';
      final to = '${_root!.path}/$newRel';
      await NativeFileService.rename(from, to);
      await _load();
    } catch (_) {
      _toast('Failed to rename');
    }
  }

  Future<void> _deleteItem(_FItem item) async {
    if (_root == null) return;
    final ok = await _confirm(
      title: 'Delete ${item.isDir ? 'folder' : 'file'}',
      body: '${item.name} will be permanently removed.',
    );
    if (ok != true) return;

    if (_agentReachable) {
      try {
        final res = await http
            .post(
              Uri.parse('$_agent/delete'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'root': _root!.id, 'path': item.relPath}),
            )
            .timeout(const Duration(seconds: 4));
        final data = jsonDecode(res.body);
        if (data['error'] != null) {
          _toast(data['error']);
        } else {
          await _load();
        }
        return;
      } catch (_) {
        setState(() => _agentReachable = false);
      }
    }
    try {
      final abs = '${_root!.path}/${item.relPath}';
      await NativeFileService.deletePath(abs);
      await _load();
    } catch (_) {
      _toast('Failed to delete');
    }
  }

  Future<String?> _prompt({
    required String title,
    required String hint,
    String initial = '',
  }) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => AlertDialog(
        backgroundColor: T.s1,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.r_lg),
            side: const BorderSide(color: T.border)),
        title: Text(title, style: T.display(size: 18, color: T.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: T.mono(size: 13, color: T.text),
          cursorColor: T.accent,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: T.mono(size: 13, color: T.muted),
            enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: T.border)),
            focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: T.accent)),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('cancel', style: T.ui(size: 12, color: T.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: Text('ok',
                style: T.ui(size: 12, color: T.accent, weight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm({required String title, required String body}) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => AlertDialog(
        backgroundColor: T.s1,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.r_lg),
            side: const BorderSide(color: T.border)),
        title: Text(title, style: T.display(size: 17, color: T.coral)),
        content: Text(body, style: T.ui(size: 13, color: T.dim)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('cancel', style: T.ui(size: 12, color: T.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('delete',
                style: T.ui(size: 12, color: T.coral, weight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: T.ui(size: 12, color: T.text)),
      backgroundColor: T.s2,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Root picker
        _RootBar(
          roots: _roots,
          selected: _root,
          onChange: _switchRoot,
        ),
        // Header — breadcrumb row + actions
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: T.s_2),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: T.border)),
          ),
          child: Row(
            children: [
              if (_crumbs.isNotEmpty)
                _TinyBtn(icon: Icons.arrow_back_rounded, onTap: _goUp)
              else
                const SizedBox(width: 24),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _crumbs.isEmpty ? '·' : _crumbs.join(' / '),
                  style: T.mono(size: 11, color: T.dim),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _TinyBtn(
                  icon: Icons.note_add_outlined,
                  tip: 'New file',
                  onTap: () => _newItem(isDir: false)),
              _TinyBtn(
                  icon: Icons.create_new_folder_outlined,
                  tip: 'New folder',
                  onTap: () => _newItem(isDir: true)),
              _TinyBtn(icon: Icons.refresh_rounded, onTap: _load),
            ],
          ),
        ),

        // Body
        Expanded(
          child: _loading
              ? const _LoadingDots()
              : _error != null
                  ? _ErrorState(error: _error!, onRetry: _load)
                  : _items.isEmpty
                      ? Center(
                          child: Text(
                            '— empty —',
                            style: T.ui(size: 11, color: T.muted),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: _items.length,
                          itemBuilder: (_, i) {
                            final item = _items[i];
                            final sel = _selected == item.relPath;
                            return _FileRow(
                              item: item,
                              selected: sel,
                              onTap: () => item.isDir
                                  ? _enter(item)
                                  : _openFile(item),
                              onRename: () => _renameItem(item),
                              onDelete: () => _deleteItem(item),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

// ── Root picker bar ─────────────────────────────────────────────────────
class _RootBar extends StatelessWidget {
  final List<_Root> roots;
  final _Root? selected;
  final Function(_Root) onChange;
  const _RootBar({
    required this.roots,
    required this.selected,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    if (roots.isEmpty) {
      return Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: T.s_3),
        alignment: Alignment.centerLeft,
        decoration: const BoxDecoration(
          color: T.s2,
          border: Border(bottom: BorderSide(color: T.border)),
        ),
        child: Text('connecting…',
            style: T.ui(size: 11, color: T.muted, letterSpacing: 1)),
      );
    }
    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: T.s2,
        border: Border(bottom: BorderSide(color: T.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: T.s_2),
          Icon(Icons.tune_rounded, size: 13, color: T.muted),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: roots
                    .map((r) => _RootChip(
                          label: r.label,
                          active: selected?.id == r.id,
                          onTap: () => onChange(r),
                        ))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RootChip extends StatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _RootChip({required this.label, required this.active, required this.onTap});

  @override
  State<_RootChip> createState() => _RootChipState();
}

class _RootChipState extends State<_RootChip> {
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
          margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: widget.active ? T.accentBg : (_hover ? T.s3 : Colors.transparent),
            borderRadius: BorderRadius.circular(T.r_pill),
            border: Border.all(
              color: widget.active ? T.accent : T.border,
              width: 0.8,
            ),
          ),
          child: Text(widget.label,
              style: T.ui(
                  size: 11,
                  color: widget.active ? T.accent : T.dim,
                  weight: FontWeight.w500)),
        ),
      ),
    );
  }
}

class _FileRow extends StatefulWidget {
  final _FItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  const _FileRow({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;

  void _showMenu(Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      color: T.s2,
      position: RelativeRect.fromLTRB(
        position.dx, position.dy, overlay.size.width - position.dx, 0,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.r_md),
        side: const BorderSide(color: T.border),
      ),
      items: [
        PopupMenuItem(
          value: 'rename',
          height: 36,
          child: Row(children: [
            const Icon(Icons.edit_outlined, size: 13, color: T.dim),
            const SizedBox(width: 8),
            Text('rename', style: T.ui(size: 12, color: T.text)),
          ]),
        ),
        PopupMenuItem(
          value: 'delete',
          height: 36,
          child: Row(children: [
            const Icon(Icons.delete_outline_rounded, size: 13, color: T.coral),
            const SizedBox(width: 8),
            Text('delete', style: T.ui(size: 12, color: T.coral)),
          ]),
        ),
      ],
    );
    if (selected == 'rename') widget.onRename();
    if (selected == 'delete') widget.onDelete();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final active = widget.selected || _hover;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPressStart: (d) => _showMenu(d.globalPosition),
        onSecondaryTapDown: (d) => _showMenu(d.globalPosition),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: T.dFast,
          padding: const EdgeInsets.symmetric(horizontal: T.s_3, vertical: 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? T.accentBg
                : (_hover ? T.s2 : Colors.transparent),
            border: Border(
              left: BorderSide(
                color: widget.selected ? T.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                item.isDir ? Icons.folder_rounded : T.fileIcon(item.name),
                size: 14,
                color: item.isDir
                    ? const Color(0xFFD6B374)
                    : T.fileColor(item.name),
              ),
              const SizedBox(width: T.s_2),
              Expanded(
                child: Text(
                  item.name,
                  style: T.mono(
                    size: 12,
                    color: active ? T.text : T.dim,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (item.isDir)
                Icon(Icons.chevron_right_rounded,
                    size: 13, color: active ? T.dim : T.faint),
            ],
          ),
        ),
      ),
    );
  }
}

class _TinyBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tip;
  const _TinyBtn({required this.icon, required this.onTap, this.tip});

  @override
  State<_TinyBtn> createState() => _TinyBtnState();
}

class _TinyBtnState extends State<_TinyBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final core = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: T.dFast,
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: _hover ? T.s3 : Colors.transparent,
            borderRadius: BorderRadius.circular(T.r_sm),
          ),
          child: Icon(widget.icon, size: 13, color: _hover ? T.text : T.muted),
        ),
      ),
    );
    return widget.tip != null ? Tooltip(message: widget.tip!, child: core) : core;
  }
}

class _LoadingDots extends StatefulWidget {
  const _LoadingDots();
  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController c;
  @override
  void initState() {
    super.initState();
    c = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AnimatedBuilder(
        animation: c,
        builder: (_, __) => Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = ((c.value + i * 0.2) % 1.0);
            final op =
                (phase < 0.5 ? phase * 2 : (1 - phase) * 2).clamp(0.3, 1.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.5),
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: T.accent.withOpacity(op),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(T.s_4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 24, color: T.muted),
            const SizedBox(height: T.s_3),
            Text(
              error,
              style: T.ui(size: 11, color: T.dim),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: T.s_2),
            Text(
              'check storage permission or try a different root',
              style: T.ui(size: 10, color: T.muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: T.s_3),
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(color: T.accent),
                  borderRadius: BorderRadius.circular(T.r_pill),
                ),
                child: Text('retry',
                    style: T.ui(
                        size: 11, color: T.accent, weight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Search pane ──────────────────────────────────────────────────────────
class SearchPane extends StatefulWidget {
  final Function(String absPath, String name, String content) onFileOpen;
  const SearchPane({super.key, required this.onFileOpen});

  @override
  State<SearchPane> createState() => _SearchPaneState();
}

class _SearchPaneState extends State<SearchPane> {
  static const _agent = 'http://localhost:8080';
  static const _skipDirs = {
    'node_modules', '.git', '.dart_tool', 'build', '.gradle', '.idea',
    'dist', '.next', 'out',
  };
  static const int _maxFileSize = 512 * 1024; // 512 KB
  static const int _maxResults = 200;

  final _ctrl = TextEditingController();
  List<_Root> _roots = const [];
  _Root? _root;
  List<_Hit> _hits = [];
  bool _searching = false;
  bool _truncated = false;
  String? _error;
  bool _agentReachable = true;

  @override
  void initState() {
    super.initState();
    _loadRoots();
  }

  /// Always-available default roots, even when the agent is offline.
  List<_Root> _defaultRoots() {
    final mode = context.read<AppModeService>();
    final ws = mode.workspacePath;
    final out = <_Root>[
      _Root(id: 'omniide', label: 'OmniIDE', path: ws),
      _Root(id: 'sdcard', label: 'Device', path: '/storage/emulated/0'),
    ];
    if (Directory('/data/data/com.termux/files/home').existsSync()) {
      out.add(const _Root(
          id: 'termux',
          label: 'Termux Home',
          path: '/data/data/com.termux/files/home'));
    }
    return out;
  }

  Future<void> _loadRoots() async {
    try {
      final res = await http.get(Uri.parse('$_agent/roots')).timeout(
            const Duration(seconds: 5),
          );
      final data = jsonDecode(res.body);
      final roots = (data['roots'] as List)
          .map((r) => _Root(id: r['id'], label: r['label'], path: r['path']))
          .toList();
      setState(() {
        _agentReachable = true;
        _roots = roots;
        _root = roots.isNotEmpty ? roots.first : null;
      });
    } catch (_) {
      // Agent unreachable — fall back to native default roots.
      final defaults = _defaultRoots();
      setState(() {
        _agentReachable = false;
        _roots = defaults;
        _root = defaults.isNotEmpty ? defaults.first : null;
      });
    }
  }

  Future<void> _run() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty || _root == null) return;
    setState(() {
      _searching = true;
      _error = null;
      _hits = [];
      _truncated = false;
    });

    if (!_agentReachable) {
      await _nativeSearch(q);
      return;
    }

    try {
      final uri = Uri.parse('$_agent/search').replace(queryParameters: {
        'root': _root!.id,
        'q': q,
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 30));
      final data = jsonDecode(res.body);
      if (data['error'] != null) {
        setState(() {
          _error = data['error'];
          _searching = false;
        });
        return;
      }
      final hits = (data['results'] as List)
          .map((h) => _Hit(
                relPath: h['path'],
                absPath: h['absPath'],
                line: h['line'],
                preview: h['preview'],
              ))
          .toList();
      setState(() {
        _hits = hits;
        _truncated = data['truncated'] == true;
        _searching = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Search failed';
        _searching = false;
      });
    }
  }

  /// Native recursive file search using dart:io Directory listing + grep.
  Future<void> _nativeSearch(String query) async {
    final rootPath = _root!.path;
    final hits = <_Hit>[];
    final queryLower = query.toLowerCase();

    try {
      final dir = Directory(rootPath);
      if (!await dir.exists()) {
        setState(() {
          _error = 'Root path does not exist: $rootPath';
          _searching = false;
        });
        return;
      }

      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (hits.length >= _maxResults) break;

        if (entity is! File) continue;

        // Skip files inside ignored directories.
        final rel = entity.path.startsWith(rootPath)
            ? entity.path.substring(rootPath.length)
            : entity.path;
        final segments = rel.split('/').where((s) => s.isNotEmpty);
        if (segments.any((s) => _skipDirs.contains(s))) continue;

        // Skip files over 512 KB.
        try {
          final stat = await entity.stat();
          if (stat.size > _maxFileSize) continue;
        } catch (_) {
          continue;
        }

        // Attempt to read and grep.
        try {
          final content = await entity.readAsString();
          final lines = const LineSplitter().convert(content);
          for (var i = 0; i < lines.length; i++) {
            if (hits.length >= _maxResults) break;
            if (lines[i].toLowerCase().contains(queryLower)) {
              final lineNum = i + 1;
              final preview = lines[i].trim();
              final relPath = segments.join('/');
              hits.add(_Hit(
                relPath: relPath,
                absPath: entity.path,
                line: lineNum,
                preview: preview.isEmpty ? '(empty line)' : preview,
              ));
            }
          }
        } catch (_) {
          // Binary or unreadable file — skip silently.
        }
      }
    } catch (e) {
      setState(() {
        _error = 'Native search error: $e';
        _searching = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _hits = hits;
      _truncated = hits.length >= _maxResults;
      _searching = false;
    });
  }

  Future<void> _openHit(_Hit h) async {
    if (_root == null) return;
    final name = h.relPath.split('/').last;

    if (_agentReachable) {
      try {
        final uri = Uri.parse('$_agent/file').replace(queryParameters: {
          'root': _root!.id,
          'path': h.relPath,
        });
        final res = await http.get(uri).timeout(const Duration(seconds: 8));
        final data = jsonDecode(res.body);
        if (data['content'] != null) {
          widget.onFileOpen(data['absPath'] ?? h.absPath, name, data['content']);
        }
        return;
      } catch (_) {
        // Agent died mid-session — fall through to native.
        setState(() => _agentReachable = false);
      }
    }

    // Native fallback.
    try {
      final result = await NativeFileService.readFile(h.absPath);
      if (result['error'] != null) return;
      widget.onFileOpen(
          result['absPath']?.toString() ?? h.absPath,
          name,
          result['content']?.toString() ?? '');
    } catch (_) {}
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Offline banner
        if (!_agentReachable)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: T.s_3, vertical: 5),
            decoration: const BoxDecoration(
              color: Color(0x1AFF9800),
              border: Border(
                  bottom: BorderSide(color: Color(0x33FF9800))),
            ),
            child: Row(children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 12, color: Color(0xFFFF9800)),
              const SizedBox(width: 6),
              Text('Agent offline — using native search',
                  style: T.ui(size: 10, color: Color(0xFFFFB74D))),
            ]),
          ),
        Container(
          color: T.s2,
          padding: const EdgeInsets.fromLTRB(T.s_3, T.s_3, T.s_3, T.s_2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.search_rounded, size: 13, color: T.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      style: T.mono(size: 12, color: T.text),
                      cursorColor: T.accent,
                      decoration: InputDecoration(
                        hintText: 'find in files',
                        hintStyle: T.mono(size: 12, color: T.muted),
                        isDense: true,
                        border: InputBorder.none,
                      ),
                      onSubmitted: (_) => _run(),
                    ),
                  ),
                  GestureDetector(
                    onTap: _run,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: T.accentBg,
                        borderRadius: BorderRadius.circular(T.r_pill),
                        border: Border.all(color: T.accent, width: 0.8),
                      ),
                      child: Text('search',
                          style: T.ui(
                              size: 10,
                              color: T.accent,
                              weight: FontWeight.w600,
                              letterSpacing: 0.5)),
                    ),
                  ),
                ],
              ),
              if (_roots.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _roots
                          .map((r) => _RootChip(
                                label: r.label,
                                active: _root?.id == r.id,
                                onTap: () => setState(() => _root = r),
                              ))
                          .toList(),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Container(height: 1, color: T.border),
        Expanded(
          child: _searching
              ? const _LoadingDots()
              : _error != null
                  ? _ErrorState(error: _error!, onRetry: _run)
                  : _hits.isEmpty
                      ? Center(
                          child: Text(
                            _ctrl.text.isEmpty
                                ? '— search in current root —'
                                : 'no matches',
                            style: T.ui(size: 11, color: T.muted),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _hits.length + (_truncated ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i >= _hits.length) {
                              return Padding(
                                padding: const EdgeInsets.all(T.s_3),
                                child: Text(
                                  '· truncated at 200 hits ·',
                                  textAlign: TextAlign.center,
                                  style: T.ui(size: 10, color: T.muted),
                                ),
                              );
                            }
                            return _HitRow(
                              hit: _hits[i],
                              onTap: () => _openHit(_hits[i]),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

class _Hit {
  final String relPath;
  final String absPath;
  final int line;
  final String preview;
  const _Hit({
    required this.relPath,
    required this.absPath,
    required this.line,
    required this.preview,
  });
}

class _HitRow extends StatefulWidget {
  final _Hit hit;
  final VoidCallback onTap;
  const _HitRow({required this.hit, required this.onTap});

  @override
  State<_HitRow> createState() => _HitRowState();
}

class _HitRowState extends State<_HitRow> {
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
          padding:
              const EdgeInsets.symmetric(horizontal: T.s_3, vertical: 7),
          color: _hover ? T.s2 : Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.hit.relPath,
                      style: T.mono(
                          size: 11,
                          color: _hover ? T.text : T.dim,
                          weight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text('${widget.hit.line}',
                      style: T.mono(size: 10, color: T.muted)),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                widget.hit.preview,
                style: T.mono(size: 10.5, color: T.muted, height: 1.3),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComingSoon extends StatelessWidget {
  final String label;
  const _ComingSoon({super.key, required this.label});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hourglass_empty_rounded, size: 20, color: T.muted),
          const SizedBox(height: T.s_2),
          Text(label, style: T.ui(size: 11, color: T.dim)),
          Text('soon',
              style: T.display(
                  size: 13, color: T.accent, style: FontStyle.italic)),
        ],
      ),
    );
  }
}

class _FItem {
  final String name;
  final bool isDir;
  final String relPath;
  const _FItem({required this.name, required this.isDir, required this.relPath});
}
