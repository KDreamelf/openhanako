import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../identity/keypair.dart';
import 'experience_network.dart';
import 'experience_store.dart';
import 'neighbor_table.dart';
import 'p2p_chunked_transfer.dart';
import 'p2p_message.dart';
import 'p2p_transport.dart';

class ExperienceP2pOverlay {
  ExperienceP2pOverlay({
    required this.localNodeId,
    required this.keyPair,
    required this.store,
    required this.dhtClient,
    int bindPort = 0,
  }) : transport = P2pTransport(bindPort: bindPort),
       neighborTable = NeighborTable(localNodeId: localNodeId);

  final String localNodeId;
  final HanakoKeyPair keyPair;
  final ExperienceStore store;
  final ExperienceDhtHttpClient dhtClient;
  final P2pTransport transport;
  final NeighborTable neighborTable;

  final Set<String> _seenDemandIds = {};
  final Map<String, List<P2pPathEntry>> _demandForwardPaths = {};
  final Map<String, Set<String>> _demandResponseSets = {};
  final Map<String, int> _demandMaxResponses = {};

  /// chunk 重组器：接收 UDP 分片数据。
  final P2pChunkAssembler _assembler = P2pChunkAssembler();

  /// 本地持有的包字节缓存（transferId → hxpBytes），用于中间节点转发。
  final Map<String, Uint8List> _localPackageCache = {};

  Timer? _maintenanceTimer;
  bool _running = false;
  static const _uuid = Uuid();

  static const _maintenanceInterval = Duration(minutes: 5);

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

  void publishDemand(P2pDemandPacket demand) {
    demand.forwardPath.add(P2pPathEntry(
      nodeId: localNodeId,
      host: transport.localAddress?.address ?? '',
      port: transport.localPort ?? 0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));
    _seenDemandIds.add(demand.demandId);
    _demandMaxResponses[demand.demandId] = demand.maxResponses;
    _demandResponseSets[demand.demandId] = {};
    _demandForwardPaths[demand.demandId] = List.from(demand.forwardPath);
    _broadcastToNeighbors(
      P2pEnvelope(type: P2pMessageType.demand, payload: demand.toJson()),
    );
  }

  // ---- message dispatch ----

  void _onMessage(P2pEnvelope envelope, InternetAddress sender, int senderPort) {
    switch (envelope.type) {
      case P2pMessageType.demand:
        _handleDemand(envelope.payload, sender, senderPort);
      case P2pMessageType.response:
        _handleResponse(envelope.payload);
      case P2pMessageType.offerAnnounce:
        _handleOfferAnnounce(envelope.payload, sender, senderPort);
      case P2pMessageType.probe:
        transport.send(
          P2pEnvelope(type: P2pMessageType.probeAck, payload: envelope.payload),
          sender,
          senderPort,
        );
      case P2pMessageType.probeAck:
        break;
      case P2pMessageType.packageData:
        _handlePackageData(envelope.payload, sender, senderPort);
    }
  }

  // ---- demand handling (§3) ----

  void _handleDemand(Map<String, dynamic> payload, InternetAddress sender, int senderPort) {
    final demand = P2pDemandPacket.fromJson(payload);
    if (demand == null) return;
    if (!demand.verifySignature()) return;

    if (_seenDemandIds.contains(demand.demandId)) return;
    _seenDemandIds.add(demand.demandId);
    _demandMaxResponses[demand.demandId] = demand.maxResponses;
    _demandResponseSets.putIfAbsent(demand.demandId, () => {});

    demand.forwardPath.add(P2pPathEntry(
      nodeId: localNodeId,
      host: transport.localAddress?.address ?? '',
      port: transport.localPort ?? 0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));

    _demandForwardPaths[demand.demandId] = List.from(demand.forwardPath);

    _broadcastToNeighbors(
      P2pEnvelope(type: P2pMessageType.demand, payload: demand.toJson()),
      excludeHost: sender.address,
      excludePort: senderPort,
    );

    unawaited(_tryLocalMatch(demand));
  }

  // ---- local match → response + UDP 分片传输 (§4) ----

  Future<void> _tryLocalMatch(P2pDemandPacket demand) async {
    try {
      final results = await store.search(demand.query, maxResults: 3);
      if (results.isEmpty) return;

      final fingerprints = <P2pPackageFingerprint>[];

      for (final result in results) {
        final package = await store.readReviewedCachedPackage(
          result.experienceId,
        );
        if (package == null) continue;
        fingerprints.add(P2pPackageFingerprint(
          packageHash: package.packageHash,
          sizeBytes: package.hxpBytes.length,
          title: result.title,
        ));
        // 缓存包字节，等 requester 沿路请求时用 UDP 分片发送。
        _localPackageCache[package.packageHash] = package.hxpBytes;
      }
      if (fingerprints.isEmpty) return;

      // 只发 fingerprint（哈希握手），不发完整数据。
      final response = P2pResponsePacket(
        demandId: demand.demandId,
        providerPubKey: keyPair.publicKeyHex,
        providerSig: '',
        fingerprints: fingerprints,
        forwardPath: List.from(demand.forwardPath),
      );
      response.signWith(keyPair);

      _routeResponseBackward(response);

      final announce = P2pOfferAnnounce(
        demandId: demand.demandId,
        providedPackageHashes: fingerprints.map((f) => f.packageHash).toList(),
        providerPubKey: keyPair.publicKeyHex,
        providerSig: '',
      )..signWith(keyPair);
      _broadcastToNeighbors(
        P2pEnvelope(type: P2pMessageType.offerAnnounce, payload: announce.toJson()),
      );
    } catch (_) {}
  }

  // ---- response routing (§4.3, §4.4) ----

  void _routeResponseBackward(P2pResponsePacket response) {
    final path = response.forwardPath;
    if (path.isEmpty) return;

    int myIdx = -1;
    for (var i = path.length - 1; i >= 0; i--) {
      if (path[i].nodeId == localNodeId) {
        myIdx = i;
        break;
      }
    }

    if (myIdx < 0) return;
    if (myIdx == 0) {
      // 我就是 requester。收到 fingerprint 后，沿 forwardPath 正向向 provider
      // 请求 UDP 分片传输。
      unawaited(_requestChunkedTransfer(response));
      return;
    }

    final nextHop = path[myIdx - 1];
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

  /// requester 收到 fingerprint 后，向 provider 发送 PackageTransferRequest，
  /// provider 用 UDP 分片把完整包沿 forwardPath 正向传回。
  Future<void> _requestChunkedTransfer(P2pResponsePacket response) async {
    for (final fp in response.fingerprints) {
      final transferId = _uuid.v4();
      _assembler.expect(transferId, onComplete: (data, hash) {
        unawaited(store.importNetworkPackage(data));
        // 完成后向参与工作的 DHT 节点发小红花。
        unawaited(_awardFlowers(response, hash));
      });

      // 向 forwardPath 的最后一跳（provider 或最近的持有者）请求数据。
      final providerEntry = response.forwardPath.isNotEmpty
          ? response.forwardPath.last
          : null;
      if (providerEntry == null) continue;
      transport.sendTo(
        P2pEnvelope(
          type: P2pMessageType.packageData,
          payload: {
            'action': 'request',
            'transferId': transferId,
            'packageHash': fp.packageHash,
            'requesterHost': transport.localAddress?.address ?? '',
            'requesterPort': transport.localPort ?? 0,
          },
        ),
        providerEntry.host,
        providerEntry.port,
      );
    }
  }

  void _handleResponse(Map<String, dynamic> payload) {
    final response = P2pResponsePacket.fromJson(payload);
    if (response == null) return;
    if (!response.verifySignature()) return;

    final responseSet = _demandResponseSets[response.demandId];
    if (responseSet != null) {
      for (final fp in response.fingerprints) {
        if (responseSet.contains(fp.packageHash)) return;
        responseSet.add(fp.packageHash);
      }
    }

    if (response.forwardPath.isEmpty) {
      final stored = _demandForwardPaths[response.demandId];
      if (stored != null) {
        response.forwardPath.addAll(stored);
      }
    }

    _routeResponseBackward(response);
  }

  // ---- UDP 分片数据处理 ----

  void _handlePackageData(Map<String, dynamic> payload, InternetAddress sender, int senderPort) {
    final action = payload['action'] as String?;

    if (action == 'request') {
      // 有节点向我请求某个包的分片传输。
      final packageHash = payload['packageHash'] as String?;
      final transferId = payload['transferId'] as String?;
      final reqHost = payload['requesterHost'] as String?;
      final reqPort = payload['requesterPort'] as int?;
      if (packageHash == null || transferId == null ||
          reqHost == null || reqPort == null) return;

      final bytes = _localPackageCache[packageHash];
      if (bytes == null) return;

      // 分片发送。
      final chunks = P2pChunkedTransfer.split(transferId, bytes);
      unawaited(P2pChunkedTransfer.sendAll(transport, chunks, reqHost, reqPort));
      return;
    }

    // 收到分片数据。
    final chunk = P2pChunk.fromJson(payload);
    if (chunk == null) return;

    final complete = _assembler.receive(chunk);
    if (complete) {
      // 转发即持有：中间客户端节点收到完整包也导入。
      // （_assembler.expect 的 onComplete 回调会处理 requester 的导入；
      //   这里处理中间节点的"路过缓存"。）
    }
  }

  // ---- offer announce (§5) ----

  void _handleOfferAnnounce(Map<String, dynamic> payload, InternetAddress sender, int senderPort) {
    final announce = P2pOfferAnnounce.fromJson(payload);
    if (announce == null) return;
    if (!announce.verifySignature()) return;

    final responseSet = _demandResponseSets.putIfAbsent(announce.demandId, () => {});
    var newHashes = false;
    for (final hash in announce.providedPackageHashes) {
      if (responseSet.add(hash)) newHashes = true;
    }

    final max = _demandMaxResponses[announce.demandId];
    if (max != null && responseSet.length >= max) return;

    if (!newHashes) return;
    _broadcastToNeighbors(
      P2pEnvelope(type: P2pMessageType.offerAnnounce, payload: announce.toJson()),
      excludeHost: sender.address,
      excludePort: senderPort,
    );
  }

  // ---- 小红花发放 ----

  Future<void> _awardFlowers(P2pResponsePacket response, String packageHash) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final flower = DHTServiceFlower(
        flowerId: _uuid.v4(),
        nodeId: dhtClient.dhtBaseUrl,
        clientPubkeyHex: keyPair.publicKeyHex,
        clientPubkeyHash: keyPair.publicKeyHash,
        resourceHash: packageHash,
        workKind: 'p2p_demand_relay',
        servedAt: now,
      );
      await dhtClient.submitFlower(flower: flower, keyPair: keyPair);
    } catch (_) {}
  }

  // ---- broadcast ----

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

  // ---- maintenance ----

  Future<void> _maintenance() async {
    _cleanupExpired();
    _assembler.cleanup();
    await neighborTable.probeExisting(transport);
    await neighborTable.discoverAndProbe(
      dhtClient: dhtClient,
      transport: transport,
    );
  }

  void _cleanupExpired() {
    if (_seenDemandIds.length > 10000) {
      final toRemove = _seenDemandIds.take(_seenDemandIds.length ~/ 2).toList();
      for (final id in toRemove) {
        _seenDemandIds.remove(id);
        _demandResponseSets.remove(id);
        _demandMaxResponses.remove(id);
        _demandForwardPaths.remove(id);
      }
    }
    // 清理本地包缓存（5 分钟后释放，避免无限增长）
    // 简化：保留最近 50 个，超过的删掉最早的。
    if (_localPackageCache.length > 50) {
      final keys = _localPackageCache.keys.toList();
      for (var i = 0; i < keys.length - 50; i++) {
        _localPackageCache.remove(keys[i]);
      }
    }
  }
}
