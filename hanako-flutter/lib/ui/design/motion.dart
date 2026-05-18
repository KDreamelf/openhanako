import 'package:flutter/material.dart';

import 'tokens.dart';

/// 动效辅助：让一个 widget 在进入视图时淡入 + 轻微上移。
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = DS.dBase,
    this.offset = 8.0,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;
  final double offset;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration);
    if (widget.delay == Duration.zero) {
      _ctrl.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _ctrl.forward();
      });
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
      builder: (_, child) {
        final t = Curves.easeOutCubic.transform(_ctrl.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, widget.offset * (1 - t)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// 可交互悬浮（hover 时整体抬升 + 缩放）。
class HoverLift extends StatefulWidget {
  const HoverLift({
    super.key,
    required this.child,
    this.scale = 1.012,
    this.lift = 1.0,
    this.disabled = false,
  });

  final Widget child;
  final double scale;
  final double lift;
  final bool disabled;

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (widget.disabled) return widget.child;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _hover ? widget.scale : 1.0,
        duration: DS.dQuick,
        curve: DS.cStandard,
        child: AnimatedSlide(
          offset: Offset(0, _hover ? -widget.lift / 100 : 0),
          duration: DS.dQuick,
          curve: DS.cStandard,
          child: widget.child,
        ),
      ),
    );
  }
}

/// 流式打字光标 — 闪烁的小方块。
class TypingCaret extends StatefulWidget {
  const TypingCaret({super.key, this.color, this.height = 16});

  final Color? color;
  final double height;

  @override
  State<TypingCaret> createState() => _TypingCaretState();
}

class _TypingCaretState extends State<TypingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = widget.color ?? palette.accentEmerald;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        return Opacity(
          opacity: 0.18 + _ctrl.value * 0.82,
          child: Container(
            width: 2.6,
            height: widget.height,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1.4),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.55),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
