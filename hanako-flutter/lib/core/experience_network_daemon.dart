import 'dart:async';
import 'dart:io';

import '../experience/experience.dart';
import '../identity/identity.dart';
import '../shared/hana_home.dart';
import 'agent_manager.dart';
import 'preferences_manager.dart';

/// 经验网络后台守护进程。
///
/// 当前阶段：通过中心化 DHT HTTP API 完成需求发布/响应/在线注册。
/// 设计目标（见 docs/experience-p2p-protocol.md）是 P2P gossip 协议，
/// 但协议层（DemandPropagator / ResponseRouter / NeighborTable）尚未实现。
///
/// 负责：
/// - 定期向 DHT 注册在线状态（announcePresence）
/// - 定期轮询未响应的需求并自动回包（answerMatchingExperienceDemands）
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
  bool _announcing = false;
  bool _polling = false;
  int _dhtResolveFailures = 0;

  static const _announceInterval = Duration(minutes: 5);
  static const _demandPollInterval = Duration(minutes: 2);
  static const _maxDhtResolveBackoff = Duration(minutes: 30);

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
    if (_announcing) return;
    _announcing = true;
    try {
      await _announce();
    } catch (_) {
    } finally {
      _announcing = false;
    }
  }

  Future<void> _safePollAndAnswer() async {
    if (_polling) return;
    _polling = true;
    try {
      await _pollAndAnswer();
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  Future<void> _announce() async {
    final identity = identityRepository.current;
    if (identity == null) return;
    final agentId = agentManager.activeAgentId;
    if (agentId == null) return;

    final dhtClient = await _resolveDhtClient();
    if (dhtClient == null) return;

    final agentDir = home.agentDir(agentId);
    final store = ExperienceStore(agentDir: agentDir);
    final packageHashes = await _collectLocalPackageHashes(store);

    await dhtClient.announcePresence(
      presence: ExperienceDhtPresence(
        peerId: identity.publicKeyHash,
        ownerPeerId: identity.publicKeyHash,
        packageHashes: packageHashes,
      ),
      keyPair: identity.keyPair,
    );
  }

  Future<List<String>> _collectLocalPackageHashes(ExperienceStore store) async {
    try {
      final items = await store.list();
      return items
          .map((e) => e.experienceId)
          .where((id) => id.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
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
  DateTime? _nextDhtResolveAttempt;

  Future<ExperienceDhtHttpClient?> _resolveDhtClient() async {
    if (_cachedDhtClient != null) return _cachedDhtClient;

    final now = DateTime.now();
    if (_nextDhtResolveAttempt != null && now.isBefore(_nextDhtResolveAttempt!)) {
      return null;
    }

    _managerClient ??= ExperienceNetworkManagerClient();
    try {
      final nodes = await _managerClient!.fetchPublicDhtNodes();
      if (nodes.isEmpty) {
        _onDhtResolveFailed();
        return null;
      }
      final best = nodes.first;
      final url = best.apiBaseUrl;
      if (url == null) {
        _onDhtResolveFailed();
        return null;
      }
      _cachedDhtClient = ExperienceDhtHttpClient(dhtBaseUrl: url);
      _dhtResolveFailures = 0;
      _nextDhtResolveAttempt = null;
      return _cachedDhtClient;
    } catch (_) {
      _onDhtResolveFailed();
      return null;
    }
  }

  void _onDhtResolveFailed() {
    _dhtResolveFailures++;
    final backoffSeconds = (30 * _dhtResolveFailures)
        .clamp(30, _maxDhtResolveBackoff.inSeconds);
    _nextDhtResolveAttempt =
        DateTime.now().add(Duration(seconds: backoffSeconds));
  }

  void invalidateDhtClient() {
    _cachedDhtClient = null;
    _dhtResolveFailures = 0;
    _nextDhtResolveAttempt = null;
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
