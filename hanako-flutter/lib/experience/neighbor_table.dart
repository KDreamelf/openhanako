import 'dart:async';
import 'dart:math';

import 'experience_network.dart';
import 'p2p_transport.dart';

class Neighbor {
  Neighbor({
    required this.nodeId,
    required this.host,
    required this.port,
    this.rttMs,
    this.region,
    DateTime? lastSeen,
    this.consecutiveFailures = 0,
  }) : lastSeen = lastSeen ?? DateTime.now();

  final String nodeId;
  final String host;
  final int port;
  int? rttMs;
  String? region;
  DateTime lastSeen;
  int consecutiveFailures;

  bool get isReachable => consecutiveFailures < 3;
}

class NeighborTable {
  NeighborTable({
    this.maxNeighbors = 100,
    required this.localNodeId,
  });

  final int maxNeighbors;
  final String localNodeId;
  final Map<String, Neighbor> _neighbors = {};

  List<Neighbor> get reachable =>
      _neighbors.values.where((n) => n.isReachable).toList();

  List<Neighbor> get all => _neighbors.values.toList();

  int get size => _neighbors.length;

  Neighbor? get(String nodeId) => _neighbors[nodeId];

  void addOrUpdate(Neighbor neighbor) {
    if (neighbor.nodeId == localNodeId) return;
    final existing = _neighbors[neighbor.nodeId];
    if (existing != null) {
      existing
        ..rttMs = neighbor.rttMs ?? existing.rttMs
        ..lastSeen = neighbor.lastSeen
        ..consecutiveFailures = neighbor.consecutiveFailures
        ..region = neighbor.region ?? existing.region;
      return;
    }
    if (_neighbors.length >= maxNeighbors) {
      if (!shouldReplace(neighbor)) return;
      _evictWorst();
    }
    _neighbors[neighbor.nodeId] = neighbor;
  }

  void markFailed(String nodeId) {
    final n = _neighbors[nodeId];
    if (n == null) return;
    n.consecutiveFailures++;
    if (n.consecutiveFailures >= 3) {
      _neighbors.remove(nodeId);
    }
  }

  void markSuccess(String nodeId, {int? rttMs}) {
    final n = _neighbors[nodeId];
    if (n == null) return;
    n.consecutiveFailures = 0;
    n.lastSeen = DateTime.now();
    if (rttMs != null) n.rttMs = rttMs;
  }

  bool shouldReplace(Neighbor candidate) {
    if (_neighbors.length < maxNeighbors) return true;
    if (candidate.rttMs == null) return false;
    final worst = _worstNeighbor();
    if (worst == null) return false;
    if (worst.rttMs == null) return true;
    return candidate.rttMs! < worst.rttMs!;
  }

  void _evictWorst() {
    final worst = _worstNeighbor();
    if (worst != null) _neighbors.remove(worst.nodeId);
  }

  Neighbor? _worstNeighbor() {
    if (_neighbors.isEmpty) return null;
    Neighbor? worst;
    for (final n in _neighbors.values) {
      if (worst == null) {
        worst = n;
        continue;
      }
      if (!n.isReachable && worst.isReachable) {
        worst = n;
        continue;
      }
      if (n.rttMs == null && worst.rttMs != null) {
        worst = n;
        continue;
      }
      if (n.rttMs != null && worst.rttMs != null && n.rttMs! > worst.rttMs!) {
        worst = n;
      }
    }
    return worst;
  }

  /// 通过 DHT 获取已 announce 的客户端节点列表，对其 UDP 端点做延迟探测，
  /// 按 RTT 排名择优加入邻居表。
  Future<void> discoverAndProbe({
    required ExperienceDhtHttpClient dhtClient,
    required P2pTransport transport,
  }) async {
    List<ExperienceDhtProviderRecord> peers;
    try {
      peers = await dhtClient.fetchActivePeers();
    } catch (_) {
      return;
    }

    final candidates = <_ProbeCandidate>[];
    for (final peer in peers) {
      if (peer.peerId == localNodeId) continue;
      if (_neighbors.containsKey(peer.peerId)) continue;
      for (final ep in peer.endpoints) {
        if (!ep.isValid) continue;
        if (ep.isUdpCandidate) {
          candidates.add(_ProbeCandidate(
            nodeId: peer.peerId,
            host: ep.host,
            port: ep.port,
          ));
          break;
        }
      }
    }

    candidates.shuffle(Random());
    final toProbe = candidates.take(20).toList();

    for (final c in toProbe) {
      final rtt = await transport.probe(c.host, c.port);
      if (rtt == null) continue;
      final neighbor = Neighbor(
        nodeId: c.nodeId,
        host: c.host,
        port: c.port,
        rttMs: rtt.inMilliseconds,
      );
      addOrUpdate(neighbor);
    }
  }

  Future<void> probeExisting(P2pTransport transport) async {
    for (final n in _neighbors.values.toList()) {
      final rtt = await transport.probe(n.host, n.port);
      if (rtt == null) {
        markFailed(n.nodeId);
      } else {
        markSuccess(n.nodeId, rttMs: rtt.inMilliseconds);
      }
    }
  }
}

class _ProbeCandidate {
  const _ProbeCandidate({
    required this.nodeId,
    required this.host,
    required this.port,
  });

  final String nodeId;
  final String host;
  final int port;
}
