import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/window_factory.dart';
import '../../core/session_coordinator.dart';
import '../../experience/experience.dart';
import '../../windows_ops/windows_ops.dart';
import '../design/design.dart';

/// 设计图里左侧常驻 sidebar — 在主聊天页 ≥1100px 宽屏下显示，<1100px 退化为
/// Drawer（保留原弹出交互）。
///
/// 数据全部来自真实 provider：
///   - 角色列表：[agentListProvider]
///   - 会话列表：[sessionListProvider]（当前 active agent 的）
///   - 状态摘要：[currentIdentityProvider] / [experienceNetworkStatusProvider] /
///     [windowsOpsStatusProvider]
/// 切换 agent 会同时 await [HanaEngine.agentManager.switchAgent] 并把
/// [activeAgentIdProvider] 推到新值，然后让 chat / desk / memory 等其它
/// per-agent provider 自动失效重读。
class PersistentSidebar extends ConsumerStatefulWidget {
  const PersistentSidebar({
    super.key,
    required this.onSwitchSession,
    required this.onNewSession,
  });

  /// 切换会话回调（由 chat_page 提供，调用 ChatNotifier.switchSession）。
  final Future<void> Function(SessionListEntry entry) onSwitchSession;

  /// 新建会话回调。
  final Future<void> Function() onNewSession;

  @override
  ConsumerState<PersistentSidebar> createState() => _PersistentSidebarState();
}

class _PersistentSidebarState extends ConsumerState<PersistentSidebar> {
  Future<void> _switchAgent(String agentId) async {
    final eng = ref.read(engineProvider);
    if (eng.agentManager.activeAgentId == agentId) return;
    try {
      await eng.agentManager.switchAgent(agentId);
      ref.read(activeAgentIdProvider.notifier).state = agentId;
      ref.invalidate(agentListProvider);
      ref.invalidate(sessionListProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('切换 Agent 失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final activeAgentId = ref.watch(activeAgentIdProvider);
    final agents = ref.watch(agentListProvider);
    final sessions = ref.watch(sessionListProvider);
    final identity = ref.watch(currentIdentityProvider);
    final networkStatus = ref.watch(experienceNetworkStatusProvider).asData?.value;
    final winOps = ref.watch(windowsOpsStatusProvider).asData?.value;

    return Container(
      width: DS.sidebarWidth,
      decoration: BoxDecoration(
        color: palette.bgRaised.withValues(alpha: palette.isDark ? 0.55 : 0.86),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomLeft,
          colors: [
            palette.bgRaised.withValues(alpha: palette.isDark ? 0.62 : 0.92),
            palette.bgBase.withValues(alpha: palette.isDark ? 0.42 : 0.86),
          ],
        ),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SidebarBrandHeader(),
            Container(
              height: DS.hairline,
              color: palette.divider,
            ),
            Expanded(
              child: ScrollConfiguration(
                behavior: const _SidebarScrollBehavior(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    DS.s12,
                    DS.s12,
                    DS.s12,
                    DS.s12,
                  ),
                  children: [
                    HanaSectionLabel(
                      '角色',
                      trailing: agents.maybeWhen(
                        data: (list) => Text(
                          '${list.length}',
                          style: TextStyle(
                            color: palette.textTertiary,
                            fontSize: DS.t10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        orElse: () => const SizedBox.shrink(),
                      ),
                    ),
                    agents.when(
                      data: (list) {
                        if (list.isEmpty) {
                          return _SidebarEmpty(
                            icon: Icons.account_tree_outlined,
                            text: '尚未创建 Agent',
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final a in list)
                              _AgentTile(
                                agent: a,
                                active: a.id == activeAgentId,
                                onTap: () => _switchAgent(a.id),
                              ),
                          ],
                        );
                      },
                      loading: () => Padding(
                        padding: const EdgeInsets.all(DS.s10),
                        child: Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.accentEmerald,
                            ),
                          ),
                        ),
                      ),
                      error: (e, _) => _SidebarErrorLine('$e'),
                    ),
                    const SizedBox(height: DS.s14),
                    HanaSectionLabel(
                      '会话',
                      trailing: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(DS.r6),
                          onTap: () async {
                            await widget.onNewSession();
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.add_rounded,
                              size: 14,
                              color: palette.accentEmerald,
                            ),
                          ),
                        ),
                      ),
                    ),
                    sessions.when(
                      data: (list) {
                        if (list.isEmpty) {
                          return _SidebarEmpty(
                            icon: Icons.forum_outlined,
                            text: '还没有会话',
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final s in list)
                              _SessionTile(
                                entry: s,
                                onTap: () async {
                                  await widget.onSwitchSession(s);
                                },
                              ),
                          ],
                        );
                      },
                      loading: () => Padding(
                        padding: const EdgeInsets.all(DS.s10),
                        child: Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: palette.accentCyan,
                            ),
                          ),
                        ),
                      ),
                      error: (e, _) => _SidebarErrorLine('$e'),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              height: DS.hairline,
              color: palette.divider,
            ),
            Padding(
              padding: const EdgeInsets.all(DS.s12),
              child: _RuntimeStatusCard(
                identityReady: identity != null,
                networkStatus: networkStatus,
                winOps: winOps,
                onOpenSettings: () => WindowFactory.openSettings(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarBrandHeader extends StatelessWidget {
  const _SidebarBrandHeader();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DS.s16, DS.s16, DS.s16, DS.s14),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  palette.accentEmerald,
                  palette.accentCyan,
                  palette.accentLavender,
                ],
              ),
              borderRadius: BorderRadius.circular(DS.r10),
              boxShadow: [
                BoxShadow(
                  color: palette.accentEmerald.withValues(alpha: 0.42),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(
              Icons.auto_awesome_rounded,
              color: palette.isDark
                  ? const Color(0xFF06120A)
                  : Colors.white,
              size: 20,
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
                const SizedBox(height: 2),
                Text(
                  '幻宙 01',
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: DS.t20,
                    fontWeight: FontWeight.w700,
                    height: 1.05,
                    letterSpacing: 0.1,
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

class _AgentTile extends StatefulWidget {
  const _AgentTile({
    required this.agent,
    required this.active,
    required this.onTap,
  });

  final dynamic agent; // Agent — kept dynamic to avoid cross-import overhead
  final bool active;
  final VoidCallback onTap;

  @override
  State<_AgentTile> createState() => _AgentTileState();
}

class _AgentTileState extends State<_AgentTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = palette.accentEmerald;
    final agent = widget.agent;
    final String name = agent.name as String;
    final String yuan = agent.yuan as String? ?? 'hanako';
    final bool isPrimary = (agent.isPrimary as bool?) ?? false;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DS.dFast,
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: widget.active
              ? accent.withValues(alpha: palette.isDark ? 0.14 : 0.10)
              : _hover
                  ? palette.glassFillStrong
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(DS.r8),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(DS.r8),
          child: InkWell(
            borderRadius: BorderRadius.circular(DS.r8),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(DS.s8, DS.s8, DS.s8, DS.s8),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 32,
                    margin: const EdgeInsets.only(right: DS.s8),
                    decoration: BoxDecoration(
                      gradient: widget.active
                          ? LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [accent, palette.accentCyan],
                            )
                          : null,
                      color: widget.active ? null : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: widget.active
                          ? [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.45),
                                blurRadius: 6,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  HanaAvatar(label: name, size: 30),
                  const SizedBox(width: DS.s10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t13,
                            fontWeight: widget.active
                                ? FontWeight.w700
                                : FontWeight.w600,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.active) ...[
                              StatusDot(
                                color: accent,
                                size: 5,
                                pulse: true,
                                glow: true,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Flexible(
                              child: Text(
                                widget.active
                                    ? '激活 · $yuan'
                                    : (isPrimary ? '主体 · $yuan' : yuan),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.textTertiary,
                                  fontSize: DS.t10,
                                  fontFamilyFallback: DS.monoFallback,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionTile extends StatefulWidget {
  const _SessionTile({required this.entry, required this.onTap});

  final SessionListEntry entry;
  final VoidCallback onTap;

  @override
  State<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends State<_SessionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final fmt = DateFormat('MM-dd HH:mm');
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DS.dFast,
        margin: const EdgeInsets.symmetric(vertical: 1),
        decoration: BoxDecoration(
          color: _hover ? palette.glassFillStrong : Colors.transparent,
          borderRadius: BorderRadius.circular(DS.r6),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(DS.r6),
          child: InkWell(
            borderRadius: BorderRadius.circular(DS.r6),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(DS.s8, 6, DS.s8, 6),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: DS.dFast,
                    width: 3,
                    height: 22,
                    margin: const EdgeInsets.only(right: DS.s8),
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
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.entry.title.isEmpty
                              ? '(未命名)'
                              : widget.entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t12,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          fmt.format(widget.entry.modified.toLocal()),
                          style: TextStyle(
                            color: palette.textTertiary,
                            fontSize: DS.t10,
                            fontFamilyFallback: DS.monoFallback,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarEmpty extends StatelessWidget {
  const _SidebarEmpty({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: DS.s14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: palette.textTertiary),
          const SizedBox(height: 4),
          Text(
            text,
            style: TextStyle(
              color: palette.textTertiary,
              fontSize: DS.t11,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarErrorLine extends StatelessWidget {
  const _SidebarErrorLine(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: DS.s8,
        vertical: DS.s8,
      ),
      child: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: palette.accentCrimson,
          fontSize: DS.t11,
        ),
      ),
    );
  }
}

class _RuntimeStatusCard extends StatelessWidget {
  const _RuntimeStatusCard({
    required this.identityReady,
    required this.networkStatus,
    required this.winOps,
    required this.onOpenSettings,
  });

  final bool identityReady;
  final ExperienceNetworkStatus? networkStatus;
  final WindowsOpsCapabilities? winOps;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final identityColor =
        identityReady ? palette.accentEmerald : palette.accentCrimson;
    final identityLabel = identityReady ? '身份已解锁' : '身份未解锁';
    final networkColor = _netColor(palette);
    final networkLabel = _netLabel();
    final opsColor = _opsColor(palette);
    final opsLabel = _opsLabel();
    final overallReady = identityReady &&
        identityColor == palette.accentEmerald &&
        networkColor == palette.accentEmerald &&
        opsColor == palette.accentEmerald;
    return Container(
      padding: const EdgeInsets.all(DS.s12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            (overallReady ? palette.accentEmerald : palette.accentAmber)
                .withValues(alpha: palette.isDark ? 0.10 : 0.08),
            palette.bgRaised.withValues(alpha: palette.isDark ? 0.50 : 0.86),
          ],
        ),
        borderRadius: BorderRadius.circular(DS.r10),
        border: Border.all(
          color: (overallReady ? palette.accentEmerald : palette.accentAmber)
              .withValues(alpha: 0.36),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                overallReady ? 'READY' : 'STANDBY',
                style: TextStyle(
                  color: overallReady
                      ? palette.accentEmerald
                      : palette.accentAmber,
                  fontSize: DS.t10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
              const Spacer(),
              StatusDot(
                color: overallReady
                    ? palette.accentEmerald
                    : palette.accentAmber,
                size: 6,
                pulse: !overallReady,
                glow: true,
              ),
            ],
          ),
          const SizedBox(height: DS.s8),
          _StatusLine(
            color: identityColor,
            label: identityLabel,
          ),
          const SizedBox(height: 6),
          _StatusLine(
            color: networkColor,
            label: networkLabel,
          ),
          const SizedBox(height: 6),
          _StatusLine(
            color: opsColor,
            label: opsLabel,
          ),
          const SizedBox(height: DS.s10),
          SizedBox(
            width: double.infinity,
            child: GlassButton(
              icon: Icons.tune_rounded,
              label: '打开设置',
              onPressed: onOpenSettings,
              dense: true,
            ),
          ),
        ],
      ),
    );
  }

  Color _netColor(HanaPalette p) {
    final s = networkStatus;
    if (s == null) return p.accentAmber;
    if (s.error != null || s.connectedDhtCount == 0) return p.accentCrimson;
    if (s.ipv6Status == ExperienceNetworkPathStatus.direct ||
        s.ipv4Status == ExperienceNetworkPathStatus.holePunchable) {
      return p.accentEmerald;
    }
    if (s.ipv4Status == ExperienceNetworkPathStatus.notPunchable) {
      return p.accentAmber;
    }
    return p.accentAmber;
  }

  String _netLabel() {
    final s = networkStatus;
    if (s == null) return 'DHT 探测中';
    if (s.connectedDhtCount == 0) return 'DHT 未连接';
    return 'DHT ${s.connectedDhtCount}/${s.configuredDhtCount}';
  }

  Color _opsColor(HanaPalette p) {
    final s = winOps;
    if (s == null) return p.accentAmber;
    if (!s.sidecar) return p.accentCrimson;
    if (s.inputMouse && s.inputKeyboard && s.uiParsing && s.ocr) {
      return p.accentEmerald;
    }
    if (s.inputMouse || s.inputKeyboard || s.uiaTree) return p.accentEmerald;
    return p.accentAmber;
  }

  String _opsLabel() {
    final s = winOps;
    if (s == null) return '界面操作待加载';
    if (!s.sidecar) return '界面操作未就绪';
    final parts = <String>[];
    if (s.inputMouse && s.inputKeyboard) parts.add('输入');
    if (s.uiParsing) parts.add('UI 模型');
    if (s.ocr) parts.add('OCR');
    if (parts.isEmpty) return '界面操作待准备';
    return parts.join(' · ');
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        StatusDot(color: color, size: 5, glow: true),
        const SizedBox(width: DS.s8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: DS.t11,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }
}

class _SidebarScrollBehavior extends ScrollBehavior {
  const _SidebarScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: false,
      thickness: 4,
      radius: const Radius.circular(DS.r6),
      child: child,
    );
  }
}
