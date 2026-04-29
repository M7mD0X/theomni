import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/agent_service.dart';
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
        return Column(
        children: [
          _StatusStrip(agent: agent, cloud: isCloud),
          Expanded(
            child: (!isCloud && agent.state == AgentState.disconnected)
                ? _DisconnectedView(agent: agent)
                : agent.messages.isEmpty
                    ? _EmptyState(
                        state: agent.state,
                        cloud: isCloud,
                        onSend: (q) {
                          _input.text = q;
                          _send();
                        })
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(
                            T.s_4, T.s_3, T.s_4, T.s_3),
                        itemCount: agent.messages.length +
                            (agent.state == AgentState.thinking ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (agent.state == AgentState.thinking &&
                              i == agent.messages.length) {
                            return const _Thinking();
                          }
                          return _Bubble(msg: agent.messages[i]);
                        },
                      ),
          ),
          _InputBar(
            ctrl: _input,
            onSend: _send,
            enabled: agent.state == AgentState.connected,
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
                  ? [BoxShadow(color: color.withOpacity(0.4), blurRadius: 4)]
                  : null,
            ),
          ),
          const SizedBox(width: T.s_2),
          Text(agent.statusText, style: T.ui(size: 11, color: T.dim)),
          const SizedBox(width: 8),
          // Mode badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: cloud ? T.s2 : T.accentBg,
              borderRadius: BorderRadius.circular(T.r_pill),
              border: Border.all(
                color: cloud ? T.border : T.accent,
                width: 0.8,
              ),
            ),
            child: Text(
              cloud ? 'Cloud Mode' : 'Full Access Agent',
              style: T.ui(
                  size: 9.5,
                  color: cloud ? T.muted : T.accent,
                  weight: FontWeight.w700,
                  letterSpacing: 1),
            ),
          ),
          const Spacer(),
          if (!cloud && agent.state == AgentState.disconnected)
            _MiniBtn(
                label: 'connect',
                onTap: () =>
                    context.read<AgentService>().connect(fromUser: true)),
          if (connected) ...[
            if (!cloud)
              _MiniBtn(
                label: 'sync',
                onTap: () => context.read<AgentService>().reloadConfig(),
              ),
            if (!cloud) const SizedBox(width: 6),
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
            borderRadius: BorderRadius.circular(T.r_pill),
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

// ── Disconnected view (NEW: copy + test + auto-retry) ────────────────────
class _DisconnectedView extends StatefulWidget {
  final AgentService agent;
  const _DisconnectedView({required this.agent});

  @override
  State<_DisconnectedView> createState() => _DisconnectedViewState();
}

class _DisconnectedViewState extends State<_DisconnectedView> {
  String? _testResult;
  bool _testing = false;
  bool _testOk = false;

  Future<void> _copy() async {
    await Clipboard.setData(
        const ClipboardData(text: AgentService.startCommand));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Copied · paste into Termux',
          style: T.ui(size: 12, color: T.text)),
      backgroundColor: T.s2,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _testAgent() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final result = await widget.agent.ping();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = result != null;
      _testResult =
          result != null ? 'reachable · $result' : 'unreachable on :8080';
    });
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(T.s_5, T.s_5, T.s_5, T.s_5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'agent offline',
            style: T.ui(size: 12, color: T.muted, letterSpacing: 2),
          ),
          const SizedBox(height: 6),
          Text(
            'start it in termux',
            style: T.display(
              size: 26,
              weight: FontWeight.w500,
              color: T.text,
              style: FontStyle.italic,
            ),
          ),
          const SizedBox(height: T.s_4),

          // Command box with copy
          _CommandBox(command: AgentService.startCommand, onCopy: _copy),

          const SizedBox(height: T.s_3),

          // Action row
          Row(
            children: [
              _GhostButton(
                icon: Icons.flash_on_rounded,
                label: 'connect now',
                onTap: () => agent.connect(fromUser: true),
              ),
              const SizedBox(width: T.s_2),
              _GhostButton(
                icon: _testing
                    ? Icons.hourglass_empty_rounded
                    : (_testOk
                        ? Icons.check_circle_outline_rounded
                        : Icons.troubleshoot_rounded),
                label: _testing ? 'testing…' : 'test agent',
                onTap: _testing ? null : _testAgent,
                accentColor: _testResult == null
                    ? null
                    : (_testOk ? T.sage : T.coral),
              ),
            ],
          ),

          if (_testResult != null) ...[
            const SizedBox(height: T.s_3),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: T.s_3, vertical: T.s_2),
              decoration: BoxDecoration(
                color: _testOk ? T.s2 : T.coralBg,
                borderRadius: BorderRadius.circular(T.r_md),
                border: Border(
                  left: BorderSide(
                      color: _testOk ? T.sage : T.coral, width: 2),
                ),
              ),
              child: Text(
                _testResult!,
                style: T.mono(
                    size: 11, color: _testOk ? T.dim : T.coral, height: 1.4),
              ),
            ),
          ],

          const SizedBox(height: T.s_5),

          // Auto-retry indicator
          _RetryCard(agent: agent),

          const SizedBox(height: T.s_5),

          // Help section
          Text('first time?',
              style: T.ui(size: 11, color: T.muted, letterSpacing: 1.5)),
          const SizedBox(height: 6),
          _HelpStep(
              n: '1', text: 'install Termux from F-Droid (not Play Store)'),
          _HelpStep(
              n: '2',
              text: 'run setup once:',
              code:
                  'curl -L https://raw.githubusercontent.com/.../setup_termux.sh | bash'),
          _HelpStep(n: '3', text: 'then start the agent (command above)'),
          _HelpStep(
              n: '4',
              text: 'come back here — it will auto-connect within seconds'),
        ],
      ),
    );
  }
}

class _CommandBox extends StatefulWidget {
  final String command;
  final VoidCallback onCopy;
  const _CommandBox({required this.command, required this.onCopy});

  @override
  State<_CommandBox> createState() => _CommandBoxState();
}

class _CommandBoxState extends State<_CommandBox> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onCopy,
        child: AnimatedContainer(
          duration: T.dFast,
          padding:
              const EdgeInsets.symmetric(horizontal: T.s_3, vertical: T.s_3),
          decoration: BoxDecoration(
            color: T.s1,
            borderRadius: BorderRadius.circular(T.r_md),
            border: Border.all(
              color: _hover ? T.accent.withOpacity(0.6) : T.border,
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Text(
                '\$',
                style: T.mono(
                    size: 13, color: T.accent, weight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  widget.command,
                  style: T.mono(size: 13, color: T.text, height: 1.5),
                ),
              ),
              const SizedBox(width: T.s_2),
              AnimatedContainer(
                duration: T.dFast,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _hover ? T.accent : T.s3,
                  borderRadius: BorderRadius.circular(T.r_pill),
                  border: Border.all(
                    color: _hover ? T.accentHi : T.border,
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.content_copy_rounded,
                        size: 11, color: _hover ? T.bg : T.dim),
                    const SizedBox(width: 5),
                    Text('copy',
                        style: T.ui(
                          size: 10,
                          color: _hover ? T.bg : T.dim,
                          weight: FontWeight.w600,
                          letterSpacing: 0.5,
                        )),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GhostButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? accentColor;
  const _GhostButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accentColor,
  });

  @override
  State<_GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<_GhostButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    final color = widget.accentColor ?? T.accent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: disabled
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: T.dFast,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _hover && !disabled
                ? color.withOpacity(0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(T.r_pill),
            border: Border.all(
              color: disabled
                  ? T.border
                  : (_hover ? color : T.borderHi),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon,
                  size: 13, color: disabled ? T.muted : color),
              const SizedBox(width: 6),
              Text(widget.label,
                  style: T.ui(
                    size: 11.5,
                    color: disabled ? T.muted : color,
                    weight: FontWeight.w600,
                    letterSpacing: 0.3,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _RetryCard extends StatelessWidget {
  final AgentService agent;
  const _RetryCard({required this.agent});

  @override
  Widget build(BuildContext context) {
    final countdown = agent.retryCountdown;
    final connecting = agent.state == AgentState.connecting;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s_3, vertical: T.s_2),
      decoration: BoxDecoration(
        color: T.s1,
        borderRadius: BorderRadius.circular(T.r_md),
        border: Border.all(color: T.border, width: 0.8),
      ),
      child: Row(
        children: [
          Icon(
            agent.autoRetry
                ? Icons.autorenew_rounded
                : Icons.pause_circle_outline_rounded,
            size: 13,
            color: agent.autoRetry ? T.accent : T.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              connecting
                  ? 'connecting…'
                  : agent.autoRetry
                      ? (countdown > 0
                          ? 'auto-retry in ${countdown}s'
                          : 'auto-retry on')
                      : 'auto-retry off',
              style: T.ui(size: 11, color: T.dim),
            ),
          ),
          GestureDetector(
            onTap: () => agent.setAutoRetry(!agent.autoRetry),
            child: Container(
              width: 28,
              height: 16,
              padding: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(
                color: agent.autoRetry ? T.accent : T.s3,
                borderRadius: BorderRadius.circular(T.r_pill),
              ),
              child: Align(
                alignment: agent.autoRetry
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    color: T.bg,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HelpStep extends StatelessWidget {
  final String n;
  final String text;
  final String? code;
  const _HelpStep({required this.n, required this.text, this.code});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            alignment: Alignment.centerLeft,
            child: Text(n,
                style: T.display(
                  size: 13,
                  color: T.accent,
                  style: FontStyle.italic,
                )),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text,
                    style: T.ui(size: 12, color: T.dim, height: 1.5)),
                if (code != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(code!,
                        style:
                            T.mono(size: 10.5, color: T.muted, height: 1.4)),
                  ),
              ],
            ),
          ),
        ],
      ),
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
          padding: const EdgeInsets.symmetric(horizontal: T.s_3, vertical: 8),
          decoration: BoxDecoration(
            color: T.slateBg,
            borderRadius: BorderRadius.circular(T.r_md),
            border: Border.all(color: T.slate.withOpacity(0.3)),
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
            borderRadius: BorderRadius.circular(T.r_md),
            border: Border(
                left: BorderSide(color: T.sage.withOpacity(0.6), width: 2)),
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
            borderRadius: BorderRadius.circular(T.r_md),
            border: Border.all(color: T.coral.withOpacity(0.4)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 14, color: T.coral),
              const SizedBox(width: T.s_2),
              Expanded(
                child:
                    Text(msg.text, style: T.ui(size: 12, color: T.coral)),
              ),
            ],
          ),
        );

      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: T.s_3, left: 40),
            padding:
                const EdgeInsets.symmetric(horizontal: T.s_3, vertical: T.s_2),
            decoration: BoxDecoration(
              color: T.s3,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(T.r_lg),
                topRight: Radius.circular(T.r_md),
                bottomLeft: Radius.circular(T.r_lg),
                bottomRight: Radius.circular(T.r_lg),
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
                      color: T.accent.withOpacity(op),
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

// ── Empty state (when connected but no messages yet) ─────────────────────
class _EmptyState extends StatelessWidget {
  final AgentState state;
  final bool cloud;
  final Function(String) onSend;
  const _EmptyState({
    required this.state,
    required this.onSend,
    this.cloud = false,
  });

  static const _cloudPrompts = [
    'explain a python decorator',
    'write a debounce function in javascript',
    'sketch a REST api for a todo app',
    'compare sqlite vs postgres for a mobile app',
  ];
  static const _localPrompts = [
    'write a hello world in python',
    'show me all files in the project',
    'create a simple express api',
    'what is in README.md',
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
              size: 32,
              weight: FontWeight.w500,
              color: T.text,
              style: FontStyle.italic,
            ),
          ),
          const SizedBox(height: T.s_5),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: (cloud ? _cloudPrompts : _localPrompts)
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
          padding: const EdgeInsets.symmetric(horizontal: T.s_3, vertical: 8),
          decoration: BoxDecoration(
            color: _hover ? T.accentBg : T.s2,
            borderRadius: BorderRadius.circular(T.r_pill),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(T.s_3, T.s_2, T.s_3, T.s_3),
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
                borderRadius: BorderRadius.circular(T.r_lg),
                border: Border.all(
                  color: _focused ? T.accent.withOpacity(0.7) : T.border,
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
                      ? 'describe what to build…'
                      : 'start agent in Termux',
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
                borderRadius: BorderRadius.circular(T.r_lg),
                border: Border.all(
                  color: _hasText && widget.enabled ? T.accentHi : T.border,
                  width: 0.8,
                ),
                boxShadow: _hasText && widget.enabled
                    ? [
                        BoxShadow(
                          color: T.accent.withOpacity(0.3),
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
