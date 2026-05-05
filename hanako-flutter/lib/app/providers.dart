import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/agent.dart';
import '../core/engine.dart';
import '../core/session_coordinator.dart';
import '../identity/identity.dart';

/// Riverpod providers 集中。
///
/// 设计原则（参考 flutter-migration-plan/02-多窗口实现方案.md）：
///   - 业务核心 [HanaEngine] 是同进程单例，主窗口持有；
///   - 子窗口不能直接访问 engine（独立 Flutter Engine / Isolate），
///     必须经 IPC business.invoke 走主窗口；
///   - UI 状态（主题、侧栏折叠等）各窗口私有。

/// engineProvider 由 main.dart 在主窗口启动时 override 注入。
/// 子窗口请勿直接 watch 它（默认抛 UnimplementedError）。
final engineProvider = Provider<HanaEngine>((ref) {
  throw UnimplementedError(
    'engineProvider must be overridden in main window ProviderScope',
  );
});

/// 子体身份仓库（密钥对 / 助记词 / 故事 / 私钥安全存储）。
///
/// 与 engineProvider 同样在 main.dart 的 ProviderScope 中注入。
/// 引导页和登录页通过本 provider 调用 [IdentityRepository.registerNew]、
/// [IdentityRepository.unlock]、[IdentityRepository.loginWithStory]。
final identityRepositoryProvider = Provider<IdentityRepository>((ref) {
  throw UnimplementedError(
    'identityRepositoryProvider must be overridden in main window ProviderScope',
  );
});

/// 当前活动 agent ID（响应 agentManager.activeAgentId 变化）。
final activeAgentIdProvider = StateProvider<String?>((ref) {
  final eng = ref.watch(engineProvider);
  return eng.agentManager.activeAgentId;
});

/// agent 列表。FutureProvider 自动缓存。
final agentListProvider = FutureProvider<List<Agent>>((ref) async {
  final eng = ref.watch(engineProvider);
  return eng.agentManager.listAgents();
});

/// session 列表（按当前 active agent）。
final sessionListProvider = FutureProvider<List<SessionListEntry>>((ref) async {
  ref.watch(activeAgentIdProvider);
  final eng = ref.watch(engineProvider);
  return eng.sessionCoordinator.listSessions();
});

/// 主题模式（light / dark / system）。
final themeModeProvider = StateProvider<AppThemeMode>(
  (_) => AppThemeMode.system,
);

enum AppThemeMode {
  light,
  dark,
  system;

  String get label => switch (this) {
    AppThemeMode.light => '浅色',
    AppThemeMode.dark => '深色',
    AppThemeMode.system => '跟随系统',
  };
}

/// 侧栏（session drawer）展开状态。
final sidebarOpenProvider = StateProvider<bool>((_) => true);
