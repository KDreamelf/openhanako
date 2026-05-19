import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

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

  /// demandId 去重表：见过的 demand 不再处理。
  final Set<String> _seenDemandIds = {};

  /// demandId → 该 demand 经过本节点时的 forwardPath 快照。
  /// 回包到达时用这个做反向路由。
  final Map<String, List<P2pPathEntry>> _demandForwardPaths = {};

  /// demandId → 已见到的回包 packageHash 集合（去重 + maxResponses 熔断）。
  final Map<String, Set<String>> _demandResponseSets = {};
  final Map<String, int> _demandMaxResponses = {};

  Timer? _maintenanceTimer;
  bool _running = false;

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

  /// 发起需求：requester 把自己加入 forwardPath，然后广播。
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
    _broadcastToNeighbors(P2pEnvelope(
      type: P2pMessageType.demand,
      payload: demand.toJson(),
    ));
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
        break;
    }
  }

  // ---- demand handling (§3) ----

  void _handleDemand(Map<String, dynamic> payload, InternetAddress sender, int senderPort) {
    final demand = P2pDemandPacket.fromJson(payload);
    if (demand == null) return;

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

    // 存储 forwardPath 快照——回包路由要用。
    _demandForwardPaths[demand.demandId] = List.from(demand.forwardPath);

    _broadcastToNeighbors(
      P2pEnvelope(type: P2pMessageType.demand, payload: demand.toJson()),
      excludeHost: sender.address,
      excludePort: senderPort,
    );

    unawaited(_tryLocalMatch(demand));
  }

  // ---- local match → response (§4.1) ----

  Future<void> _tryLocalMatch(P2pDemandPacket demand) async {
    try {
      final results = await store.search(demand.query, maxResults: 3);
      if (results.isEmpty) return;

      final fingerprints = <P2pPackageFingerprint>[];
      Uint8List? firstPackageData;

      for (final result in results) {
        fingerprints.add(P2pPackageFingerprint(
          packageHash: result.experienceId,
          sizeBytes: 0,
          title: result.title,
        ));
        if (firstPackageData == null) {
          firstPackageData = await _readCachedPackageBytes(result.experienceId);
        }
      }

      final response = P2pResponsePacket(
        demandId: demand.demandId,
        providerPubKey: keyPair.publicKeyHex,
        providerSig: '',
        fingerprints: fingerprints,
        packageData: firstPackageData,
        forwardPath: List.from(demand.forwardPath),
      );

      _routeResponseBackward(response);

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

  Future<Uint8List?> _readCachedPackageBytes(String experienceId) async {
    try {
      final cacheDir = Directory(p.join(store.rootDir.path, 'cache'));
      final hxpFile = File(p.join(cacheDir.path, '$experienceId.hxp'));
      if (await hxpFile.exists()) return hxpFile.readAsBytes();
      return null;
    } catch (_) {
      return null;
    }
  }

  // ---- response routing (§4.3, §4.4) ----

  /// 沿 forwardPath 反向路由 response。
  /// 从 forwardPath 中找到自己，发给前一跳。
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
      // 我就是 requester，直接导入包。
      if (response.packageData != null && response.packageData!.isNotEmpty) {
        unawaited(_importReceivedPackage(response.packageData!));
      }
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

  void _handleResponse(Map<String, dynamic> payload) {
    final response = P2pResponsePacket.fromJson(payload);
    if (response == null) return;

    final responseSet = _demandResponseSets[response.demandId];
    if (responseSet != null) {
      for (final fp in response.fingerprints) {
        if (responseSet.contains(fp.packageHash)) return;
        responseSet.add(fp.packageHash);
      }
    }

    // 转发即持有（§6.1）：回包经过本节点时，缓存完整包到本地经验库。
    if (response.packageData != null && response.packageData!.isNotEmpty) {
      unawaited(_cachePackageLocally(response.packageData!));
    }

    // 用存储的 forwardPath 或 response 自带的做反向路由。
    if (response.forwardPath.isEmpty) {
      final stored = _demandForwardPaths[response.demandId];
      if (stored != null) {
        response.forwardPath.addAll(stored);
      }
    }

    _routeResponseBackward(response);
  }

  // ---- offer announce (§5) ----

  void _handleOfferAnnounce(Map<String, dynamic> payload, InternetAddress sender, int senderPort) {
    final announce = P2pOfferAnnounce.fromJson(payload);
    if (announce == null) return;

    final responseSet =
        _demandResponseSets.putIfAbsent(announce.demandId, () => {});
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

  // ---- package import ----

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
  }
}
