import 'dart:async';
import 'dart:io';

import '../experience/experience.dart';
import '../identity/identity.dart';
import '../shared/hana_home.dart';
import 'agent_manager.dart';
import 'preferences_manager.dart';

/// 经验网络后台守护进程。
///
/// 负责：
/// - 定期向 DHT 注册在线状态（announcePresence）→ 修复 B4/B6
/// - 定期轮询未响应的需求并自动回包（answerMatchingExperienceDemands）→ 修复 B2/B6
///
/// 在 `HanaEngine.startAutomation()` 中启动。
class ExperienceNetworkDaemon {
  ExperienceNetworkDaemon({
    required this.home,
    required this.agentManager,
    required this.identityRepository,
    required this.preferences,
  });

  final HanaHome home;
  final AgentManager agentManager;
  final IdentityRepository identityRepository;
  final PreferencesManager preferences;

  Timer? _announceTimer;
  Timer? _demandPollTimer;
  bool _running = false;

  static const _announceInterval = Duration(minutes: 5);
  static const _demandPollInterval = Duration(minutes: 2);

  void start() {
    if (_running) return;
    _running = true;
    _announceTimer = Timer.periodic(_announceInterval, (_) {
      unawaited(_safeAnnounce());
    });
    _demandPollTimer = Timer.periodic(_demandPollInterval, (_) {
      unawaited(_safePollAndAnswer());
    });
    unawaited(_safeAnnounce());
  }

  Future<void> stop() async {
    _running = false;
    _announceTimer?.cancel();
    _demandPollTimer?.cancel();
    _announceTimer = null;
    _demandPollTimer = null;
  }

  Future<void> _safeAnnounce() async {
    try {
      await _announce();
    } catch (_) {}
  }

  Future<void> _safePollAndAnswer() async {
    try {
      await _pollAndAnswer();
    } catch (_) {}
  }

  Future<void> _announce() async {
    final identity = identityRepository.current;
    if (identity == null) return;
    final agentId = agentManager.activeAgentId;
    if (agentId == null) return;

    final dhtClient = await _resolveDhtClient();
    if (dhtClient == null) return;

    await dhtClient.announcePresence(
      presence: ExperienceDhtPresence(peerId: identity.publicKeyHash),
      keyPair: identity.keyPair,
    );
  }

  Future<void> _pollAndAnswer() async {
    final identity = identityRepository.current;
    if (identity == null) return;
    final agentId = agentManager.activeAgentId;
    if (agentId == null) return;

    final dhtClient = await _resolveDhtClient();
    if (dhtClient == null) return;

    final agentDir = home.agentDir(agentId);
    final store = ExperienceStore(agentDir: agentDir);
    final supplyWorkflow = ExperiencePackageSupplyWorkflow(
      store: store,
      dhtClient: dhtClient,
    );

    await supplyWorkflow.answerMatchingExperienceDemands(
      providerPeerId: identity.publicKeyHash,
      keyPair: identity.keyPair,
    );
  }

  ExperienceNetworkManagerClient? _managerClient;
  ExperienceDhtHttpClient? _cachedDhtClient;

  Future<ExperienceDhtHttpClient?> _resolveDhtClient() async {
    if (_cachedDhtClient != null) return _cachedDhtClient;
    _managerClient ??= ExperienceNetworkManagerClient();
    try {
      final nodes = await _managerClient!.fetchPublicDhtNodes();
      if (nodes.isEmpty) return null;
      final best = nodes.first;
      final url = best.apiBaseUrl;
      if (url == null) return null;
      _cachedDhtClient = ExperienceDhtHttpClient(dhtBaseUrl: url);
      return _cachedDhtClient;
    } catch (_) {
      return null;
    }
  }

  void invalidateDhtClient() {
    _cachedDhtClient = null;
  }

  Future<Map<String, dynamic>> publishDemand({
    required String query,
    List<String> keywords = const [],
    String? agentDirOverride,
  }) async {
    final identity = identityRepository.current;
    if (identity == null) {
      return {'ok': false, 'error': '请先创建或解锁子体身份'};
    }
    final agentId = agentManager.activeAgentId;
    if (agentId == null) {
      return {'ok': false, 'error': '无活跃 Agent'};
    }

    final dhtClient = await _resolveDhtClient();
    if (dhtClient == null) {
      return {'ok': false, 'error': '无法连接 DHT 节点'};
    }

    final agentDir = agentDirOverride != null
        ? Directory(agentDirOverride)
        : home.agentDir(agentId);
    final store = ExperienceStore(agentDir: agentDir);
    final workflow = ExperienceDemandPullWorkflow(
      store: store,
      dhtClient: dhtClient,
      managerClient: _managerClient,
    );

    final result = await workflow.requestAndImportBestOffer(
      query: query,
      requesterPeerId: identity.publicKeyHash,
      keyPair: identity.keyPair,
      queryKeywords: keywords,
    );

    final importOk = result.importResult.ok;
    return {
      'ok': true,
      'demand_id': result.demand.demand.requestId,
      'offers_count': result.offers.length,
      'imported': importOk,
      if (importOk && result.importResult.experienceId != null)
        'experience_id': result.importResult.experienceId,
      if (!importOk) 'import_message': result.importResult.message,
    };
  }
}
