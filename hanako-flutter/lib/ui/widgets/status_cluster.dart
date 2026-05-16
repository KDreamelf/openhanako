import 'package:flutter/material.dart';

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
    this.spacing = 6,
    this.runSpacing = 6,
    this.maxExpandedWidth = 220,
    this.collapsedSize = 26,
    this.iconSize = 14,
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
    final badge = AnimatedSize(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      alignment: widget.expandLeft
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 120),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: _expanded
            ? _buildExpanded(context, tooltip)
            : _buildCollapsed(context, tooltip),
      ),
    );

    return MouseRegion(
      cursor: widget.item.onPressed != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Semantics(button: true, label: widget.item.label, child: badge),
    );
  }

  Widget _buildCollapsed(BuildContext context, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: Material(
        key: const ValueKey('status-badge-collapsed'),
        color: widget.item.color.withAlpha(30),
        shape: CircleBorder(
          side: BorderSide(color: widget.item.color.withAlpha(90)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _handleTap,
          child: SizedBox.square(
            dimension: widget.collapsedSize,
            child: Icon(
              widget.item.icon,
              size: widget.iconSize,
              color: widget.item.color,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded(BuildContext context, String tooltip) {
    final children = <Widget>[
      if (widget.expandLeft)
        _StatusBadgeLabel(
          label: widget.item.label,
          color: widget.item.color,
          maxWidth: widget.maxExpandedWidth,
        ),
      if (widget.expandLeft) const SizedBox(width: 6),
      Icon(widget.item.icon, size: widget.iconSize, color: widget.item.color),
      if (!widget.expandLeft) const SizedBox(width: 6),
      if (!widget.expandLeft)
        _StatusBadgeLabel(
          label: widget.item.label,
          color: widget.item.color,
          maxWidth: widget.maxExpandedWidth,
        ),
    ];
    return Tooltip(
      message: tooltip,
      child: Material(
        key: const ValueKey('status-badge-expanded'),
        color: widget.item.color.withAlpha(24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(color: widget.item.color.withAlpha(72)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _handleTap,
          child: Container(
            constraints: BoxConstraints(maxWidth: widget.maxExpandedWidth + 28),
            padding: const EdgeInsets.symmetric(horizontal: 8),
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
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
