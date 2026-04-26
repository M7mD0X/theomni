import 'package:flutter/material.dart';
import '../theme/omni_theme.dart';

class TerminalPanel extends StatefulWidget {
  const TerminalPanel({super.key});

  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  final List<_Line> _lines = [
    _Line('omni-ide · terminal', _Lt.brand),
    _Line('~/omni-ide/projects', _Lt.path),
    _Line('', _Lt.out),
    _Line(
      'preview only — for real execution, ask the agent panel below.',
      _Lt.dim,
    ),
  ];

  void _submit(String cmd) {
    if (cmd.trim().isEmpty) return;
    setState(() {
      _lines.add(_Line('\$ $cmd', _Lt.cmd));
      _lines.add(_Line(
        'use the agent to execute. real shell coming in phase 2.',
        _Lt.dim,
      ));
    });
    _ctrl.clear();
    _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: T.dFast,
          curve: T.eOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: T.bg,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(T.s_4, T.s_3, T.s_4, T.s_3),
              itemCount: _lines.length,
              itemBuilder: (_, i) => _LineView(line: _lines[i]),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              color: T.s1,
              border: Border(top: BorderSide(color: T.border)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: T.s_4, vertical: 8),
            child: Row(
              children: [
                Text('›',
                    style: T.mono(
                        size: 14, weight: FontWeight.w700, color: T.accent)),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    onSubmitted: _submit,
                    style: T.mono(size: 12, color: T.text),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      hintText: 'type a command…',
                      hintStyle: T.mono(size: 12, color: T.muted),
                    ),
                    cursorColor: T.accent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LineView extends StatelessWidget {
  final _Line line;
  const _LineView({required this.line});

  @override
  Widget build(BuildContext context) {
    switch (line.type) {
      case _Lt.brand:
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(line.text,
              style: T.display(
                size: 14,
                color: T.accent,
                style: FontStyle.italic,
                weight: FontWeight.w500,
              )),
        );
      case _Lt.path:
        return Text(line.text, style: T.mono(size: 11, color: T.muted));
      case _Lt.cmd:
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(line.text,
              style: T.mono(size: 12, color: T.text, weight: FontWeight.w500)),
        );
      case _Lt.out:
        return Text(line.text, style: T.mono(size: 12, color: T.text));
      case _Lt.dim:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(line.text, style: T.ui(size: 11, color: T.muted)),
        );
    }
  }
}

enum _Lt { brand, path, cmd, out, dim }

class _Line {
  final String text;
  final _Lt type;
  const _Line(this.text, this.type);
}
