import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../identity/keypair.dart';
import 'experience_network.dart';
import 'experience_store.dart';
import 'neighbor_table.dart';
import 'p2p_message.dart';
import 'p2p_transport.dart';

class ExperienceP2pOverlay {
  ExperienceP2pOverlay({
    required this.localNodeId,
    required this.keyPair,
    required this.store,
    required this.managerClient,
    int bindPort = 0,
  }) : transport = P2pTransport(bindPort: bindPort),
       neighborTable = NeighborTable(localNodeId: localNodeId);

  final String localNodeId;
  final HanakoKeyPair keyPair;
  final ExperienceStore store;
  final ExperienceNetworkManagerClient managerClient;
  final P2pTransport transport;
  final NeighborTable neighborTable;

  final Set<String> _seenDemandIds = {};
  final Map<String, Set<String>> _demandResponseSets = {};
  final Map<String, int> _demandMaxResponses = {};
  Timer? _maintenanceTimer;
  bool _running = false;

  static const _maintenanceInterval = Duration(minutes: 5);
  static const _demandExpiryDuration = Duration(hours: 24);

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await transport.start();
    transport.onMessage = _onMessage;
    _maintenanceTimer = Timer.periodic(_maintenanceInterval, (_) {
      unawaited(_maintenance());
    });
    unawaited(_maintenance());
  }

  Future<void> stop() async {
    _running = false;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    await transport.stop();
  }

  /// Agent 发起需求 → gossip 传播到所有邻居。
  void publishDemand(P2pDemandPacket demand) {
    _seenDemandIds.add(demand.demandId);
    _demandMaxResponses[demand.demandId] = demand.maxResponses;
    _demandResponseSets[demand.demandId] = {};
    _broadcastToNeighbors(P2pEnvelope(
      type: P2pMessageType.demand,
      payload: demand.toJson(),
    ));
  }

  void _onMessage(P2pEnvelope envelope, InternetAddress sender, int senderPort) {
    switch (envelope.type) {
      case P2pMessageType.demand:
        _handleDemand(envelope.payload, sender, senderPort);
      case P2pMessageType.response:
        _handleResponse(envelope.payload, sender, senderPort);
      case P2pMessageType.offerAnnounce:
        _handleOfferAnnounce(envelope.payload, sender, senderPort);
      case P2pMessageType.probe:
        _handleProbe(envelope.payload, sender, senderPort);
      case P2pMessageType.probeAck:
        break; // handled by transport.probe()
      case P2pMessageType.packageData:
        _handlePackageData(envelope.payload, sender, senderPort);
    }
  }

  void _handleDemand(Map<String, dynamic> payload, InternetAddress sender, int senderPort) {
    final demand = P2pDemandPacket.fromJson(payload);
    if (demand == null) return;

    // demandId 去重
    if (_seenDemandIds.contains(demand.demandId)) return;
    _seenDemandIds.add(demand.demandId);
    _demandMaxResponses[demand.demandId] = demand.maxResponses;
    _demandResponseSets.putIfAbsent(demand.demandId, () => {});

    // 追加自己到 forwardPath
    demand.forwardPath.add(P2pPathEntry(
      nodeId: localNodeId,
      host: transport.localAddress?.address ?? '',
      port: transport.localPort ?? 0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));

    // 转发给邻居（排除来源）
    _broadcastToNeighbors(
      P2pEnvelope(type: P2pMessageType.demand, payload: demand.toJson()),
      excludeHost: sender.address,
      excludePort: senderPort,
    );

    // 检查本地是否有匹配经验
    unawaited(_tryLocalMatch(demand));
  }

  Future<void> _tryLocalMatch(P2pDemandPacket demand) async {
    try {
      final results = await store.search(demand.query, maxResults: 3);
      if (results.isEmpty) return;

      final fingerprints = <P2pPackageFingerprint>[];
      for (final result in results) {
        fingerprints.add(P2pPackageFingerprint(
          packageHash: result.experienceId,
          sizeBytes: 0,
          title: result.title ?? '',
        ));
      }

      // 沿 forwardPath 逆向回包
      final response = P2pResponsePacket(
        demandId: demand.demandId,
        providerPubKey: keyPair.publicKeyHex,
        providerSig: '',
        fingerprints: fingerprints,
      );

      _sendResponseAlongPath(response, demand.forwardPath);

      // 同时广播 OfferAnnounce
      final announce = P2pOfferAnnounce(
        demandId: demand.demandId,
        providedPackageHashes: fingerprints.map((f) => f.packageHash).toList(),
        providerPubKey: keyPair.publicKeyHex,
        providerSig: '',
      );
      _broadcastToNeighbors(P2pEnvelope(
        type: P2pMessageType.offerAnnounce,
        payload: announce.toJson(),
      ));
    } catch (_) {}
  }

  void _sendResponseAlongPath(P2pResponsePacket response, List<P2pPathEntry> forwardPath) {
    if (forwardPath.isEmpty) return;
    // 逆序：最后一个是离 provider 最近的，第一个是离 requester 最近的
    final nextHop = forwardPath.last;
    response.returnPath.add(P2pPathEntry(
      nodeId: localNodeId,
      host: transport.localAddress?.address ?? '',
      port: transport.localPort ?? 0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
    transport.sendTo(
      P2pEnvelope(type: P2pMessageType.response, payload: response.toJson()),
      nextHop.host,
      nextHop.port,
    );
  }

  void _handleResponse(Map<String, dynamic> payload, InternetAddress sender, int senderPort) {
    final response = P2pResponsePacket.fromJson(payload);
    if (response == null) return;

    // 去重检查
    final responseSet = _demandResponseSets[response.demandId];
    if (responseSet != null) {
      for (final fp in response.fingerprints) {
        if (responseSet.contains(fp.packageHash)) return; // 重复
        responseSet.add(fp.packageHash);
      }
    }

    // 转发即持有：如果回包带完整包数据，缓存到本地经验库
    if (response.packageData != null && response.packageData!.isNotEmpty) {
      unawaited(_cachePackageLocally(response.packageData!));
    }

    // 如果我是 requester（forwardPath 的第一个），导入包
    if (_seenDemandIds.contains(response.demandId)) {
      if (response.packageData != null && response.packageData!.isNotEmpty) {
        unawaited(_importReceivedPackage(response.packageData!));
      }
    }

    // 继续沿 forwardPath 回传（找到"自己"在路径中的位置，向前一跳发）
    _relayResponseToNextHop(response);
  }

  void _relayResponseToNextHop(P2pResponsePacket response) {
    // 找到 forwardPath 中最近一个不是自己的条目
    // response 从 provider → requester 方向传播
    // forwardPath 是正向的（requester → provider），所以回传是逆序
    // returnPath 记录了已经走过的节点
    final visited = {
      localNodeId,
      ...response.returnPath.map((e) => e.nodeId),
    };
    // 在 demand 的 forwardPath 中，我们没有直接引用。
    // 但 response 来自某个方向，我们需要继续向 requester 方向传。
    // 简化策略：转发给所有可达邻居中未在 returnPath 里的。
    response.returnPath.add(P2pPathEntry(
      nodeId: localNodeId,
      host: transport.localAddress?.address ?? '',
      port: transport.localPort ?? 0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
    for (final n in neighborTable.reachable) {
      if (visited.contains(n.nodeId)) continue;
      transport.sendTo(
        P2pEnvelope(type: P2pMessageType.response, payload: response.toJson()),
        n.host,
        n.port,
      );
      break; // 只发给一个（最优邻居），不广播回包
    }
  }

  void _handleOfferAnnounce(Map<String, dynamic> payload, InternetAddress sender, int senderPort) {
    final announce = P2pOfferAnnounce.fromJson(payload);
    if (announce == null) return;

    final responseSet =
        _demandResponseSets.putIfAbsent(announce.demandId, () => {});
    var newHashes = false;
    for (final hash in announce.providedPackageHashes) {
      if (responseSet.add(hash)) newHashes = true;
    }

    // maxResponses 熔断
    final max = _demandMaxResponses[announce.demandId];
    if (max != null && responseSet.length >= max) return;

    // 有新 hash 才继续传播
    if (!newHashes) return;
    _broadcastToNeighbors(
      P2pEnvelope(type: P2pMessageType.offerAnnounce, payload: announce.toJson()),
      excludeHost: sender.address,
      excludePort: senderPort,
    );
  }

  void _handleProbe(Map<String, dynamic> payload, InternetAddress sender, int senderPort) {
    transport.send(
      P2pEnvelope(type: P2pMessageType.probeAck, payload: payload),
      sender,
      senderPort,
    );
  }

  void _handlePackageData(Map<String, dynamic> payload, InternetAddress sender, int senderPort) {
    final dataStr = payload['data'];
    if (dataStr is! String || dataStr.isEmpty) return;
    try {
      final bytes = Uint8List.fromList(dataStr.codeUnits);
      unawaited(_cachePackageLocally(bytes));
    } catch (_) {}
  }

  Future<void> _cachePackageLocally(Uint8List bytes) async {
    try {
      await store.importNetworkPackage(bytes);
    } catch (_) {}
  }

  Future<void> _importReceivedPackage(Uint8List bytes) async {
    try {
      await store.importNetworkPackage(bytes);
    } catch (_) {}
  }

  void _broadcastToNeighbors(
    P2pEnvelope envelope, {
    String? excludeHost,
    int? excludePort,
  }) {
    for (final n in neighborTable.reachable) {
      if (n.host == excludeHost && n.port == excludePort) continue;
      transport.sendTo(envelope, n.host, n.port);
    }
  }

  Future<void> _maintenance() async {
    _cleanupExpiredDemands();
    await neighborTable.probeExisting(transport);
    await neighborTable.discoverAndProbe(
      managerClient: managerClient,
      transport: transport,
    );
  }

  void _cleanupExpiredDemands() {
    final cutoff = DateTime.now()
        .subtract(_demandExpiryDuration)
        .millisecondsSinceEpoch;
    _seenDemandIds.removeWhere((id) {
      // 简化：无法从 ID 获取时间戳，直接按容量清理
      return false;
    });
    // 容量清理：超过 10000 条去重记录时清理最早一半
    if (_seenDemandIds.length > 10000) {
      final toRemove = _seenDemandIds.take(_seenDemandIds.length ~/ 2).toList();
      for (final id in toRemove) {
        _seenDemandIds.remove(id);
        _demandResponseSets.remove(id);
        _demandMaxResponses.remove(id);
      }
    }
  }
}
