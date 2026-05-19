import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../identity/keypair.dart';
import 'experience_network.dart';
import 'experience_review.dart';
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
    required this.dhtNodeId,
    this.trustAnchor,
    int bindPort = 0,
  }) : transport = P2pTransport(bindPort: bindPort),
       neighborTable = NeighborTable(localNodeId: localNodeId);

  final String localNodeId;
  final HanakoKeyPair keyPair;
  final ExperienceStore store;
  final ExperienceDhtHttpClient dhtClient;
  final String dhtNodeId;
  final ExperienceReviewTrustAnchor? trustAnchor;
  final P2pTransport transport;
  final NeighborTable neighborTable;

  final Set<String> _seenDemandIds = {};
  final Map<String, List<P2pPathEntry>> _demandForwardPaths = {};
  final Map<String, Set<String>> _demandResponseSets = {};
  final Map<String, int> _demandMaxResponses = {};
  final Map<String, P2pPathEntry> _observedRoutes = {};

  /// chunk 重组器：接收 UDP 分片数据。
  final P2pChunkAssembler _assembler = P2pChunkAssembler();

  /// 本地持有的包字节缓存（packageHash → hxpBytes），用于中间节点转发。
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
    demand.forwardPath.add(_localPathEntry());
    _seenDemandIds.add(demand.demandId);
    _demandMaxResponses[demand.demandId] = demand.maxResponses;
    _demandResponseSets[demand.demandId] = {};
    _demandForwardPaths[demand.demandId] = List.from(demand.forwardPath);
    _broadcastToNeighbors(
      P2pEnvelope(type: P2pMessageType.demand, payload: demand.toJson()),
    );
  }

  // ---- message dispatch ----

  void _onMessage(
    P2pEnvelope envelope,
    InternetAddress sender,
    int senderPort,
  ) {
    switch (envelope.type) {
      case P2pMessageType.demand:
        _handleDemand(envelope.payload, sender, senderPort);
      case P2pMessageType.response:
        _handleResponse(envelope.payload, sender, senderPort);
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

  void _handleDemand(
    Map<String, dynamic> payload,
    InternetAddress sender,
    int senderPort,
  ) {
    final demand = P2pDemandPacket.fromJson(payload);
    if (demand == null) return;
    if (!demand.verifySignature()) return;

    _correctPreviousHop(demand.forwardPath, sender, senderPort);

    if (_seenDemandIds.contains(demand.demandId)) return;
    _seenDemandIds.add(demand.demandId);
    _demandMaxResponses[demand.demandId] = demand.maxResponses;
    _demandResponseSets.putIfAbsent(demand.demandId, () => {});

    demand.forwardPath.add(_localPathEntry());

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
          trustAnchor: trustAnchor,
        );
        if (package == null) continue;
        fingerprints.add(
          P2pPackageFingerprint(
            packageHash: package.packageHash,
            sizeBytes: package.hxpBytes.length,
            title: result.title,
          ),
        );
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
        P2pEnvelope(
          type: P2pMessageType.offerAnnounce,
          payload: announce.toJson(),
        ),
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
    response.returnPath.add(_localPathEntry());
    _sendToPathEntry(
      P2pEnvelope(type: P2pMessageType.response, payload: response.toJson()),
      nextHop,
    );
  }

  /// requester 收到 fingerprint 后，向 provider 发送 PackageTransferRequest，
  /// provider 用 UDP 分片把完整包沿 forwardPath 正向传回。
  Future<void> _requestChunkedTransfer(P2pResponsePacket response) async {
    final path = response.forwardPath;
    if (path.length < 2 || path.first.nodeId != localNodeId) return;

    for (final fp in response.fingerprints) {
      final transferId = _uuid.v4();
      _assembler.expect(
        transferId,
        onComplete: (data, hash) {
          unawaited(
            _importTransferredPackage(data, hash, awardFlowerFor: response),
          );
        },
      );

      // 请求只能沿 demand 的传播路径逐跳前进，不能直连 provider。
      _sendToPathEntry(
        P2pEnvelope(
          type: P2pMessageType.packageData,
          payload: {
            'action': 'request',
            'transferId': transferId,
            'packageHash': fp.packageHash,
            'path': path.map((entry) => entry.toJson()).toList(),
          },
        ),
        path[1],
      );
    }
  }

  void _handleResponse(
    Map<String, dynamic> payload,
    InternetAddress sender,
    int senderPort,
  ) {
    final response = P2pResponsePacket.fromJson(payload);
    if (response == null) return;
    if (!response.verifySignature()) return;

    final responseSet = _demandResponseSets[response.demandId];
    if (responseSet != null) {
      for (final fp in response.fingerprints) {
        responseSet.add(fp.packageHash);
      }
    }

    if (response.forwardPath.isEmpty) {
      final stored = _demandForwardPaths[response.demandId];
      if (stored != null) {
        response.forwardPath.addAll(stored);
      }
    }

    final myIdx = _pathIndex(response.forwardPath);
    if (myIdx >= 0 && myIdx + 1 < response.forwardPath.length) {
      _rememberRoute(
        response.forwardPath[myIdx + 1].nodeId,
        sender,
        senderPort,
      );
    } else if (response.forwardPath.isNotEmpty) {
      _rememberRoute(response.forwardPath.last.nodeId, sender, senderPort);
    }

    _routeResponseBackward(response);
  }

  // ---- UDP 分片数据处理 ----

  void _handlePackageData(
    Map<String, dynamic> payload,
    InternetAddress sender,
    int senderPort,
  ) {
    final action = payload['action'] as String?;

    if (action == 'request') {
      final packageHash = payload['packageHash'] as String?;
      final transferId = payload['transferId'] as String?;
      final path = _pathFromJson(payload['path']);
      final myIdx = _pathIndex(path);
      if (packageHash == null || transferId == null || myIdx < 0) return;
      if (myIdx > 0) {
        _rememberRoute(path[myIdx - 1].nodeId, sender, senderPort);
      }

      final bytes = _localPackageCache[packageHash];
      if (bytes != null && myIdx > 0) {
        final chunks = P2pChunkedTransfer.split(
          transferId,
          bytes,
          packageHash: packageHash,
          path: path,
        );
        final previousHop = path[myIdx - 1];
        unawaited(_sendChunksToPathEntry(chunks, previousHop));
        return;
      }

      if (myIdx + 1 >= path.length) return;
      if (myIdx > 0 && !_assembler.hasExpected(transferId)) {
        _assembler.expect(
          transferId,
          onComplete: (data, hash) {
            unawaited(_importTransferredPackage(data, hash));
          },
        );
      }
      _sendToPathEntry(
        P2pEnvelope(type: P2pMessageType.packageData, payload: payload),
        path[myIdx + 1],
      );
      return;
    }

    // 收到分片数据。
    final chunk = P2pChunk.fromJson(payload);
    if (chunk == null) return;
    final myIdx = _pathIndex(chunk.path);
    if (myIdx < 0) return;
    if (!_assembler.hasExpected(chunk.transferId)) return;
    if (myIdx + 1 < chunk.path.length) {
      _rememberRoute(chunk.path[myIdx + 1].nodeId, sender, senderPort);
    }

    if (myIdx > 0) {
      _sendToPathEntry(
        P2pEnvelope(type: P2pMessageType.packageData, payload: chunk.toJson()),
        chunk.path[myIdx - 1],
      );
    }

    _assembler.receive(chunk);
  }

  // ---- offer announce (§5) ----

  void _handleOfferAnnounce(
    Map<String, dynamic> payload,
    InternetAddress sender,
    int senderPort,
  ) {
    final announce = P2pOfferAnnounce.fromJson(payload);
    if (announce == null) return;
    if (!announce.verifySignature()) return;

    final responseSet = _demandResponseSets.putIfAbsent(
      announce.demandId,
      () => {},
    );
    var newHashes = false;
    for (final hash in announce.providedPackageHashes) {
      if (responseSet.add(hash)) newHashes = true;
    }

    final max = _demandMaxResponses[announce.demandId];
    if (max != null && responseSet.length >= max) return;

    if (!newHashes) return;
    _broadcastToNeighbors(
      P2pEnvelope(
        type: P2pMessageType.offerAnnounce,
        payload: announce.toJson(),
      ),
      excludeHost: sender.address,
      excludePort: senderPort,
    );
  }

  // ---- 小红花发放 ----

  Future<void> _awardFlowers(
    P2pResponsePacket response,
    String packageHash,
  ) async {
    try {
      if (dhtNodeId.trim().isEmpty) return;
      final now = DateTime.now().toUtc().toIso8601String();
      final flower = DHTServiceFlower(
        flowerId: _uuid.v4(),
        nodeId: dhtNodeId,
        clientPubkeyHex: keyPair.publicKeyHex,
        clientPubkeyHash: keyPair.publicKeyHash,
        resourceHash: packageHash,
        workKind: 'p2p_rendezvous',
        servedAt: now,
      ).signedWith(keyPair);
      await dhtClient.submitFlower(flower: flower, keyPair: keyPair);
    } catch (_) {}
  }

  Future<void> _importTransferredPackage(
    Uint8List data,
    String packageHash, {
    P2pResponsePacket? awardFlowerFor,
  }) async {
    final result = await store.importNetworkPackage(
      data,
      trustAnchor: trustAnchor,
      expectedPackageHash: packageHash,
    );
    if (!result.ok) return;
    _localPackageCache[packageHash] = data;
    if (awardFlowerFor != null) {
      await _awardFlowers(awardFlowerFor, packageHash);
    }
  }

  P2pPathEntry _localPathEntry() {
    return P2pPathEntry(
      nodeId: localNodeId,
      host: transport.advertisedHost ?? transport.localAddress?.address ?? '',
      port: transport.localPort ?? 0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _correctPreviousHop(
    List<P2pPathEntry> path,
    InternetAddress sender,
    int senderPort,
  ) {
    if (path.isEmpty) return;
    final previous = path.last;
    final observed = P2pPathEntry(
      nodeId: previous.nodeId,
      host: sender.address,
      port: senderPort,
      timestamp: previous.timestamp,
    );
    path[path.length - 1] = observed;
    _observedRoutes[previous.nodeId] = observed;
  }

  void _rememberRoute(String nodeId, InternetAddress sender, int senderPort) {
    if (nodeId.trim().isEmpty) return;
    _observedRoutes[nodeId] = P2pPathEntry(
      nodeId: nodeId,
      host: sender.address,
      port: senderPort,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  int _pathIndex(List<P2pPathEntry> path) {
    for (var i = 0; i < path.length; i++) {
      if (path[i].nodeId == localNodeId) return i;
    }
    return -1;
  }

  List<P2pPathEntry> _pathFromJson(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map(P2pPathEntry.fromJson)
        .whereType<P2pPathEntry>()
        .toList(growable: false);
  }

  P2pPathEntry _routeFor(P2pPathEntry entry) {
    final observed = _observedRoutes[entry.nodeId];
    if (observed != null && _isUsableEndpoint(observed.host, observed.port)) {
      return observed;
    }
    return entry;
  }

  bool _isUsableEndpoint(String host, int port) {
    final normalized = host.trim();
    return normalized.isNotEmpty &&
        normalized != '0.0.0.0' &&
        normalized != '::' &&
        port > 0;
  }

  void _sendToPathEntry(P2pEnvelope envelope, P2pPathEntry entry) {
    final route = _routeFor(entry);
    if (!_isUsableEndpoint(route.host, route.port)) return;
    transport.sendTo(envelope, route.host, route.port);
  }

  Future<void> _sendChunksToPathEntry(
    List<P2pChunk> chunks,
    P2pPathEntry entry,
  ) async {
    final route = _routeFor(entry);
    if (!_isUsableEndpoint(route.host, route.port)) return;
    await P2pChunkedTransfer.sendAll(transport, chunks, route.host, route.port);
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
