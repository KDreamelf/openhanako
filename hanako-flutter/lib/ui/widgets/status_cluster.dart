import 'package:flutter/material.dart';

import '../design/design.dart';

/// 状态簇 — header 右上角的横排状态药丸群。
///
/// 折叠态：圆形 icon 灯，hover 或点击展开为带文字的胶囊。
/// 展开方向由 [expandLeft] 控制。
class StatusClusterItem {
  const StatusClusterItem({
    required this.icon,
    required this.label,
    required this.color,
    this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final String? tooltip;
  final VoidCallback? onPressed;
}

class StatusCluster extends StatelessWidget {
  const StatusCluster({
    super.key,
    required this.items,
    this.expandLeft = false,
    this.spacing = DS.s6,
    this.runSpacing = DS.s6,
    this.maxExpandedWidth = 200,
    this.collapsedSize = 26,
    this.iconSize = 13,
  });

  final List<StatusClusterItem> items;
  final bool expandLeft;
  final double spacing;
  final double runSpacing;
  final double maxExpandedWidth;
  final double collapsedSize;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      children: [
        for (final item in items)
          _StatusBadge(
            item: item,
            expandLeft: expandLeft,
            maxExpandedWidth: maxExpandedWidth,
            collapsedSize: collapsedSize,
            iconSize: iconSize,
          ),
      ],
    );
  }
}

class _StatusBadge extends StatefulWidget {
  const _StatusBadge({
    required this.item,
    required this.expandLeft,
    required this.maxExpandedWidth,
    required this.collapsedSize,
    required this.iconSize,
  });

  final StatusClusterItem item;
  final bool expandLeft;
  final double maxExpandedWidth;
  final double collapsedSize;
  final double iconSize;

  @override
  State<_StatusBadge> createState() => _StatusBadgeState();
}

class _StatusBadgeState extends State<_StatusBadge>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  bool _pinnedOpen = false;
  bool _pressed = false;

  bool get _expanded => _hovered || _pinnedOpen;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  void _handleTap() {
    widget.item.onPressed?.call();
    if (!mounted) return;
    setState(() => _pinnedOpen = !_pinnedOpen);
  }

  @override
  Widget build(BuildContext context) {
    final tooltip = widget.item.tooltip?.trim().isNotEmpty == true
        ? widget.item.tooltip!.trim()
        : widget.item.label;
    final palette = context.palette;
    final accent = widget.item.color;
    final hoverScale = _pressed ? 0.96 : (_expanded ? 1.04 : 1.0);

    final badge = AnimatedSize(
      duration: DS.dQuick,
      curve: DS.cStandard,
      alignment: widget.expandLeft
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: AnimatedSwitcher(
        duration: DS.dFast,
        switchInCurve: DS.cEnter,
        switchOutCurve: DS.cExit,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.0).animate(anim),
            child: child,
          ),
        ),
        child: _expanded
            ? _buildExpanded(context, palette, accent, tooltip)
            : _buildCollapsed(context, palette, accent, tooltip),
      ),
    );

    return MouseRegion(
      cursor: widget.item.onPressed != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: AnimatedScale(
        scale: hoverScale,
        duration: DS.dFast,
        curve: DS.cStandard,
        child: Semantics(button: true, label: widget.item.label, child: badge),
      ),
    );
  }

  Widget _buildCollapsed(
    BuildContext context,
    HanaPalette palette,
    Color accent,
    String tooltip,
  ) {
    final iconColor = Color.lerp(palette.textSecondary, accent, 0.78)!;
    return Tooltip(
      message: tooltip,
      child: Material(
        key: const ValueKey('status-badge-collapsed'),
        color: accent.withValues(alpha: palette.isDark ? 0.10 : 0.085),
        shape: CircleBorder(
          side: BorderSide(
            color: accent.withValues(alpha: palette.isDark ? 0.30 : 0.36),
            width: DS.hairline,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _handleTap,
          onHighlightChanged: (v) => setState(() => _pressed = v),
          splashColor: accent.withValues(alpha: 0.18),
          hoverColor: accent.withValues(alpha: 0.05),
          child: SizedBox.square(
            dimension: widget.collapsedSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  widget.item.icon,
                  size: widget.iconSize,
                  color: iconColor,
                ),
                Positioned(
                  top: 3,
                  right: 3,
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.7),
                          blurRadius: 3,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded(
    BuildContext context,
    HanaPalette palette,
    Color accent,
    String tooltip,
  ) {
    final foreground = Color.lerp(palette.textPrimary, accent, 0.55)!;
    final children = <Widget>[
      if (widget.expandLeft)
        _StatusBadgeLabel(
          label: widget.item.label,
          color: foreground,
          maxWidth: widget.maxExpandedWidth,
        ),
      if (widget.expandLeft) const SizedBox(width: DS.s6),
      Icon(widget.item.icon, size: widget.iconSize, color: foreground),
      if (!widget.expandLeft) const SizedBox(width: DS.s6),
      if (!widget.expandLeft)
        _StatusBadgeLabel(
          label: widget.item.label,
          color: foreground,
          maxWidth: widget.maxExpandedWidth,
        ),
    ];
    return Tooltip(
      message: tooltip,
      child: Material(
        key: const ValueKey('status-badge-expanded'),
        color: accent.withValues(alpha: palette.isDark ? 0.12 : 0.10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DS.rPill),
          side: BorderSide(
            color: accent.withValues(alpha: palette.isDark ? 0.36 : 0.42),
            width: DS.hairline,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _handleTap,
          onHighlightChanged: (v) => setState(() => _pressed = v),
          splashColor: accent.withValues(alpha: 0.18),
          hoverColor: accent.withValues(alpha: 0.05),
          child: Container(
            constraints:
                BoxConstraints(maxWidth: widget.maxExpandedWidth + 30),
            padding: const EdgeInsets.symmetric(horizontal: DS.s10),
            height: widget.collapsedSize,
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }
}

class _StatusBadgeLabel extends StatelessWidget {
  const _StatusBadgeLabel({
    required this.label,
    required this.color,
    required this.maxWidth,
  });

  final String label;
  final Color color;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: TextStyle(
          color: color,
          fontSize: DS.t12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
