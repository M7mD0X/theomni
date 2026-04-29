import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/agent_service.dart';
import '../services/app_mode_service.dart';
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

  /// Validate API key format before testing.
  String? _validateKey() {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) return 'Enter an API key first';
    if (key.contains(' ')) return 'Key must not contain spaces';

    switch (_provider) {
      case 'openrouter':
        if (!key.startsWith('sk-or-')) {
          return 'OpenRouter keys start with sk-or-';
        }
        if (key.length < 20) return 'Key looks too short';
        return null;
      case 'anthropic':
        if (!key.startsWith('sk-ant-')) {
          return 'Anthropic keys start with sk-ant-';
        }
        if (key.length < 20) return 'Key looks too short';
        return null;
      case 'openai':
        if (!key.startsWith('sk-')) {
          return 'OpenAI keys start with sk-';
        }
        if (key.length < 20) return 'Key looks too short';
        return null;
      case 'custom':
        if (key.length < 8) return 'Key is too short for a custom endpoint';
        return null;
    }
    return null;
  }

  Future<void> _test() async {
    // Format validation first
    final validationError = _validateKey();
    if (validationError != null) {
      setState(() {
        _testMsg = validationError;
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
              'x-api-key': _keyCtrl.text.trim(),
              'anthropic-version': '2023-06-01',
              'content-type': 'application/json',
            }
          : {
              'Authorization': 'Bearer ${_keyCtrl.text.trim()}',
              'Content-Type': 'application/json',
            };

      final body =
          '{"model":"$_model","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}';
      final res = await http
          .post(Uri.parse(url), headers: headers, body: body)
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        setState(() {
          _ok = true;
          _testMsg = 'Connected — $_model is ready to use.';
        });
      } else if (res.statusCode == 401) {
        setState(() {
          _ok = false;
          _testMsg = 'Invalid key — authentication rejected. Double-check your key and try again.';
        });
      } else if (res.statusCode == 403) {
        setState(() {
          _ok = false;
          _testMsg = 'Access denied — your key does not have permission for this model.';
        });
      } else if (res.statusCode == 404 || res.statusCode == 400) {
        setState(() {
          _ok = false;
          _testMsg = 'Model "$_model" not found. Pick a different model from the list.';
        });
      } else if (res.statusCode == 429) {
        setState(() {
          _ok = false;
          _testMsg = 'Rate limited — too many requests. Wait a moment and try again.';
        });
      } else {
        setState(() {
          _ok = false;
          _testMsg = 'Error ${res.statusCode} — check your key and model. Provider may be experiencing issues.';
        });
      }
    } on SocketException {
      setState(() {
        _ok = false;
        _testMsg = 'No internet connection. Check your network and try again.';
      });
    } on TimeoutException {
      setState(() {
        _ok = false;
        _testMsg = 'Connection timed out — the provider is slow or unreachable.';
      });
    } catch (e) {
      setState(() {
        _ok = false;
        _testMsg = 'Unexpected error: ${e.toString().replaceAll('Exception: ', '')}';
      });
    }
    setState(() => _testing = false);
  }

  Future<void> _save() async {
    final validationError = _validateKey();
    if (validationError != null && _keyCtrl.text.trim().isNotEmpty) {
      setState(() {
        _testMsg = validationError;
        _ok = false;
      });
      return;
    }
    await _svc.save(provider: _provider, apiKey: _keyCtrl.text.trim(), model: _model);
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
                    borderRadius: BorderRadius.circular(T.radiusMd),
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

          // ── Mode (Cloud / Local) ────────────────────
          _ModeSection(),
          const SizedBox(height: T.s_4),
          // Help card explaining the difference
          Container(
            padding: const EdgeInsets.all(T.s_3),
            decoration: BoxDecoration(
              color: T.s2,
              borderRadius: BorderRadius.circular(T.radiusMd),
              border: Border.all(color: T.border, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 14, color: T.slate),
                    const SizedBox(width: 8),
                    Text('what is full access?',
                        style: T.ui(size: 12, color: T.text, weight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Cloud mode: Chat with AI directly. Read files on your device, but cannot write or run commands.',
                  style: T.ui(size: 11, color: T.dim, height: 1.5),
                ),
                const SizedBox(height: 6),
                Text(
                  'Full Access mode: Requires Termux installed (from F-Droid). Connects to a local agent that can read, write, and execute shell commands on your device.',
                  style: T.ui(size: 11, color: T.dim, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: T.s_6),

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
                borderRadius: BorderRadius.circular(T.radiusMd),
                border: Border.all(
                  color:
                      _ok ? T.sage40 : T.coral40,
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
            borderRadius: BorderRadius.circular(T.radiusMd),
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
  const _TextBox({
    required this.ctrl,
    required this.hint,
    this.obscure = false,
    this.suffix,
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
        borderRadius: BorderRadius.circular(T.radiusMd),
        border: Border.all(
          color: focused ? T.accent : T.border,
          width: focused ? 1 : 0.8,
        ),
      ),
      child: TextField(
        controller: widget.ctrl,
        focusNode: _f,
        obscureText: widget.obscure,
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
          borderRadius: BorderRadius.circular(T.radiusMd),
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
              borderRadius: BorderRadius.circular(T.radiusMd),
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(T.radiusXl)),
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
                borderRadius: BorderRadius.circular(T.radiusMd),
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
                    borderRadius: BorderRadius.circular(T.radiusMd),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: T.s_3, vertical: T.s_3),
                      decoration: BoxDecoration(
                        color: sel ? T.accentBg : T.s2,
                        borderRadius: BorderRadius.circular(T.radiusMd),
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
            borderRadius: BorderRadius.circular(T.radiusMd),
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
            borderRadius: BorderRadius.circular(T.radiusMd),
            boxShadow: [
              BoxShadow(
                color: widget.active ? T.sage40 : T.accent30,
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

// ─── Mode (Cloud / Local) ──────────────────────────────────────────────
class _ModeSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<AppModeService>(
      builder: (_, mode, __) {
        final isLocal = mode.mode == AppMode.local;
        final termux = mode.termuxInstalled;
        return _Section(
          label: 'mode',
          subtitle: isLocal
              ? 'Full Access — file read/write + shell commands via Termux'
              : 'Cloud Mode — chat with AI, no Termux needed',
          child: Column(
            children: [
              // Cloud tile
              _ModeTile(
                title: 'Cloud',
                desc: 'Chat with AI directly · no setup needed · works offline with cached keys',
                icon: Icons.cloud_outlined,
                selected: !isLocal,
                onTap: () => mode.setLocalEnabled(false),
              ),
              const SizedBox(height: T.s_2),
              // Local tile (gated by Termux presence)
              _ModeTile(
                title: 'Full Access',
                desc: termux
                    ? 'Agent with file read/write + shell commands'
                    : 'Requires Termux installed from F-Droid to enable',
                icon: termux
                    ? Icons.terminal_rounded
                    : Icons.lock_outline_rounded,
                selected: isLocal,
                disabled: !termux,
                onTap: () async {
                  if (!termux) {
                    await mode.refreshTermux();
                    if (!mode.termuxInstalled) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          backgroundColor: T.s2,
                          behavior: SnackBarBehavior.floating,
                          content: Text(
                              'Termux not installed. Install it from F-Droid first.',
                              style: T.ui(size: 12, color: T.text)),
                        ),
                      );
                      return;
                    }
                  }
                  await mode.setLocalEnabled(true);
                },
              ),
              if (!termux) ...[
                const SizedBox(height: T.s_3),
                GestureDetector(
                  onTap: mode.refreshTermux,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: T.s_3, vertical: T.s_2),
                    decoration: BoxDecoration(
                      color: T.s2,
                      borderRadius: BorderRadius.circular(T.radiusMd),
                      border: Border.all(color: T.border, width: 0.8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.refresh_rounded,
                            size: 13, color: T.muted),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'I just installed Termux — re-check',
                            style: T.ui(size: 11, color: T.dim),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (termux && isLocal) ...[
                const SizedBox(height: T.s_3),
                GestureDetector(
                  onTap: mode.openTermux,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: T.s_3, vertical: T.s_2),
                    decoration: BoxDecoration(
                      color: T.accentBg,
                      borderRadius: BorderRadius.circular(T.radiusMd),
                      border: Border.all(color: T.accent, width: 0.8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.open_in_new_rounded,
                            size: 13, color: T.accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'open Termux & run ~/omni-ide/start_agent.sh',
                            style: T.mono(size: 11, color: T.accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ModeTile extends StatefulWidget {
  final String title;
  final String desc;
  final IconData icon;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;
  const _ModeTile({
    required this.title,
    required this.desc,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.disabled = false,
  });

  @override
  State<_ModeTile> createState() => _ModeTileState();
}

class _ModeTileState extends State<_ModeTile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return MouseRegion(
      cursor: widget.disabled
          ? SystemMouseCursors.forbidden
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.disabled ? null : widget.onTap,
        child: AnimatedContainer(
          duration: T.dFast,
          padding: const EdgeInsets.symmetric(
              horizontal: T.s_4, vertical: T.s_3),
          decoration: BoxDecoration(
            color: sel
                ? T.accentBg
                : (_hover && !widget.disabled ? T.s2 : T.s1),
            borderRadius: BorderRadius.circular(T.radiusMd),
            border: Border.all(
              color: sel
                  ? T.accent
                  : (widget.disabled ? T.border : T.borderHi),
              width: sel ? 1 : 0.8,
            ),
          ),
          child: Row(
            children: [
              Icon(widget.icon,
                  size: 17,
                  color: sel
                      ? T.accent
                      : (widget.disabled ? T.muted : T.dim)),
              const SizedBox(width: T.s_3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title,
                        style: T.ui(
                          size: 13,
                          color: widget.disabled ? T.muted : T.text,
                          weight: sel
                              ? FontWeight.w600
                              : FontWeight.w500,
                        )),
                    const SizedBox(height: 2),
                    Text(widget.desc,
                        style:
                            T.ui(size: 11, color: T.muted, height: 1.3)),
                  ],
                ),
              ),
              if (sel)
                const Icon(Icons.check_rounded, size: 16, color: T.accent),
            ],
          ),
        ),
      ),
    );
  }
}

