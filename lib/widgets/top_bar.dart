import 'package:flutter/material.dart';
import '../theme/omni_theme.dart';

class TopBar extends StatelessWidget implements PreferredSizeWidget {
  final String? filename;
  final bool guardianRunning;
  final bool sidebarOpen;
  final bool hasDirtyFile;
  final VoidCallback onMenuTap;
  final VoidCallback onSettingsTap;
  final VoidCallback? onSave;

  const TopBar({
    super.key,
    required this.filename,
    required this.guardianRunning,
    required this.sidebarOpen,
    required this.onMenuTap,
    required this.onSettingsTap,
    this.hasDirtyFile = false,
    this.onSave,
  });

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      height: preferredSize.height + top,
      padding: EdgeInsets.only(top: top),
      decoration: const BoxDecoration(
        color: T.s1,
        border: Border(bottom: BorderSide(color: T.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: T.s_2),
          _IconBtn(
            icon:
                sidebarOpen ? Icons.view_sidebar_outlined : Icons.menu_rounded,
            onTap: onMenuTap,
            tip: 'Toggle sidebar',
          ),
          const SizedBox(width: T.s_3),

          // Logo — editorial wordmark
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: 'Omni',
                  style: T.display(
                    size: 18,
                    weight: FontWeight.w600,
                    color: T.text,
                    letterSpacing: -0.3,
                  ),
                ),
                TextSpan(
                  text: '\u00b7ide',
                  style: T.display(
                    size: 18,
                    weight: FontWeight.w400,
                    color: T.accent,
                    style: FontStyle.italic,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: T.s_5),

          // Active filename breadcrumb
          if (filename != null)
            Flexible(
              child: AnimatedSwitcher(
                duration: T.dFast,
                child: Row(
                  key: ValueKey(filename),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(T.fileIcon(filename!),
                        size: 12, color: T.fileColor(filename!)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        filename!,
                        style: T.mono(size: 12, color: T.dim),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Dirty dot in top bar breadcrumb
                    if (hasDirtyFile)
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(left: 5),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: T.accent,
                        ),
                      ),
                  ],
                ),
              ),
            ),

          // Trailing actions — use FittedBox to prevent overflow
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Save button
                if (onSave != null)
                  _IconBtn(
                    icon: hasDirtyFile
                        ? Icons.save_rounded
                        : Icons.save_outlined,
                    onTap: onSave!,
                    tip: 'Save (Ctrl+S)',
                    highlighted: hasDirtyFile,
                  ),
                if (onSave != null) const SizedBox(width: 4),
                _StatusPill(active: guardianRunning),
                const SizedBox(width: T.s_2),
                _IconBtn(
                  icon: Icons.tune_rounded,
                  onTap: onSettingsTap,
                  tip: 'Settings',
                ),
                const SizedBox(width: T.s_2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatefulWidget {
  final bool active;
  const _StatusPill({required this.active});

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (widget.active) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_StatusPill old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.active && old.active) {
      _ctrl.stop();
      _ctrl.reset();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.active ? T.sage : T.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: widget.active ? T.sageBg : T.s2,
        borderRadius: BorderRadius.circular(T.radiusPill),
        border: Border.all(
          color: widget.active ? T.sage40 : T.border,
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Only animate when active — saves ~60 rebuilds/sec when idle
          if (widget.active)
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.3 + 0.5 * _ctrl.value),
                      blurRadius: 4 + 3 * _ctrl.value,
                    ),
                  ],
                ),
              ),
            )
          else
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
              ),
            ),
          const SizedBox(width: 7),
          Text(
            widget.active ? 'Guardian' : 'Idle',
            style: T.ui(size: 10.5, weight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

class _IconBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tip;
  final bool highlighted;
  const _IconBtn({
    required this.icon,
    required this.onTap,
    required this.tip,
    this.highlighted = false,
  });

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) {
            setState(() => _pressed = false);
            widget.onTap();
          },
          child: AnimatedContainer(
            duration: T.dFast,
            curve: T.eOut,
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _pressed
                  ? T.accentBg
                  : (widget.highlighted
                      ? (_hover ? T.accentBg : T.s3)
                      : (_hover ? T.s3 : Colors.transparent)),
              borderRadius: BorderRadius.circular(T.radiusMd),
            ),
            child: Icon(
              widget.icon,
              size: 18,
              color: (widget.highlighted || _hover || _pressed)
                  ? T.accent
                  : T.dim,
            ),
          ),
        ),
      ),
    );
  }
}
