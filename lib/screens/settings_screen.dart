import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/agent_service.dart';
import '../theme/omni_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _svc = SettingsService();
  final _keyCtrl = TextEditingController();

  String _provider = 'openrouter';
  String _model = 'anthropic/claude-3.5-sonnet';
  bool _obscure = true;
  bool _testing = false;
  String _testMsg = '';
  bool _ok = false;
  bool _saved = false;

  List<String> _models = [];
  bool _loadingModels = false;
  String _modelFilter = '';

  @override
  void initState() {
    super.initState();
    _load();
    _fetchModels();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final d = await _svc.load();
    setState(() {
      _provider = d['provider']!;
      _keyCtrl.text = d['apiKey']!;
      _model = d['model']!;
    });
  }

  Future<void> _fetchModels() async {
    setState(() => _loadingModels = true);
    try {
      final res = await http
          .get(Uri.parse('https://openrouter.ai/api/v1/models'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final list = (data['data'] as List)
            .map((m) => m['id'] as String)
            .toList()
          ..sort();
        setState(() => _models = list);
      }
    } catch (_) {}
    setState(() => _loadingModels = false);
  }

  Future<void> _test() async {
    if (_keyCtrl.text.isEmpty) {
      setState(() {
        _testMsg = 'Enter an API key first';
        _ok = false;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testMsg = '';
    });
    try {
      final isAnthropic = _provider == 'anthropic';
      final url = isAnthropic
          ? 'https://api.anthropic.com/v1/messages'
          : _provider == 'openai'
              ? 'https://api.openai.com/v1/chat/completions'
              : 'https://openrouter.ai/api/v1/chat/completions';

      final headers = isAnthropic
          ? {
              'x-api-key': _keyCtrl.text,
              'anthropic-version': '2023-06-01',
              'content-type': 'application/json',
            }
          : {
              'Authorization': 'Bearer ${_keyCtrl.text}',
              'Content-Type': 'application/json',
            };

      final body =
          '{"model":"$_model","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}';
      final res = await http
          .post(Uri.parse(url), headers: headers, body: body)
          .timeout(const Duration(seconds: 12));

      setState(() {
        _ok = res.statusCode == 200;
        _testMsg = _ok
            ? 'Connected — ready.'
            : 'Status ${res.statusCode}. Check key and model.';
      });
    } catch (e) {
      setState(() {
        _ok = false;
        _testMsg = 'Network error: $e';
      });
    }
    setState(() => _testing = false);
  }

  Future<void> _save() async {
    await _svc.save(provider: _provider, apiKey: _keyCtrl.text, model: _model);
    if (!mounted) return;
    context.read<AgentService>().reloadConfig();
    setState(() => _saved = true);
    await Future.delayed(const Duration(milliseconds: 1600));
    if (mounted) setState(() => _saved = false);
  }

  List<String> _availableModels() {
    if (_provider == 'openrouter' && _models.isNotEmpty) return _models;
    return _fallbackModels(_provider);
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: T.bg,
      body: ListView(
        padding: EdgeInsets.fromLTRB(T.s_5, top + T.s_4, T.s_5, T.s_7),
        children: [
          // Header
          Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: T.s2,
                    borderRadius: BorderRadius.circular(T.r_md),
                    border: Border.all(color: T.border),
                  ),
                  child: const Icon(Icons.arrow_back_rounded,
                      size: 16, color: T.dim),
                ),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: T.s_5),
          Text('settings',
              style: T.ui(size: 12, color: T.muted, letterSpacing: 2)),
          const SizedBox(height: 6),
          RichText(
            text: TextSpan(children: [
              TextSpan(
                  text: 'the ',
                  style: T.display(
                      size: 34, color: T.text, weight: FontWeight.w500)),
              TextSpan(
                  text: 'brain.',
                  style: T.display(
                      size: 34,
                      color: T.accent,
                      style: FontStyle.italic,
                      weight: FontWeight.w400)),
            ]),
          ),
          const SizedBox(height: T.s_7),

          // ── Provider ────────────────────────────────
          _Section(
            label: 'provider',
            subtitle: 'where the agent\'s intelligence comes from',
            child: Column(
              children: SettingsService.providers.entries
                  .map((e) => _ProviderTile(
                        id: e.key,
                        name: e.value,
                        selected: _provider == e.key,
                        onTap: () => setState(() => _provider = e.key),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: T.s_6),

          // ── API key ────────────────────────────────
          _Section(
            label: 'api key',
            subtitle: _provider == 'openrouter'
                ? 'free keys at openrouter.ai'
                : 'kept locally on device',
            child: _TextBox(
              ctrl: _keyCtrl,
              hint: _provider == 'anthropic'
                  ? 'sk-ant-...'
                  : _provider == 'openai'
                      ? 'sk-...'
                      : 'sk-or-v1-...',
              obscure: _obscure,
              suffix: IconButton(
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 17,
                  color: T.dim,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: T.s_6),

          // ── Model ──────────────────────────────────
          _Section(
            label: 'model',
            subtitle: _provider == 'openrouter'
                ? '${_models.length} models live from openrouter'
                : 'choose an available model',
            child: _ModelPicker(
              models: _availableModels(),
              value: _model,
              filter: _modelFilter,
              onFilter: (s) => setState(() => _modelFilter = s),
              onPick: (m) => setState(() => _model = m),
              loading: _loadingModels && _provider == 'openrouter',
            ),
          ),

          if (_testMsg.isNotEmpty) ...[
            const SizedBox(height: T.s_5),
            Container(
              padding: const EdgeInsets.all(T.s_3),
              decoration: BoxDecoration(
                color: _ok ? T.sageBg : T.coralBg,
                borderRadius: BorderRadius.circular(T.r_md),
                border: Border.all(
                  color:
                      _ok ? T.sage.withOpacity(0.4) : T.coral.withOpacity(0.4),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _ok ? Icons.check_circle_outline : Icons.error_outline,
                    size: 16,
                    color: _ok ? T.sage : T.coral,
                  ),
                  const SizedBox(width: T.s_2),
                  Expanded(
                    child: Text(
                      _testMsg,
                      style: T.ui(
                        size: 12,
                        color: _ok ? T.sage : T.coral,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: T.s_5),
          Row(
            children: [
              Expanded(
                child: _GhostBtn(
                  label: _testing ? 'testing…' : 'test connection',
                  onTap: _testing ? null : _test,
                ),
              ),
              const SizedBox(width: T.s_3),
              Expanded(
                flex: 2,
                child: _SolidBtn(
                  label: _saved ? 'saved ✓' : 'save',
                  onTap: _save,
                  active: _saved,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<String> _fallbackModels(String p) {
    switch (p) {
      case 'anthropic':
        return [
          'claude-opus-4-5',
          'claude-sonnet-4-5',
          'claude-haiku-4-5',
          'claude-3-5-sonnet-20241022',
        ];
      case 'openai':
        return ['gpt-4o', 'gpt-4o-mini', 'gpt-5.2'];
      default:
        return ['anthropic/claude-3.5-sonnet'];
    }
  }
}

// ── Reusable pieces ──────────────────────────────────────────────────────
class _Section extends StatelessWidget {
  final String label;
  final String subtitle;
  final Widget child;
  const _Section(
      {required this.label, required this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(label.toUpperCase(), style: T.label()),
            const SizedBox(width: T.s_3),
            Expanded(child: Container(height: 1, color: T.border)),
          ],
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: T.ui(size: 11, color: T.muted, height: 1.4)),
        const SizedBox(height: T.s_3),
        child,
      ],
    );
  }
}

class _ProviderTile extends StatefulWidget {
  final String id;
  final String name;
  final bool selected;
  final VoidCallback onTap;
  const _ProviderTile({
    required this.id,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  static const _icons = {
    'openrouter': Icons.hub_rounded,
    'anthropic': Icons.psychology_alt_rounded,
    'openai': Icons.bolt_rounded,
    'custom': Icons.settings_rounded,
  };

  @override
  State<_ProviderTile> createState() => _ProviderTileState();
}

class _ProviderTileState extends State<_ProviderTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: T.dFast,
          margin: const EdgeInsets.only(bottom: T.s_2),
          padding:
              const EdgeInsets.symmetric(horizontal: T.s_4, vertical: T.s_3),
          decoration: BoxDecoration(
            color: sel ? T.accentBg : (_hover ? T.s2 : T.s1),
            borderRadius: BorderRadius.circular(T.r_md),
            border: Border.all(
              color: sel ? T.accent : (_hover ? T.borderHi : T.border),
              width: sel ? 1 : 0.8,
            ),
          ),
          child: Row(
            children: [
              Icon(
                _ProviderTile._icons[widget.id] ?? Icons.settings,
                size: 17,
                color: sel ? T.accent : T.dim,
              ),
              const SizedBox(width: T.s_3),
              Text(widget.name,
                  style: T.ui(
                    size: 13,
                    color: sel ? T.text : T.dim,
                    weight: sel ? FontWeight.w600 : FontWeight.w400,
                  )),
              const Spacer(),
              if (sel)
                const Icon(Icons.check_rounded, size: 16, color: T.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextBox extends StatefulWidget {
  final TextEditingController ctrl;
  final String hint;
  final bool obscure;
  final Widget? suffix;
  final Function(String)? onChanged;

  const _TextBox({
    required this.ctrl,
    required this.hint,
    this.obscure = false,
    this.suffix,
    this.onChanged,
  });

  @override
  State<_TextBox> createState() => _TextBoxState();
}

class _TextBoxState extends State<_TextBox> {
  final FocusNode _f = FocusNode();
  @override
  void initState() {
    super.initState();
    _f.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _f.hasFocus;
    return AnimatedContainer(
      duration: T.dFast,
      decoration: BoxDecoration(
        color: T.s2,
        borderRadius: BorderRadius.circular(T.r_md),
        border: Border.all(
          color: focused ? T.accent : T.border,
          width: focused ? 1 : 0.8,
        ),
      ),
      child: TextField(
        controller: widget.ctrl,
        focusNode: _f,
        obscureText: widget.obscure,
        onChanged: widget.onChanged,
        style: T.mono(size: 13, color: T.text),
        cursorColor: T.accent,
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: T.mono(size: 12.5, color: T.muted),
          border: InputBorder.none,
          suffixIcon: widget.suffix,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: T.s_3, vertical: T.s_3),
        ),
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  final List<String> models;
  final String value;
  final String filter;
  final Function(String) onFilter;
  final Function(String) onPick;
  final bool loading;
  const _ModelPicker({
    required this.models,
    required this.value,
    required this.filter,
    required this.onFilter,
    required this.onPick,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Container(
        height: 60,
        decoration: BoxDecoration(
          color: T.s2,
          borderRadius: BorderRadius.circular(T.r_md),
          border: Border.all(color: T.border, width: 0.8),
        ),
        child: Center(
          child: Text('loading models…', style: T.ui(size: 11, color: T.muted)),
        ),
      );
    }

    final filtered = filter.isEmpty
        ? models
        : models
            .where((m) => m.toLowerCase().contains(filter.toLowerCase()))
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Current selection as a chip
        GestureDetector(
          onTap: () => _showPicker(context, filtered),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: T.s_3, vertical: T.s_3),
            decoration: BoxDecoration(
              color: T.s2,
              borderRadius: BorderRadius.circular(T.r_md),
              border: Border.all(color: T.border, width: 0.8),
            ),
            child: Row(
              children: [
                const Icon(Icons.memory_rounded, size: 15, color: T.accent),
                const SizedBox(width: T.s_2),
                Expanded(
                  child: Text(
                    value,
                    style: T.mono(size: 12.5, color: T.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.unfold_more_rounded, size: 16, color: T.dim),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showPicker(BuildContext context, List<String> list) {
    showModalBottomSheet(
      context: context,
      backgroundColor: T.s1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(T.r_xl)),
      ),
      builder: (_) => _ModelSheet(
        models: models,
        value: value,
        onPick: (m) {
          onPick(m);
          Navigator.pop(context);
        },
      ),
    );
  }
}

class _ModelSheet extends StatefulWidget {
  final List<String> models;
  final String value;
  final Function(String) onPick;
  const _ModelSheet({
    required this.models,
    required this.value,
    required this.onPick,
  });

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final filtered = _q.isEmpty
        ? widget.models
        : widget.models
            .where((m) => m.toLowerCase().contains(_q.toLowerCase()))
            .toList();
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => Padding(
        padding: const EdgeInsets.fromLTRB(T.s_4, T.s_3, T.s_4, T.s_4),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 3,
              decoration: BoxDecoration(
                color: T.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: T.s_4),
            Row(
              children: [
                Text('choose model',
                    style: T.display(
                        size: 20, color: T.text, weight: FontWeight.w500)),
                const Spacer(),
                Text('${filtered.length}',
                    style: T.mono(size: 12, color: T.accent)),
              ],
            ),
            const SizedBox(height: T.s_3),
            Container(
              decoration: BoxDecoration(
                color: T.s2,
                borderRadius: BorderRadius.circular(T.r_md),
                border: Border.all(color: T.border, width: 0.8),
              ),
              child: TextField(
                autofocus: false,
                style: T.ui(size: 13, color: T.text),
                cursorColor: T.accent,
                decoration: InputDecoration(
                  hintText: 'filter…',
                  hintStyle: T.ui(size: 13, color: T.muted),
                  prefixIcon:
                      const Icon(Icons.search_rounded, size: 17, color: T.dim),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: T.s_3),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            const SizedBox(height: T.s_3),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final m = filtered[i];
                  final sel = m == widget.value;
                  return InkWell(
                    onTap: () => widget.onPick(m),
                    borderRadius: BorderRadius.circular(T.r_md),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: T.s_3, vertical: T.s_3),
                      decoration: BoxDecoration(
                        color: sel ? T.accentBg : T.s2,
                        borderRadius: BorderRadius.circular(T.r_md),
                        border: Border.all(
                          color: sel ? T.accent : T.border,
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(m,
                                style: T.mono(
                                  size: 12.5,
                                  color: sel ? T.text : T.dim,
                                  weight:
                                      sel ? FontWeight.w600 : FontWeight.w400,
                                )),
                          ),
                          if (sel)
                            const Icon(Icons.check_rounded,
                                size: 16, color: T.accent),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GhostBtn extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  const _GhostBtn({required this.label, this.onTap});
  @override
  State<_GhostBtn> createState() => _GhostBtnState();
}

class _GhostBtnState extends State<_GhostBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final en = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: T.dFast,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: _hover && en ? T.s2 : Colors.transparent,
            borderRadius: BorderRadius.circular(T.r_md),
            border: Border.all(
              color: en ? T.accent : T.border,
              width: 0.8,
            ),
          ),
          child: Center(
            child: Text(widget.label,
                style: T.ui(
                  size: 13,
                  color: en ? T.accent : T.muted,
                  weight: FontWeight.w600,
                )),
          ),
        ),
      ),
    );
  }
}

class _SolidBtn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool active;
  const _SolidBtn(
      {required this.label, required this.onTap, this.active = false});
  @override
  State<_SolidBtn> createState() => _SolidBtnState();
}

class _SolidBtnState extends State<_SolidBtn> {
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
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: widget.active ? T.sage : (_hover ? T.accentHi : T.accent),
            borderRadius: BorderRadius.circular(T.r_md),
            boxShadow: [
              BoxShadow(
                color: (widget.active ? T.sage : T.accent).withOpacity(0.25),
                blurRadius: 14,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(
            child: Text(widget.label,
                style: T.ui(size: 13, color: T.bg, weight: FontWeight.w700)),
          ),
        ),
      ),
    );
  }
}
