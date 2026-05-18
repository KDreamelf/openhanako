import 'dart:ui';

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 玻璃材质 — 整个 PH01 视觉的核心原语。
///
/// 使用：
/// ```dart
/// GlassSurface(
///   padding: const EdgeInsets.all(DS.s16),
///   child: Text('hi'),
/// )
/// ```
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.constraints,
    this.accent,
    this.radius = DS.r10,
    this.intensity = GlassIntensity.regular,
    this.elevated = true,
    this.borderless = false,
    this.blur = 20.0,
    this.onTap,
    this.tooltip,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BoxConstraints? constraints;
  final Color? accent;
  final double radius;
  final GlassIntensity intensity;
  final bool elevated;
  final bool borderless;
  final double blur;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final fill = switch (intensity) {
      GlassIntensity.subtle => palette.glassFill.withValues(
        alpha: palette.glassFill.a * 0.6,
      ),
      GlassIntensity.regular => palette.glassFill,
      GlassIntensity.strong => palette.glassFillStrong,
      GlassIntensity.solid => palette.bgRaised,
    };
    final border = borderless
        ? Colors.transparent
        : (accent?.withValues(alpha: palette.isDark ? 0.28 : 0.36) ??
              palette.glassBorder);
    final highlight = palette.isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.white.withValues(alpha: 0.36);

    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      boxShadow: elevated
          ? [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: palette.isDark ? 0.32 : 0.06,
                ),
                blurRadius: palette.isDark ? 28 : 22,
                offset: const Offset(0, 12),
                spreadRadius: -8,
              ),
            ]
          : null,
    );

    Widget content = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: border, width: DS.hairline),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [highlight, fill],
            ),
          ),
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),
      ),
    );

    if (onTap != null) {
      content = Stack(
        children: [
          content,
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(radius),
              child: InkWell(
                borderRadius: BorderRadius.circular(radius),
                onTap: onTap,
                splashColor: (accent ?? palette.accentEmerald).withValues(
                  alpha: 0.12,
                ),
                hoverColor: (accent ?? palette.accentEmerald).withValues(
                  alpha: 0.06,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
      );
    }

    Widget result = Container(
      margin: margin,
      constraints: constraints,
      decoration: decoration,
      child: content,
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      result = Tooltip(message: tooltip!, child: result);
    }
    return result;
  }
}

enum GlassIntensity { subtle, regular, strong, solid }

/// 玻璃按钮 — 配合状态色，支持 icon + label。
class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    required this.onPressed,
    this.child,
    this.icon,
    this.label,
    this.tooltip,
    this.accent,
    this.padding = const EdgeInsets.symmetric(
      horizontal: DS.s12,
      vertical: DS.s8,
    ),
    this.height = 36,
    this.dense = false,
    this.filled = false,
  });

  final VoidCallback? onPressed;
  final Widget? child;
  final IconData? icon;
  final String? label;
  final String? tooltip;
  final Color? accent;
  final EdgeInsetsGeometry padding;
  final double height;
  final bool dense;

  /// 实心强调色（用于主行动按钮）。
  final bool filled;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final enabled = widget.onPressed != null;
    final accent = widget.accent ?? palette.accentEmerald;
    final fg = !enabled
        ? palette.textDisabled
        : widget.filled
        ? (palette.isDark ? const Color(0xFF06120A) : Colors.white)
        : (_hover ? accent : palette.textPrimary);
    final bg = !enabled
        ? palette.glassFill.withValues(alpha: palette.glassFill.a * 0.5)
        : widget.filled
        ? (_pressed
              ? Color.lerp(
                  accent,
                  palette.isDark ? Colors.white : Colors.black,
                  0.18,
                )!
              : (_hover ? Color.lerp(accent, Colors.white, 0.12)! : accent))
        : (_pressed
              ? accent.withValues(alpha: palette.isDark ? 0.20 : 0.18)
              : (_hover
                    ? accent.withValues(alpha: palette.isDark ? 0.12 : 0.10)
                    : palette.glassFill));
    final borderColor = widget.filled
        ? Colors.transparent
        : !enabled
        ? palette.glassBorder.withValues(alpha: palette.glassBorder.a * 0.5)
        : (_hover ? accent.withValues(alpha: 0.42) : palette.glassBorder);

    final radius = widget.dense ? DS.r6 : DS.r8;
    final Widget content;
    if (widget.child != null) {
      content = widget.child!;
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: widget.dense ? 14 : 16),
            if (widget.label != null)
              SizedBox(width: widget.dense ? DS.s4 : DS.s6),
          ],
          if (widget.label != null)
            Text(
              widget.label!,
              style: TextStyle(
                fontSize: widget.dense ? DS.t12 : DS.t13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
        ],
      );
    }

    final button = AnimatedContainer(
      duration: DS.dFast,
      curve: DS.cStandard,
      height: widget.height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor, width: DS.hairline),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: widget.onPressed,
          onHighlightChanged: (v) {
            if (mounted) setState(() => _pressed = v);
          },
          onHover: (v) {
            if (mounted) setState(() => _hover = v);
          },
          splashColor: accent.withValues(alpha: 0.10),
          hoverColor: Colors.transparent,
          child: IconTheme(
            data: IconThemeData(color: fg),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: fg),
              child: Padding(
                padding: widget.padding,
                child: Center(widthFactor: 1, heightFactor: 1, child: content),
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      return Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}

/// 圆形 icon 按钮（小尺寸）— 用于 header 操作。
class GlassIconButton extends StatefulWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 32,
    this.iconSize = 16,
    this.accent,
    this.badgeColor,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double iconSize;
  final Color? accent;
  final Color? badgeColor;

  @override
  State<GlassIconButton> createState() => _GlassIconButtonState();
}

class _GlassIconButtonState extends State<GlassIconButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final enabled = widget.onPressed != null;
    final accent = widget.accent ?? palette.accentEmerald;
    final fg = !enabled
        ? palette.textDisabled
        : (_hover ? accent : palette.textPrimary);
    final bg = !enabled
        ? palette.glassFill.withValues(alpha: palette.glassFill.a * 0.4)
        : _pressed
        ? accent.withValues(alpha: 0.20)
        : (_hover ? accent.withValues(alpha: 0.10) : palette.glassFill);
    final borderColor = !enabled
        ? palette.glassBorder.withValues(alpha: palette.glassBorder.a * 0.5)
        : (_hover ? accent.withValues(alpha: 0.36) : palette.glassBorder);

    final core = AnimatedContainer(
      duration: DS.dFast,
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(DS.r8),
        border: Border.all(color: borderColor, width: DS.hairline),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(DS.r8),
        child: InkWell(
          borderRadius: BorderRadius.circular(DS.r8),
          onTap: widget.onPressed,
          onHighlightChanged: (v) {
            if (mounted) setState(() => _pressed = v);
          },
          onHover: (v) {
            if (mounted) setState(() => _hover = v);
          },
          splashColor: accent.withValues(alpha: 0.10),
          hoverColor: Colors.transparent,
          child: Center(
            child: Icon(widget.icon, size: widget.iconSize, color: fg),
          ),
        ),
      ),
    );

    Widget result = core;
    if (widget.badgeColor != null) {
      result = Stack(
        clipBehavior: Clip.none,
        children: [
          core,
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: widget.badgeColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: widget.badgeColor!.withValues(alpha: 0.6),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      result = Tooltip(message: widget.tooltip!, child: result);
    }
    return result;
  }
}

/// 装饰性环境光晕 — 在主背景顶层覆一层渐变。
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, this.child, this.intensity = 1.0});
  final Widget? child;
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(decoration: BoxDecoration(color: palette.bgBase)),
        ),
        // 左上角主光晕
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.85, -1.05),
                  radius: 1.6,
                  colors: [
                    palette.glassGlow.withValues(
                      alpha: palette.glassGlow.a * intensity,
                    ),
                    Colors.transparent,
                  ],
                  stops: const [0, 1],
                ),
              ),
            ),
          ),
        ),
        // 右下角次光晕（淡薰衣草）
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(1.15, 1.2),
                  radius: 1.4,
                  colors: [
                    palette.accentLavender.withValues(
                      alpha: (palette.isDark ? 0.10 : 0.14) * intensity,
                    ),
                    Colors.transparent,
                  ],
                  stops: const [0, 1],
                ),
              ),
            ),
          ),
        ),
        // 顶部细带高光（模拟边缘光）
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  Colors.white.withValues(alpha: palette.isDark ? 0.08 : 0.4),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        if (child != null) Positioned.fill(child: child!),
      ],
    );
  }
}
