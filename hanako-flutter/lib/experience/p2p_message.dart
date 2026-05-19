import 'dart:convert';
import 'dart:typed_data';

import 'experience_network.dart';

enum P2pMessageType {
  demand,
  response,
  offerAnnounce,
  packageData,
  probe,
  probeAck,
}

class P2pEnvelope {
  const P2pEnvelope({required this.type, required this.payload});

  final P2pMessageType type;
  final Map<String, dynamic> payload;

  static const _magic = 0x50483031; // "PH01"

  Uint8List encode() {
    final json = utf8.encode(jsonEncode(payload));
    final buf = ByteData(12 + json.length);
    buf.setUint32(0, _magic);
    buf.setUint32(4, type.index);
    buf.setUint32(8, json.length);
    final bytes = buf.buffer.asUint8List();
    bytes.setRange(12, 12 + json.length, json);
    return bytes;
  }

  static P2pEnvelope? decode(Uint8List data) {
    if (data.length < 12) return null;
    final view = ByteData.sublistView(data);
    if (view.getUint32(0) != _magic) return null;
    final typeIndex = view.getUint32(4);
    if (typeIndex >= P2pMessageType.values.length) return null;
    final payloadLen = view.getUint32(8);
    if (data.length < 12 + payloadLen) return null;
    try {
      final json = utf8.decode(data.sublist(12, 12 + payloadLen));
      final map = jsonDecode(json);
      if (map is! Map<String, dynamic>) return null;
      return P2pEnvelope(
        type: P2pMessageType.values[typeIndex],
        payload: map,
      );
    } catch (_) {
      return null;
    }
  }
}

class P2pPathEntry {
  const P2pPathEntry({
    required this.nodeId,
    required this.host,
    required this.port,
    required this.timestamp,
  });

  final String nodeId;
  final String host;
  final int port;
  final int timestamp;

  Map<String, dynamic> toJson() => {
    'nodeId': nodeId,
    'host': host,
    'port': port,
    'timestamp': timestamp,
  };

  static P2pPathEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final nodeId = raw['nodeId'];
    final host = raw['host'];
    final port = raw['port'];
    if (nodeId is! String || host is! String || port is! int) return null;
    return P2pPathEntry(
      nodeId: nodeId,
      host: host,
      port: port,
      timestamp: (raw['timestamp'] as int?) ?? 0,
    );
  }
}

class P2pDemandPacket {
  P2pDemandPacket({
    required this.demandId,
    required this.requesterPubKey,
    required this.signature,
    required this.query,
    this.tags = const [],
    this.maxResponses = 3,
    required this.createdAt,
    List<P2pPathEntry>? forwardPath,
  }) : forwardPath = forwardPath ?? [];

  final String demandId;
  final String requesterPubKey;
  final String signature;
  final String query;
  final List<String> tags;
  final int maxResponses;
  final int createdAt;
  final List<P2pPathEntry> forwardPath;

  Map<String, dynamic> toJson() => {
    'demandId': demandId,
    'requesterPubKey': requesterPubKey,
    'signature': signature,
    'query': query,
    'tags': tags,
    'maxResponses': maxResponses,
    'createdAt': createdAt,
    'forwardPath': forwardPath.map((e) => e.toJson()).toList(),
  };

  static P2pDemandPacket? fromJson(Map<String, dynamic> json) {
    final demandId = json['demandId'];
    final requesterPubKey = json['requesterPubKey'];
    final signature = json['signature'];
    final query = json['query'];
    if (demandId is! String ||
        requesterPubKey is! String ||
        signature is! String ||
        query is! String) {
      return null;
    }
    return P2pDemandPacket(
      demandId: demandId,
      requesterPubKey: requesterPubKey,
      signature: signature,
      query: query,
      tags: (json['tags'] as List?)?.cast<String>() ?? const [],
      maxResponses: (json['maxResponses'] as int?) ?? 3,
      createdAt: (json['createdAt'] as int?) ?? 0,
      forwardPath: (json['forwardPath'] as List?)
              ?.map(P2pPathEntry.fromJson)
              .whereType<P2pPathEntry>()
              .toList() ??
          const [],
    );
  }
}

class P2pPackageFingerprint {
  const P2pPackageFingerprint({
    required this.packageHash,
    required this.sizeBytes,
    this.title = '',
  });

  final String packageHash;
  final int sizeBytes;
  final String title;

  Map<String, dynamic> toJson() => {
    'packageHash': packageHash,
    'sizeBytes': sizeBytes,
    'title': title,
  };

  static P2pPackageFingerprint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final hash = raw['packageHash'];
    if (hash is! String) return null;
    return P2pPackageFingerprint(
      packageHash: hash,
      sizeBytes: (raw['sizeBytes'] as int?) ?? 0,
      title: (raw['title'] as String?) ?? '',
    );
  }
}

class P2pResponsePacket {
  P2pResponsePacket({
    required this.demandId,
    required this.providerPubKey,
    required this.providerSig,
    required this.fingerprints,
    List<P2pPathEntry>? returnPath,
    this.packageData,
  }) : returnPath = returnPath ?? [];

  final String demandId;
  final String providerPubKey;
  final String providerSig;
  final List<P2pPackageFingerprint> fingerprints;
  final List<P2pPathEntry> returnPath;
  final Uint8List? packageData;

  Map<String, dynamic> toJson() => {
    'demandId': demandId,
    'providerPubKey': providerPubKey,
    'providerSig': providerSig,
    'fingerprints': fingerprints.map((f) => f.toJson()).toList(),
    'returnPath': returnPath.map((e) => e.toJson()).toList(),
    if (packageData != null) 'packageData': base64Encode(packageData!),
  };

  static P2pResponsePacket? fromJson(Map<String, dynamic> json) {
    final demandId = json['demandId'];
    final providerPubKey = json['providerPubKey'];
    final providerSig = json['providerSig'];
    if (demandId is! String ||
        providerPubKey is! String ||
        providerSig is! String) {
      return null;
    }
    Uint8List? data;
    final rawData = json['packageData'];
    if (rawData is String && rawData.isNotEmpty) {
      try {
        data = base64Decode(rawData);
      } catch (_) {}
    }
    return P2pResponsePacket(
      demandId: demandId,
      providerPubKey: providerPubKey,
      providerSig: providerSig,
      fingerprints: (json['fingerprints'] as List?)
              ?.map(P2pPackageFingerprint.fromJson)
              .whereType<P2pPackageFingerprint>()
              .toList() ??
          const [],
      returnPath: (json['returnPath'] as List?)
              ?.map(P2pPathEntry.fromJson)
              .whereType<P2pPathEntry>()
              .toList() ??
          const [],
      packageData: data,
    );
  }
}

class P2pOfferAnnounce {
  const P2pOfferAnnounce({
    required this.demandId,
    required this.providedPackageHashes,
    required this.providerPubKey,
    required this.providerSig,
  });

  final String demandId;
  final List<String> providedPackageHashes;
  final String providerPubKey;
  final String providerSig;

  Map<String, dynamic> toJson() => {
    'demandId': demandId,
    'providedPackageHashes': providedPackageHashes,
    'providerPubKey': providerPubKey,
    'providerSig': providerSig,
  };

  static P2pOfferAnnounce? fromJson(Map<String, dynamic> json) {
    final demandId = json['demandId'];
    final providerPubKey = json['providerPubKey'];
    final providerSig = json['providerSig'];
    if (demandId is! String ||
        providerPubKey is! String ||
        providerSig is! String) {
      return null;
    }
    return P2pOfferAnnounce(
      demandId: demandId,
      providedPackageHashes:
          (json['providedPackageHashes'] as List?)?.cast<String>() ?? const [],
      providerPubKey: providerPubKey,
      providerSig: providerSig,
    );
  }
}
