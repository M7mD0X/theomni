import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/agent_service.dart';
import '../services/agent/agent_interface.dart';
import '../services/agent/agent_bootstrap.dart';
import '../services/app_mode_service.dart';
import '../theme/omni_theme.dart';

class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key});

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late AgentService _agent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _agent = context.read<AgentService>();
      _agent.addListener(_onUpdate);
      _agent.connect();
    });
  }

  void _onUpdate() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: T.dMed,
          curve: T.eOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _agent.removeListener(_onUpdate);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    _agent.sendMessage(t);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AgentService>(
      builder: (_, agent, __) {
        final modeSvc = context.watch<AppModeService>();
        final isCloud = modeSvc.mode == AppMode.cloud;
        final isConnected = agent.state == AgentState.connected ||
            agent.state == AgentState.thinking;

        return Column(
          children: [
            _StatusStrip(agent: agent, cloud: isCloud),
            Expanded(
              child: !isCloud && !isConnected
                  ? _StartScreen(agent: agent)
                  : agent.messages.isEmpty
                      ? _EmptyState(
                          cloud: isCloud,
                          onSend: (q) {
                            _input.text = q;
                            _send();
                          })
                      : _MessageList(
                          agent: agent,
                          scrollController: _scroll,
                        ),
            ),
            _InputBar(
              ctrl: _input,
              onSend: _send,
              enabled: isConnected,
            ),
          ],
        );
      },
    );
  }
}

// ── Status strip ─────────────────────────────────────────────────────────
class _StatusStrip extends StatelessWidget {
  final AgentService agent;
  final bool cloud;
  const _StatusStrip({required this.agent, required this.cloud});

  @override
  Widget build(BuildContext context) {
    final connected = agent.state == AgentState.connected ||
        agent.state == AgentState.thinking;
    final color = connected ? T.sage : T.muted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s_4, vertical: 7),
      decoration: const BoxDecoration(
        color: T.s1,
        border: Border(bottom: BorderSide(color: T.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: connected
                  ? [BoxShadow(color: T.sage40, blurRadius: 4)]
                  : null,
            ),
          ),
          const SizedBox(width: T.s_2),
          Text(agent.statusText, style: T.ui(size: 11, color: T.dim)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: cloud ? T.s2 : T.accentBg,
              borderRadius: BorderRadius.circular(T.radiusPill),
              border: Border.all(
                color: cloud ? T.border : T.accent,
                width: 0.8,
              ),
            ),
            child: Text(
              cloud ? 'Cloud' : 'Local',
              style: T.ui(
                  size: 9.5,
                  color: cloud ? T.muted : T.accent,
                  weight: FontWeight.w700,
                  letterSpacing: 1),
            ),
          ),
          const Spacer(),
          if (agent.state == AgentState.thinking) ...[
            _MiniBtn(
              label: 'stop',
              onTap: () => context.read<AgentService>().cancelRequest(),
            ),
            const SizedBox(width: 6),
          ],
          if (connected) ...[
            _MiniBtn(
              label: 'clear',
              onTap: () => context.read<AgentService>().clearMessages(),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniBtn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _MiniBtn({required this.label, required this.onTap});

  @override
  State<_MiniBtn> createState() => _MiniBtnState();
}

class _MiniBtnState extends State<_MiniBtn> {
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _hover ? T.accentBg : Colors.transparent,
            borderRadius: BorderRadius.circular(T.radiusPill),
            border: Border.all(
              color: _hover ? T.accent : T.border,
              width: 0.8,
            ),
          ),
          child: Text(widget.label,
              style: T.ui(
                size: 10,
                weight: FontWeight.w600,
                color: _hover ? T.accent : T.dim,
                letterSpacing: 0.5,
              )),
        ),
      ),
    );
  }
}

// ── Start screen — simplified single-button design ───────────────────────
class _StartScreen extends StatefulWidget {
  final AgentService agent;
  const _StartScreen({required this.agent});

  @override
  State<_StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<_StartScreen> {
  bool _launching = false;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _launching = true;
      _error = null;
    });

    try {
      final result = await widget.agent.bootstrap.start();

      if (!mounted) return;

      switch (result) {
        case BootstrapResult.ready:
        case BootstrapResult.cloudReady:
          await widget.agent.connect(fromUser: true);
          break;
        case BootstrapResult.failed:
          setState(() {
            _launching = false;
            _error = 'Agent didn\'t respond. Make sure Termux is running and try again.';
          });
          break;
        case BootstrapResult.termuxRequired:
          setState(() {
            _launching = false;
            _error = 'Termux is required for local mode. Install it from F-Droid.';
          });
          break;
        case BootstrapResult.manualRequired:
          // Try to open Termux automatically
          try {
            await context.read<AppModeService>().openTermux();
          } catch (_) {}
          setState(() {
            _launching = false;
            _error = 'Open Termux and run: ~/omni-ide/start_agent.sh';
          });
          break;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _launching = false;
        _error = 'Failed to start: $e';
      });
    }
  }

  void _copyCommand() {
    Clipboard.setData(const ClipboardData(text: AgentService.startCommand));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Copied to clipboard',
          style: T.ui(size: 12, color: T.text)),
      backgroundColor: T.s2,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: T.s_5, vertical: T.s_6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Agent icon
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: T.accentBg,
                border: Border.all(color: T.accent30, width: 1.5),
              ),
              child: const Icon(
                Icons.smart_toy_outlined,
                size: 26,
                color: T.accent,
              ),
            ),
            const SizedBox(height: T.s_4),

            Text(
              'agent offline',
              style: T.ui(size: 12, color: T.muted, letterSpacing: 2),
            ),
            const SizedBox(height: 4),
            Text(
              'start to begin',
              style: T.display(
                size: 22,
                weight: FontWeight.w500,
                color: T.text,
                style: FontStyle.italic,
              ),
            ),
            const SizedBox(height: T.s_5),

            // Primary start button
            SizedBox(
              width: double.infinity,
              child: _PrimaryButton(
                label: _launching ? 'starting...' : 'start agent',
                icon: _launching ? null : Icons.play_arrow_rounded,
                onTap: _launching ? null : _start,
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: T.s_4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(T.s_3),
                decoration: BoxDecoration(
                  color: T.coralBg,
                  borderRadius: BorderRadius.circular(T.radiusMd),
                  border: Border.all(color: T.coral40),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 14, color: T.coral),
                    const SizedBox(width: T.s_2),
                    Expanded(
                      child: Text(
                        _error!,
                        style: T.ui(size: 12, color: T.coral, height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
              // Show copy command option when manual start is needed
              if (_error!.contains('Termux') ||
                  _error!.contains('start_agent')) ...[
                const SizedBox(height: T.s_3),
                GestureDetector(
                  onTap: _copyCommand,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: T.s_3, vertical: T.s_3),
                    decoration: BoxDecoration(
                      color: T.s2,
                      borderRadius: BorderRadius.circular(T.radiusMd),
                      border: Border.all(color: T.border, width: 0.8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.copy_rounded,
                            size: 13, color: T.dim),
                        const SizedBox(width: T.s_2),
                        Expanded(
                          child: Text(
                            '\$ ${AgentService.startCommand}',
                            style: T.mono(size: 11, color: T.dim),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

// ── Primary button ───────────────────────────────────────────────────────
class _PrimaryButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  const _PrimaryButton({
    required this.label,
    this.icon,
    this.onTap,
  });

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: T.dFast,
          padding: const EdgeInsets.symmetric(horizontal: T.s_4, vertical: T.s_3),
          decoration: BoxDecoration(
            color: disabled
                ? T.s3
                : (_hover ? T.accentHi : T.accent),
            borderRadius: BorderRadius.circular(T.radiusMd),
            border: Border.all(
              color: disabled ? T.border : T.accent,
              width: 0.8,
            ),
            boxShadow: !disabled
                ? [BoxShadow(color: T.accent30, blurRadius: 12, offset: const Offset(0, 2))]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon,
                    size: 18,
                    color: disabled ? T.muted : T.bg),
                const SizedBox(width: 8),
              ],
              if (widget.icon == null && disabled)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: T.muted,
                  ),
                ),
              if (widget.icon == null && disabled)
                const SizedBox(width: 8),
              Text(widget.label,
                  style: T.ui(
                    size: 13,
                    color: disabled ? T.muted : T.bg,
                    weight: FontWeight.w600,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Message list ─────────────────────────────────────────────────────────
class _MessageList extends StatelessWidget {
  final AgentService agent;
  final ScrollController scrollController;

  const _MessageList({
    required this.agent,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(T.s_4, T.s_3, T.s_4, T.s_3),
      itemCount: agent.messages.length +
          (agent.state == AgentState.thinking ? 1 : 0),
      itemBuilder: (_, i) {
        if (agent.state == AgentState.thinking &&
            i == agent.messages.length) {
          return const _Thinking();
        }
        return _Bubble(msg: agent.messages[i]);
      },
    );
  }
}

// ── Message bubble ───────────────────────────────────────────────────────
class _Bubble extends StatelessWidget {
  final AgentMessage msg;
  const _Bubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    switch (msg.role) {
      case 'system':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: Text(
              msg.text,
              style: T.ui(size: 10, color: T.muted, letterSpacing: 1),
            ),
          ),
        );

      case 'tool_call':
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding:
              const EdgeInsets.symmetric(horizontal: T.s_3, vertical: 8),
          decoration: BoxDecoration(
            color: T.slateBg,
            borderRadius: BorderRadius.circular(T.radiusMd),
            border: Border.all(color: T.slate30),
          ),
          child: Row(
            children: [
              const Icon(Icons.bolt_rounded, size: 13, color: T.slate),
              const SizedBox(width: 7),
              Text(msg.text,
                  style: T.mono(
                      size: 11, color: T.slate, weight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  msg.meta?['params'] ?? '',
                  style: T.mono(size: 10.5, color: T.dim),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );

      case 'tool_result':
        return Container(
          margin: const EdgeInsets.only(bottom: T.s_3, left: 18),
          padding: const EdgeInsets.all(T.s_3),
          decoration: BoxDecoration(
            color: T.s2,
            borderRadius: BorderRadius.circular(T.radiusMd),
            border:
                Border(left: BorderSide(color: T.sage60, width: 2)),
          ),
          child: Text(
            msg.text,
            style: T.mono(size: 11, color: T.dim, height: 1.55),
          ),
        );

      case 'error':
        return Container(
          margin: const EdgeInsets.only(bottom: T.s_3),
          padding: const EdgeInsets.all(T.s_3),
          decoration: BoxDecoration(
            color: T.coralBg,
            borderRadius: BorderRadius.circular(T.radiusMd),
            border: Border.all(color: T.coral40),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 14, color: T.coral),
              const SizedBox(width: T.s_2),
              Expanded(
                child: Text(msg.text,
                    style: T.ui(size: 12, color: T.coral)),
              ),
            ],
          ),
        );

      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: T.s_3, left: 40),
            padding: const EdgeInsets.symmetric(
                horizontal: T.s_3, vertical: T.s_2),
            decoration: BoxDecoration(
              color: T.s3,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(T.radiusLg),
                topRight: Radius.circular(T.radiusMd),
                bottomLeft: Radius.circular(T.radiusLg),
                bottomRight: Radius.circular(T.radiusLg),
              ),
              border: Border.all(color: T.borderHi, width: 0.8),
            ),
            child: SelectableText(
              msg.text,
              style: T.ui(size: 13, color: T.text, height: 1.5),
            ),
          ),
        );

      default: // agent
        return Container(
          margin: const EdgeInsets.only(bottom: T.s_4),
          padding: const EdgeInsets.fromLTRB(T.s_3, T.s_3, T.s_3, T.s_3),
          decoration: const BoxDecoration(
            color: Colors.transparent,
            border: Border(left: BorderSide(color: T.accent, width: 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('agent',
                  style: T.display(
                    size: 11,
                    color: T.accent,
                    style: FontStyle.italic,
                    weight: FontWeight.w500,
                  )),
              const SizedBox(height: 4),
              SelectableText(
                msg.text,
                style: T.ui(size: 13.5, color: T.text, height: 1.6),
              ),
            ],
          ),
        );
    }
  }
}

// ── Thinking indicator ───────────────────────────────────────────────────
class _Thinking extends StatefulWidget {
  const _Thinking();
  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking>
    with SingleTickerProviderStateMixin {
  late AnimationController c;

  @override
  void initState() {
    super.initState();
    c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: T.s_4),
      padding: const EdgeInsets.fromLTRB(T.s_3, T.s_3, T.s_3, T.s_3),
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: T.accent, width: 2)),
      ),
      child: Row(
        children: [
          Text('thinking',
              style: T.display(
                size: 11,
                color: T.accent,
                style: FontStyle.italic,
              )),
          const SizedBox(width: 8),
          AnimatedBuilder(
            animation: c,
            builder: (_, __) => Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final phase = ((c.value + i * 0.22) % 1.0);
                final op = (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
                    .clamp(0.25, 1.0);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Container(
                    width: 3.5,
                    height: 3.5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: T.accent.withValues(alpha: op),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty state ──────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final bool cloud;
  final Function(String) onSend;
  const _EmptyState({
    required this.onSend,
    this.cloud = false,
  });

  static const _prompts = [
    'explain a python decorator',
    'write a debounce function in JS',
    'sketch a REST API for a todo app',
    'compare SQLite vs PostgreSQL',
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(T.s_5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'what shall we',
            style: T.ui(size: 12, color: T.muted, letterSpacing: 2),
          ),
          const SizedBox(height: 6),
          Text(
            'build today?',
            style: T.display(
              size: 28,
              weight: FontWeight.w500,
              color: T.text,
              style: FontStyle.italic,
            ),
          ),
          const SizedBox(height: T.s_5),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _prompts
                .map((p) => _Suggestion(text: p, onTap: () => onSend(p)))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _Suggestion extends StatefulWidget {
  final String text;
  final VoidCallback onTap;
  const _Suggestion({required this.text, required this.onTap});

  @override
  State<_Suggestion> createState() => _SuggestionState();
}

class _SuggestionState extends State<_Suggestion> {
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
              const EdgeInsets.symmetric(horizontal: T.s_3, vertical: 8),
          decoration: BoxDecoration(
            color: _hover ? T.accentBg : T.s2,
            borderRadius: BorderRadius.circular(T.radiusPill),
            border: Border.all(
              color: _hover ? T.accent : T.border,
              width: 0.8,
            ),
          ),
          child: Text(widget.text,
              style: T.ui(
                size: 12,
                color: _hover ? T.accent : T.dim,
              )),
        ),
      ),
    );
  }
}

// ── Input bar ────────────────────────────────────────────────────────────
class _InputBar extends StatefulWidget {
  final TextEditingController ctrl;
  final VoidCallback onSend;
  final bool enabled;

  const _InputBar({
    required this.ctrl,
    required this.onSend,
    required this.enabled,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  bool _hasText = false;
  bool _focused = false;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.ctrl.addListener(() {
      final has = widget.ctrl.text.isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Container(
      padding:
          EdgeInsets.fromLTRB(T.s_3, T.s_2, T.s_3, T.s_3 + bottomInset),
      decoration: const BoxDecoration(
        color: T.s1,
        border: Border(top: BorderSide(color: T.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: AnimatedContainer(
              duration: T.dFast,
              decoration: BoxDecoration(
                color: T.s3,
                borderRadius: BorderRadius.circular(T.radiusLg),
                border: Border.all(
                  color: _focused ? T.accent30 : T.border,
                  width: 1,
                ),
              ),
              child: TextField(
                controller: widget.ctrl,
                focusNode: _focus,
                enabled: widget.enabled,
                maxLines: 5,
                minLines: 1,
                style: T.ui(size: 13, color: T.text),
                decoration: InputDecoration(
                  hintText: widget.enabled
                      ? 'describe what to build...'
                      : 'start agent first',
                  hintStyle: T.ui(size: 13, color: T.muted),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: T.s_3, vertical: T.s_3),
                ),
                cursorColor: T.accent,
                onSubmitted: (_) => widget.onSend(),
              ),
            ),
          ),
          const SizedBox(width: T.s_2),
          GestureDetector(
            onTap: _hasText && widget.enabled ? widget.onSend : null,
            child: AnimatedContainer(
              duration: T.dFast,
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _hasText && widget.enabled ? T.accent : T.s2,
                borderRadius: BorderRadius.circular(T.radiusLg),
                border: Border.all(
                  color:
                      _hasText && widget.enabled ? T.accentHi : T.border,
                  width: 0.8,
                ),
                boxShadow: _hasText && widget.enabled
                    ? [
                        BoxShadow(
                          color: T.accent30,
                          blurRadius: 12,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 18,
                color: _hasText && widget.enabled ? T.bg : T.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
