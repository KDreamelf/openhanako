import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/window_factory.dart';
import '../../core/session_coordinator.dart';

/// 侧边 Session Drawer：显示当前 agent 的 session 列表。
class SessionDrawer extends ConsumerWidget {
  const SessionDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeAgent = ref.watch(activeAgentIdProvider);
    final agents = ref.watch(agentListProvider);
    final sessions = ref.watch(sessionListProvider);

    return Drawer(
      width: 320,
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: agents.maybeWhen(
                data: (list) {
                  final me = list.firstWhere(
                    (a) => a.id == activeAgent,
                    orElse: () => list.isEmpty
                        ? throw StateError('no agents')
                        : list.first,
                  );
                  return Text(me.name);
                },
                orElse: () => const Text('未选择 agent'),
              ),
              subtitle: Text('Agent · ${activeAgent ?? "无"}'),
              trailing: IconButton(
                icon: const Icon(Icons.tune),
                tooltip: '设置',
                onPressed: () => WindowFactory.openSettings(),
              ),
            ),
            const Divider(height: 0),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text('Sessions',
                      style: Theme.of(context).textTheme.labelLarge),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: '新建会话',
                    onPressed: () async {
                      final eng = ref.read(engineProvider);
                      await eng.sessionCoordinator.createSession();
                      ref.invalidate(sessionListProvider);
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: sessions.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Error: $e')),
                data: (list) {
                  if (list.isEmpty) {
                    return const Center(child: Text('（暂无会话）'));
                  }
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final s = list[i];
                      return _SessionTile(entry: s);
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

class _SessionTile extends ConsumerWidget {
  final SessionListEntry entry;
  const _SessionTile({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fmt = DateFormat('MM-dd HH:mm');
    return ListTile(
      dense: true,
      title: Text(
        entry.title.isEmpty ? '(未命名)' : entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(fmt.format(entry.modified.toLocal())),
      onTap: () async {
        final eng = ref.read(engineProvider);
        await eng.sessionCoordinator.switchSession(entry.path);
      },
    );
  }
}
