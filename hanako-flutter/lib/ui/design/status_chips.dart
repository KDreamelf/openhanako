import 'package:flutter/material.dart';

import 'tokens.dart';

/// 状态点 — 圆形小灯，配合可选的发光效果。
class StatusDot extends StatefulWidget {
  const StatusDot({
    super.key,
    required this.color,
    this.size = 8,
    this.pulse = false,
    this.glow = true,
  });

  final Color color;
  final double size;

  /// 是否做呼吸式脉冲（用于流式/进行中状态）。
  final bool pulse;

  /// 是否发光。
  final bool glow;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    if (widget.pulse) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.pulse && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        final t = widget.pulse ? (0.55 + _ctrl.value * 0.45) : 1.0;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: t),
            shape: BoxShape.circle,
            boxShadow: widget.glow
                ? [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.55 * t),
                      blurRadius: widget.size * 1.2,
                      spreadRadius: 0.5,
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}

/// Pill — 通用药丸标签，可选 icon + label + 状态点。
class HanaPill extends StatelessWidget {
  const HanaPill({
    super.key,
    this.icon,
    required this.label,
    this.color,
    this.dotColor,
    this.dense = false,
    this.onTap,
    this.tooltip,
    this.outlined = true,
  });

  /// 简写：带状态点的小标签。
  factory HanaPill.dot({
    Key? key,
    required String label,
    required Color color,
    bool pulse = false,
    String? tooltip,
    VoidCallback? onTap,
  }) {
    return HanaPill(
      key: key,
      label: label,
      color: color,
      dotColor: color,
      dense: true,
      tooltip: tooltip,
      onTap: onTap,
    );
  }

  final IconData? icon;
  final String label;
  final Color? color;
  final Color? dotColor;
  final bool dense;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final base = color ?? palette.accentEmerald;
    final fg = Color.lerp(palette.textSecondary, base, 0.74)!;
    final bgColor = base.withValues(
      alpha: palette.isDark ? 0.10 : 0.085,
    );
    final borderColor = outlined
        ? base.withValues(alpha: palette.isDark ? 0.28 : 0.34)
        : Colors.transparent;
    final widget = Material(
      color: bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DS.rPill),
        side: outlined ? BorderSide(color: borderColor) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(DS.rPill),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? DS.s8 : DS.s10,
            vertical: dense ? 3 : 5,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dotColor != null) ...[
                StatusDot(color: dotColor!, size: dense ? 5 : 6, pulse: false),
                SizedBox(width: dense ? DS.s4 : DS.s6),
              ] else if (icon != null) ...[
                Icon(icon, size: dense ? 12 : 14, color: fg),
                SizedBox(width: dense ? DS.s4 : DS.s6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: dense ? DS.t11 : DS.t12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (tooltip != null && tooltip!.isNotEmpty) {
      return Tooltip(message: tooltip!, child: widget);
    }
    return widget;
  }
}

/// 横幅 — 用于错误/重试/待授权等水平横幅。
class HanaBanner extends StatelessWidget {
  const HanaBanner({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.color,
    this.leadingLabel,
    this.trailing,
    this.padding = const EdgeInsets.all(DS.s14),
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? color;

  /// 左上角小标签（如 `WAITING FOR YOU`）。
  final String? leadingLabel;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final base = color ?? palette.accentCrimson;
    final fg = Color.lerp(palette.textPrimary, base, 0.32)!;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: base.withValues(alpha: palette.isDark ? 0.10 : 0.085),
        borderRadius: BorderRadius.circular(DS.r10),
        border: Border.all(color: base.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: base.withValues(alpha: palette.isDark ? 0.18 : 0.14),
              borderRadius: BorderRadius.circular(DS.r8),
              border: Border.all(color: base.withValues(alpha: 0.36)),
            ),
            child: Icon(icon, size: 16, color: fg),
          ),
          const SizedBox(width: DS.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leadingLabel != null && leadingLabel!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      leadingLabel!,
                      style: TextStyle(
                        color: base.withValues(alpha: 0.85),
                        fontSize: DS.t10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                Text(
                  title,
                  style: TextStyle(
                    color: fg,
                    fontSize: DS.t14,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: DS.t12,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: DS.s12), trailing!],
        ],
      ),
    );
  }
}

/// 段落标题（小灰大写） — 用于侧栏分组等。
class HanaSectionLabel extends StatelessWidget {
  const HanaSectionLabel(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DS.s4, DS.s8, DS.s4, DS.s6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                color: palette.textTertiary,
                fontSize: DS.t10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 头像方块 — 用于 Agent 标识。
class HanaAvatar extends StatelessWidget {
  const HanaAvatar({
    super.key,
    required this.label,
    this.size = 32,
    this.color,
    this.radius = DS.r8,
  });

  /// 用于显示字符的 label（取第一个字符）。
  final String label;
  final double size;
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = color ?? _colorForLabel(label, palette);
    final ch = label.isEmpty ? '?' : String.fromCharCode(label.runes.first);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: palette.isDark ? 0.18 : 0.18),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: accent.withValues(alpha: 0.42)),
      ),
      alignment: Alignment.center,
      child: Text(
        ch,
        style: TextStyle(
          color: accent,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.42,
        ),
      ),
    );
  }

  static Color _colorForLabel(String label, HanaPalette p) {
    if (label.isEmpty) return p.accentEmerald;
    final code = label.runes.first;
    final palette = [
      p.accentEmerald,
      p.accentCyan,
      p.accentLavender,
      p.accentLilac,
      p.accentAmber,
    ];
    return palette[code % palette.length];
  }
}
