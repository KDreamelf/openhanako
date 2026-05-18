import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/window_factory.dart';
import '../../core/session_coordinator.dart';
import '../design/design.dart';

/// 会话抽屉：Agent 切换 + 会话列表。
class SessionDrawer extends ConsumerWidget {
  const SessionDrawer({
    super.key,
    required this.onNewSession,
    required this.onSwitchSession,
  });

  final Future<void> Function() onNewSession;
  final Future<void> Function(SessionListEntry entry) onSwitchSession;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final activeAgentId = ref.watch(activeAgentIdProvider);
    final agents = ref.watch(agentListProvider);
    final sessions = ref.watch(sessionListProvider);

    return Drawer(
      width: DS.drawerWidth,
      backgroundColor: palette.bgRaised,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部品牌区
            _DrawerHeader(palette: palette),
            // Agent 标识区
            agents.maybeWhen(
              data: (list) {
                final current = activeAgentId == null
                    ? null
                    : list.firstWhere(
                        (a) => a.id == activeAgentId,
                        orElse: () => list.isEmpty
                            ? throw StateError('no agents')
                            : list.first,
                      );
                return _ActiveAgentCard(
                  agentLabel: current?.name ?? activeAgentId ?? '未选 Agent',
                  agentId: current?.id ?? activeAgentId,
                  onOpenSettings: () => WindowFactory.openSettings(context),
                );
              },
              orElse: () => _ActiveAgentCard(
                agentLabel: activeAgentId ?? '未选 Agent',
                agentId: activeAgentId,
                onOpenSettings: () => WindowFactory.openSettings(context),
              ),
            ),
            const SizedBox(height: DS.s12),
            // Section: 会话列表
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DS.s16),
              child: HanaSectionLabel(
                '会话',
                trailing: GlassIconButton(
                  icon: Icons.add_rounded,
                  size: 28,
                  iconSize: 16,
                  tooltip: '新建会话',
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await onNewSession();
                    if (context.mounted) navigator.pop();
                  },
                ),
              ),
            ),
            Expanded(
              child: sessions.when(
                loading: () => Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: palette.accentEmerald,
                    ),
                  ),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(DS.s16),
                  child: Center(
                    child: Text(
                      '加载失败：$e',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: palette.accentCrimson),
                    ),
                  ),
                ),
                data: (list) {
                  if (list.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(DS.s24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.forum_outlined,
                              size: 28,
                              color: palette.textTertiary,
                            ),
                            const SizedBox(height: DS.s10),
                            Text(
                              '还没有会话',
                              style: TextStyle(
                                color: palette.textSecondary,
                                fontSize: DS.t13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '点击右上角 + 开启第一段对话',
                              style: TextStyle(
                                color: palette.textTertiary,
                                fontSize: DS.t11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                      DS.s8,
                      DS.s4,
                      DS.s8,
                      DS.s12,
                    ),
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final s = list[i];
                      return _SessionTile(
                        entry: s,
                        onSwitchSession: onSwitchSession,
                      );
                    },
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

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({required this.palette});

  final HanaPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(DS.s16, DS.s14, DS.s16, DS.s10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      palette.accentEmerald,
                      palette.accentCyan,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(DS.r8),
                  boxShadow: [
                    BoxShadow(
                      color:
                          palette.accentEmerald.withValues(alpha: 0.42),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  color: palette.isDark
                      ? const Color(0xFF06120A)
                      : Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: DS.s10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'PH01 SUBBODY',
                      style: TextStyle(
                        color: palette.textTertiary,
                        fontSize: DS.t10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.8,
                      ),
                    ),
                    Text(
                      '幻宙 01',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: DS.t18,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                  ],
                ),
              ),
              GlassIconButton(
                icon: Icons.close_rounded,
                size: 28,
                iconSize: 16,
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActiveAgentCard extends StatelessWidget {
  const _ActiveAgentCard({
    required this.agentLabel,
    required this.agentId,
    required this.onOpenSettings,
  });

  final String agentLabel;
  final String? agentId;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DS.s16),
      child: GlassSurface(
        padding: const EdgeInsets.fromLTRB(DS.s10, DS.s10, DS.s10, DS.s10),
        radius: DS.r10,
        intensity: GlassIntensity.subtle,
        elevated: false,
        child: Row(
          children: [
            HanaAvatar(label: agentLabel, size: 36),
            const SizedBox(width: DS.s10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    agentLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: DS.t14,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      StatusDot(
                        color: agentId == null
                            ? palette.accentCrimson
                            : palette.accentEmerald,
                        size: 6,
                        pulse: agentId != null,
                      ),
                      const SizedBox(width: DS.s6),
                      Flexible(
                        child: Text(
                          agentId == null ? '等待选择' : 'Agent · ${agentId!}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textSecondary,
                            fontSize: DS.t11,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            GlassIconButton(
              icon: Icons.tune_rounded,
              size: 28,
              iconSize: 15,
              tooltip: '设置',
              onPressed: onOpenSettings,
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionTile extends ConsumerStatefulWidget {
  const _SessionTile({required this.entry, required this.onSwitchSession});

  final SessionListEntry entry;
  final Future<void> Function(SessionListEntry entry) onSwitchSession;

  @override
  ConsumerState<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends ConsumerState<_SessionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final fmt = DateFormat('MM-dd HH:mm');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: DS.dFast,
          decoration: BoxDecoration(
            color: _hover
                ? palette.glassFillStrong
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DS.r8),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(DS.r8),
            child: InkWell(
              borderRadius: BorderRadius.circular(DS.r8),
              onTap: () async {
                final navigator = Navigator.of(context);
                await widget.onSwitchSession(widget.entry);
                if (context.mounted) navigator.pop();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: DS.s12,
                  vertical: DS.s10,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 32,
                      margin: const EdgeInsets.only(right: DS.s10),
                      decoration: BoxDecoration(
                        gradient: _hover
                            ? LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  palette.accentEmerald,
                                  palette.accentCyan,
                                ],
                              )
                            : null,
                        color: _hover ? null : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.entry.title.isEmpty
                                ? '(未命名会话)'
                                : widget.entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: DS.t13,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            fmt.format(widget.entry.modified.toLocal()),
                            style: TextStyle(
                              color: palette.textTertiary,
                              fontSize: DS.t11,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedOpacity(
                      opacity: _hover ? 1 : 0,
                      duration: DS.dFast,
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        size: 14,
                        color: palette.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
