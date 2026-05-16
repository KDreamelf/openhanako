import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/agent.dart';
import '../core/engine.dart';
import '../core/session_coordinator.dart';
import '../experience/experience.dart';
import '../identity/identity.dart';
import '../windows_ops/windows_ops.dart';

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

/// 身份状态版本号。IdentityRepository 本身是可变对象，注册 / 解锁 / 锁定后
/// 需要递增此值，通知 UI 重新读取 current。
final identityRevisionProvider = StateProvider<int>((_) => 0);

final currentIdentityProvider = Provider<HanakoIdentity?>((ref) {
  ref.watch(identityRevisionProvider);
  return ref.watch(identityRepositoryProvider).current;
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

/// 经验网络 DHT 状态。
///
/// 主窗口顶部状态栏使用它显示公共/私有 DHT 可连接数量，以及当前 IPv6/IPv4
/// 网络能力评分。探测只做管理端 DHT 列表读取和 DHT `/healthz` 轻量检查。
final experienceNetworkStatusProvider = StreamProvider<ExperienceNetworkStatus>(
  (ref) async* {
    final eng = ref.watch(engineProvider);
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 2),
        sendTimeout: const Duration(seconds: 2),
      ),
    );
    ref.onDispose(() => dio.close());
    while (true) {
      final cfg = eng.config.read();
      final dhtConfig = ExperienceDhtClientConfig.fromJson(
        _stringKeyMap(_stringKeyMap(cfg['experience'])['dht_client']),
      );
      const managerBaseUrl =
          ExperienceNetworkManagerClient.defaultManagerBaseUrl;
      try {
        yield await ExperienceNetworkStatusProbe(
          config: dhtConfig,
          fallbackManagerBaseUrl: managerBaseUrl,
          dio: dio,
        ).probe();
      } catch (e) {
        yield ExperienceNetworkStatus.unavailable(
          managerBaseUrl: managerBaseUrl,
          error: '$e',
        );
      }
      await _waitForExperienceNetworkRefresh(eng);
    }
  },
);

/// Windows 操作链状态。
///
/// 顶部状态栏用它展示 sidecar、截图、鼠标/键盘输入、OCR 和本地界面识别
/// 模型是否已经就绪。探测会触发 sidecar 能力检查；未就绪能力不会注册给 AI。
final windowsOpsStatusProvider = FutureProvider<WindowsOpsCapabilities>((
  ref,
) async {
  final eng = ref.watch(engineProvider);
  return eng.sessionCoordinator.resolveWindowsOpsCapabilities();
});

Future<void> _waitForExperienceNetworkRefresh(HanaEngine eng) {
  final completer = Completer<void>();
  Timer? timer;
  StreamSubscription<Map<String, dynamic>>? subscription;

  void complete() {
    if (completer.isCompleted) return;
    timer?.cancel();
    subscription?.cancel();
    completer.complete();
  }

  timer = Timer(const Duration(seconds: 30), complete);
  subscription = eng.config.onChanged.listen((_) => complete());
  return completer.future;
}

Map<String, dynamic> _stringKeyMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, dynamic value) => MapEntry('$key', value));
}
