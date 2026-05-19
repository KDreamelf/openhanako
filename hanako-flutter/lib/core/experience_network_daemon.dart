import 'dart:async';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../experience/experience.dart';
import '../identity/identity.dart';
import '../shared/hana_home.dart';
import 'agent_manager.dart';
import 'preferences_manager.dart';

/// 经验网络后台守护进程。
///
/// 双轨运行：
/// 1. 中心化 DHT HTTP 链路（兜底）：定期 announce + 轮询需求 + 自动回包
/// 2. P2P gossip 覆盖网络（首选）：ExperienceP2pOverlay 管理邻居、传播需求、沿路回包
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
  ExperienceP2pOverlay? _overlay;

  static const _announceInterval = Duration(minutes: 5);
  static const _demandPollInterval = Duration(minutes: 2);
  static const _maxDhtResolveBackoff = Duration(minutes: 30);
  static const _uuid = Uuid();

  void start() {
    if (_running) return;
    _running = true;
    _announceTimer = Timer.periodic(_announceInterval, (_) {
      unawaited(_safeAnnounce());
    });
    _demandPollTimer = Timer.periodic(_demandPollInterval, (_) {
      unawaited(_safePollAndAnswer());
    });
    unawaited(_initOverlay());
    unawaited(_safeAnnounce());
  }

  Future<void> stop() async {
    _running = false;
    _announceTimer?.cancel();
    _demandPollTimer?.cancel();
    _announceTimer = null;
    _demandPollTimer = null;
    await _overlay?.stop();
    _overlay = null;
  }

  Future<void> _initOverlay() async {
    final identity = identityRepository.current;
    if (identity == null) return;
    final agentId = agentManager.activeAgentId;
    if (agentId == null) return;

    final agentDir = home.agentDir(agentId);
    final store = ExperienceStore(agentDir: agentDir);
    _managerClient ??= ExperienceNetworkManagerClient();

    final overlay = ExperienceP2pOverlay(
      localNodeId: identity.publicKeyHash,
      keyPair: identity.keyPair,
      store: store,
      managerClient: _managerClient!,
    );
    await overlay.start();
    _overlay = overlay;
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
    final packageHashes = await _collectLocalExperienceIds(store);

    await dhtClient.announcePresence(
      presence: ExperienceDhtPresence(
        peerId: identity.publicKeyHash,
        ownerPeerId: identity.publicKeyHash,
        packageHashes: packageHashes,
      ),
      keyPair: identity.keyPair,
    );
  }

  Future<List<String>> _collectLocalExperienceIds(ExperienceStore store) async {
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

  /// 中心化兜底：通过 DHT HTTP API 轮询需求并响应。
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

  /// Agent 工具调用入口：双轨发布需求。
  /// 1. P2P gossip 传播（如果 overlay 已就绪）
  /// 2. 中心化 DHT HTTP 兜底（总是尝试）
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

    final demandId = _uuid.v4();

    // 1. P2P gossip 传播
    final overlay = _overlay;
    if (overlay != null) {
      overlay.publishDemand(P2pDemandPacket(
        demandId: demandId,
        requesterPubKey: identity.keyPair.publicKeyHex,
        signature: '',
        query: query,
        tags: keywords,
        maxResponses: 3,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }

    // 2. 中心化 DHT HTTP 兜底
    final dhtClient = await _resolveDhtClient();
    if (dhtClient == null && overlay == null) {
      return {'ok': false, 'error': '无法连接 DHT 节点且 P2P 覆盖网络未就绪'};
    }

    if (dhtClient != null) {
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
        'p2p_demand_id': demandId,
        'p2p_neighbors': overlay?.neighborTable.size ?? 0,
        'offers_count': result.offers.length,
        'imported': importOk,
        if (importOk && result.importResult.experienceId != null)
          'experience_id': result.importResult.experienceId,
        if (!importOk) 'import_message': result.importResult.message,
      };
    }

    return {
      'ok': true,
      'demand_id': demandId,
      'p2p_only': true,
      'p2p_neighbors': overlay?.neighborTable.size ?? 0,
      'message': '需求已通过 P2P 网络广播，等待邻居响应',
    };
  }
}
