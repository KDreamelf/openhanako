import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../identity/keypair.dart';
import '../identity/signed_request.dart' as ph01;
import 'experience_review.dart';

class ExperienceNetworkRequestException implements Exception {
  const ExperienceNetworkRequestException({
    required this.action,
    required this.statusCode,
    required this.message,
    this.errorCode = '',
    this.rawBody = '',
  });

  final String action;
  final int? statusCode;
  final String errorCode;
  final String message;
  final String rawBody;

  @override
  String toString() {
    final parts = <String>[action];
    if (statusCode != null) {
      parts.add('HTTP $statusCode');
    }
    if (errorCode.trim().isNotEmpty) {
      parts.add(errorCode.trim());
    }
    parts.add(message.trim().isEmpty ? '请求失败' : message.trim());
    return parts.join('：');
  }
}

enum ExperienceTransport {
  ipv6Direct('ipv6_direct'),
  ipv4HolePunch('ipv4_hole_punch'),
  dhtRelay('dht_relay'),
  managerSeed('manager_seed');

  const ExperienceTransport(this.wireName);
  final String wireName;
}

enum ExperienceDhtOwnerKind {
  official('official'),
  user('user');

  const ExperienceDhtOwnerKind(this.wireName);
  final String wireName;

  static ExperienceDhtOwnerKind fromWire(String value) => switch (value) {
    'user' => ExperienceDhtOwnerKind.user,
    _ => ExperienceDhtOwnerKind.official,
  };
}

enum ExperienceRelayPolicy {
  public('public'),
  ownerOnly('owner_only'),
  disabled('disabled');

  const ExperienceRelayPolicy(this.wireName);
  final String wireName;

  static ExperienceRelayPolicy fromWire(String value) => switch (value) {
    'owner_only' => ExperienceRelayPolicy.ownerOnly,
    'disabled' => ExperienceRelayPolicy.disabled,
    _ => ExperienceRelayPolicy.public,
  };
}

enum ExperienceDhtHealthStatus {
  healthy('healthy'),
  degraded('degraded'),
  unhealthy('unhealthy');

  const ExperienceDhtHealthStatus(this.wireName);
  final String wireName;

  static ExperienceDhtHealthStatus fromWire(String value) => switch (value) {
    'degraded' => ExperienceDhtHealthStatus.degraded,
    'unhealthy' => ExperienceDhtHealthStatus.unhealthy,
    _ => ExperienceDhtHealthStatus.healthy,
  };
}

ExperienceTransport _transportFromWire(String value) => switch (value) {
  'ipv4_hole_punch' => ExperienceTransport.ipv4HolePunch,
  'dht_relay' => ExperienceTransport.dhtRelay,
  'manager_seed' => ExperienceTransport.managerSeed,
  _ => ExperienceTransport.ipv6Direct,
};

class ExperienceNetworkEndpoint {
  const ExperienceNetworkEndpoint({
    required this.network,
    required this.host,
    required this.port,
    this.requiresHolePunch = false,
  });

  final String network;
  final String host;
  final int port;
  final bool requiresHolePunch;

  bool get isValid => host.trim().isNotEmpty && port > 0 && port <= 65535;

  bool get isIPv6 {
    final parsed = InternetAddress.tryParse(host);
    return parsed != null && parsed.type == InternetAddressType.IPv6;
  }

  bool get isIPv4 {
    final parsed = InternetAddress.tryParse(host);
    return parsed != null && parsed.type == InternetAddressType.IPv4;
  }

  bool get isHttpApi {
    final normalized = network.toLowerCase().trim();
    return normalized == 'http' || normalized == 'https';
  }

  bool get isUdpCandidate {
    final normalized = network.toLowerCase().trim();
    return normalized == 'udp' || normalized == 'udp4' || normalized == 'udp6';
  }

  bool get isQuic => network.toLowerCase().trim() == 'quic';

  String? get baseUrl {
    if (!isValid || !isHttpApi) return null;
    final scheme = network.toLowerCase().trim();
    final normalizedHost = isIPv6 ? '[${host.trim()}]' : host.trim();
    return '$scheme://$normalizedHost:$port';
  }

  Map<String, dynamic> toJson() => {
    'network': network,
    'host': host,
    'port': port,
    if (requiresHolePunch) 'requires_hole_punch': true,
  };

  static ExperienceNetworkEndpoint fromJson(Map<String, dynamic> json) {
    return ExperienceNetworkEndpoint(
      network: json['network']?.toString() ?? 'udp',
      host: json['host']?.toString() ?? '',
      port: _intValue(json['port']),
      requiresHolePunch: json['requires_hole_punch'] == true,
    );
  }
}

class ExperienceDhtLoad {
  const ExperienceDhtLoad({
    this.relayActiveSessions = 0,
    this.relayCapacity = 0,
  });

  final int relayActiveSessions;
  final int relayCapacity;

  bool get hasRelayCapacity =>
      relayCapacity <= 0 || relayActiveSessions < relayCapacity;

  Map<String, dynamic> toJson() => {
    'relay_active_sessions': relayActiveSessions,
    'relay_capacity': relayCapacity,
  };

  static ExperienceDhtLoad fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ExperienceDhtLoad();
    return ExperienceDhtLoad(
      relayActiveSessions: _intValue(json['relay_active_sessions']),
      relayCapacity: _intValue(json['relay_capacity']),
    );
  }
}

class ExperienceDhtNode {
  const ExperienceDhtNode({
    this.schemaVersion = 'ph01.experience.dht_node.v1',
    required this.nodeId,
    this.ownerKind = ExperienceDhtOwnerKind.official,
    this.ownerPeerId,
    this.dhtPeerId,
    this.endpoints = const [],
    this.capabilities = const {},
    this.relayPolicy = ExperienceRelayPolicy.public,
    this.region = '',
    this.load = const ExperienceDhtLoad(),
    this.healthStatus = ExperienceDhtHealthStatus.healthy,
    this.lastHealthCheckAt,
    this.expiresAt,
  });

  final String schemaVersion;
  final String nodeId;
  final ExperienceDhtOwnerKind ownerKind;
  final String? ownerPeerId;
  final String? dhtPeerId;
  final List<ExperienceNetworkEndpoint> endpoints;
  final Map<String, dynamic> capabilities;
  final ExperienceRelayPolicy relayPolicy;
  final String region;
  final ExperienceDhtLoad load;
  final ExperienceDhtHealthStatus healthStatus;
  final DateTime? lastHealthCheckAt;
  final DateTime? expiresAt;

  bool isUsable(DateTime now) {
    if (healthStatus == ExperienceDhtHealthStatus.unhealthy) return false;
    if (expiresAt != null && !expiresAt!.isAfter(now)) return false;
    return endpoints.any((endpoint) => endpoint.isValid);
  }

  bool get supportsRelay {
    if (relayPolicy == ExperienceRelayPolicy.disabled) return false;
    final explicit = capabilities['relay'];
    if (explicit is bool) return explicit && load.hasRelayCapacity;
    return load.hasRelayCapacity;
  }

  bool get supportsHolePunch => capabilities['hole_punch'] == true;

  String? get apiBaseUrl {
    for (final endpoint in endpoints) {
      if (endpoint.network.toLowerCase().trim() == 'https') {
        final baseUrl = endpoint.baseUrl;
        if (baseUrl != null) return baseUrl;
      }
    }
    for (final endpoint in endpoints) {
      if (endpoint.network.toLowerCase().trim() == 'http') {
        final baseUrl = endpoint.baseUrl;
        if (baseUrl != null) return baseUrl;
      }
    }
    return null;
  }

  bool canSendAs(String peerId) {
    final normalized = peerId.trim();
    if (normalized.isEmpty) return false;
    return normalized == dhtPeerId || normalized == ownerPeerId;
  }

  bool canRelayBetween({
    required String requesterPeerId,
    required String providerPeerId,
  }) {
    if (!supportsRelay) return false;
    if (relayPolicy == ExperienceRelayPolicy.public) return true;
    if (relayPolicy == ExperienceRelayPolicy.disabled) return false;
    return _isSelfOrOwner(requesterPeerId) || _isSelfOrOwner(providerPeerId);
  }

  bool _isSelfOrOwner(String peerId) {
    final normalized = peerId.trim();
    if (normalized.isEmpty) return false;
    return normalized == dhtPeerId || normalized == ownerPeerId;
  }

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'node_id': nodeId,
    'owner_kind': ownerKind.wireName,
    if (ownerPeerId != null) 'owner_peer_id': ownerPeerId,
    if (dhtPeerId != null) 'dht_peer_id': dhtPeerId,
    'endpoints': endpoints.map((endpoint) => endpoint.toJson()).toList(),
    'capabilities': capabilities,
    'relay_policy': relayPolicy.wireName,
    if (region.isNotEmpty) 'region': region,
    'load': load.toJson(),
    'health_status': healthStatus.wireName,
    if (lastHealthCheckAt != null)
      'last_health_check_at': lastHealthCheckAt!.toUtc().toIso8601String(),
    if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
  };

  static ExperienceDhtNode fromJson(Map<String, dynamic> json) {
    final endpoints = json['endpoints'] is List
        ? (json['endpoints'] as List)
              .whereType<Map>()
              .map(
                (item) => ExperienceNetworkEndpoint.fromJson(
                  item.cast<String, dynamic>(),
                ),
              )
              .toList(growable: false)
        : const <ExperienceNetworkEndpoint>[];
    return ExperienceDhtNode(
      schemaVersion:
          json['schema_version']?.toString() ?? 'ph01.experience.dht_node.v1',
      nodeId: json['node_id']?.toString() ?? '',
      ownerKind: ExperienceDhtOwnerKind.fromWire(
        json['owner_kind']?.toString() ?? '',
      ),
      ownerPeerId: _nullableString(json['owner_peer_id']),
      dhtPeerId: _nullableString(json['dht_peer_id']),
      endpoints: endpoints,
      capabilities: json['capabilities'] is Map
          ? (json['capabilities'] as Map).cast<String, dynamic>()
          : const {},
      relayPolicy: ExperienceRelayPolicy.fromWire(
        json['relay_policy']?.toString() ?? '',
      ),
      region: json['region']?.toString() ?? '',
      load: ExperienceDhtLoad.fromJson(
        json['load'] is Map
            ? (json['load'] as Map).cast<String, dynamic>()
            : null,
      ),
      healthStatus: ExperienceDhtHealthStatus.fromWire(
        json['health_status']?.toString() ?? '',
      ),
      lastHealthCheckAt: DateTime.tryParse(
        json['last_health_check_at']?.toString() ?? '',
      )?.toUtc(),
      expiresAt: DateTime.tryParse(
        json['expires_at']?.toString() ?? '',
      )?.toUtc(),
    );
  }
}

class ExperienceDhtClientConfig {
  const ExperienceDhtClientConfig({
    this.schemaVersion = 'ph01.experience.dht_client_config.v1',
    this.mode = 'manager_default',
    this.endpoint,
    this.candidateEndpoints = const [],
    this.relayPolicy = ExperienceRelayPolicy.ownerOnly,
    this.publicRegistrationEnabled = false,
    this.managerBaseUrl = '',
    this.adminBaseUrl = '',
  });

  final String schemaVersion;
  final String mode;
  final ExperienceNetworkEndpoint? endpoint;
  final List<ExperienceNetworkEndpoint> candidateEndpoints;
  final ExperienceRelayPolicy relayPolicy;
  final bool publicRegistrationEnabled;
  final String managerBaseUrl;
  final String adminBaseUrl;

  bool get isCustomPrivate => mode == 'custom_private';

  List<ExperienceNetworkEndpoint> get effectiveCandidateEndpoints {
    if (candidateEndpoints.isNotEmpty) return candidateEndpoints;
    return endpoint == null ? const [] : [endpoint!];
  }

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'mode': mode,
    if (effectiveCandidateEndpoints.isNotEmpty)
      'candidate_endpoints': effectiveCandidateEndpoints
          .map((endpoint) => endpoint.toJson())
          .toList(growable: false),
    'relay_policy': relayPolicy.wireName,
    'public_registration_enabled': publicRegistrationEnabled,
    if (adminBaseUrl.trim().isNotEmpty) 'admin_base_url': adminBaseUrl,
  };

  static ExperienceDhtClientConfig fromJson(Map<String, dynamic> json) {
    final endpoints = _endpointsFromJson(json['candidate_endpoints']);
    final legacyEndpoint = json['endpoint'] is Map
        ? ExperienceNetworkEndpoint.fromJson(
            (json['endpoint'] as Map).cast<String, dynamic>(),
          )
        : null;
    return ExperienceDhtClientConfig(
      schemaVersion:
          json['schema_version']?.toString() ??
          'ph01.experience.dht_client_config.v1',
      mode: json['mode']?.toString() ?? 'manager_default',
      endpoint: legacyEndpoint,
      candidateEndpoints: endpoints,
      relayPolicy: ExperienceRelayPolicy.fromWire(
        json['relay_policy']?.toString() ?? 'owner_only',
      ),
      publicRegistrationEnabled: json['public_registration_enabled'] == true,
      managerBaseUrl: json['manager_base_url']?.toString() ?? '',
      adminBaseUrl: json['admin_base_url']?.toString() ?? '',
    );
  }
}

class ExperienceDhtRuntimeState {
  const ExperienceDhtRuntimeState({
    this.publicApiBaseUrl = '',
    this.publicNetwork = '',
    this.publicHost = '',
    this.publicPort = 0,
    this.candidateEndpoints = const [],
    this.ownerKind = '',
    this.region = '',
    this.relayPolicy = '',
    this.relayCapacity = 0,
    this.capabilities = const {},
  });

  final String publicApiBaseUrl;
  final String publicNetwork;
  final String publicHost;
  final int publicPort;
  final List<ExperienceNetworkEndpoint> candidateEndpoints;
  final String ownerKind;
  final String region;
  final String relayPolicy;
  final int relayCapacity;
  final Map<String, dynamic> capabilities;

  static ExperienceDhtRuntimeState fromJson(Map<String, dynamic> json) {
    return ExperienceDhtRuntimeState(
      publicApiBaseUrl: json['public_api_base_url']?.toString() ?? '',
      publicNetwork: json['public_network']?.toString() ?? '',
      publicHost: json['public_host']?.toString() ?? '',
      publicPort: _intValue(json['public_port']),
      candidateEndpoints: _endpointsFromJson(json['candidate_endpoints']),
      ownerKind: json['owner_kind']?.toString() ?? '',
      region: json['region']?.toString() ?? '',
      relayPolicy: json['relay_policy']?.toString() ?? '',
      relayCapacity: _intValue(json['relay_capacity']),
      capabilities: json['capabilities'] is Map
          ? (json['capabilities'] as Map).cast<String, dynamic>()
          : const {},
    );
  }
}

class ExperienceDhtRuntimeConfig {
  const ExperienceDhtRuntimeConfig({
    this.publicApiBaseUrl = '',
    this.endpoint,
    this.candidateEndpoints = const [],
    this.relayPolicy = ExperienceRelayPolicy.ownerOnly,
  });

  final String publicApiBaseUrl;
  final ExperienceNetworkEndpoint? endpoint;
  final List<ExperienceNetworkEndpoint> candidateEndpoints;
  final ExperienceRelayPolicy relayPolicy;

  List<ExperienceNetworkEndpoint> get effectiveCandidateEndpoints {
    if (candidateEndpoints.isNotEmpty) return candidateEndpoints;
    return endpoint == null ? const [] : [endpoint!];
  }

  ExperienceNetworkEndpoint? get legacyPublicEndpoint {
    final endpoints = effectiveCandidateEndpoints;
    if (endpoints.isEmpty) return null;
    for (final endpoint in endpoints) {
      if (endpoint.isUdpCandidate) return endpoint;
    }
    return endpoints.first;
  }

  Map<String, dynamic> toJson() {
    final legacyEndpoint = legacyPublicEndpoint;
    return {
      if (publicApiBaseUrl.trim().isNotEmpty)
        'public_api_base_url': publicApiBaseUrl.trim(),
      if (effectiveCandidateEndpoints.isNotEmpty)
        'candidate_endpoints': effectiveCandidateEndpoints
            .map((endpoint) => endpoint.toJson())
            .toList(growable: false),
      if (legacyEndpoint != null) ...{
        'public_network': legacyEndpoint.network.trim(),
        'public_host': legacyEndpoint.host.trim(),
        'public_port': legacyEndpoint.port,
      },
      'owner_kind': 'user',
      'relay_policy': relayPolicy.wireName,
      'capabilities': const {
        'peer_discovery': true,
        'hole_punch': true,
        'relay': true,
        'package_provider_index': true,
      },
    };
  }
}

class ExperienceDhtAdminState {
  const ExperienceDhtAdminState({
    this.schemaVersion = 'ph01.experience.dht_state.v1',
    required this.nodeId,
    this.boundPubkeyHex = '',
    this.boundAt,
    this.bootstrapManagerBaseUrl = '',
    this.publicEnabled = false,
    this.publicRegistered = false,
    this.publicManagerBaseUrl = '',
    this.runtimeConfig,
    this.updatedAt,
  });

  final String schemaVersion;
  final String nodeId;
  final String boundPubkeyHex;
  final DateTime? boundAt;
  final String bootstrapManagerBaseUrl;
  final bool publicEnabled;
  final bool publicRegistered;
  final String publicManagerBaseUrl;
  final ExperienceDhtRuntimeState? runtimeConfig;
  final DateTime? updatedAt;

  bool get bound => boundPubkeyHex.trim().isNotEmpty;

  static ExperienceDhtAdminState fromJson(Map<String, dynamic> json) {
    return ExperienceDhtAdminState(
      schemaVersion:
          json['schema_version']?.toString() ?? 'ph01.experience.dht_state.v1',
      nodeId: json['node_id']?.toString() ?? '',
      boundPubkeyHex: json['bound_pubkey_hex']?.toString() ?? '',
      boundAt: DateTime.tryParse(json['bound_at']?.toString() ?? '')?.toUtc(),
      bootstrapManagerBaseUrl:
          json['bootstrap_manager_base_url']?.toString() ?? '',
      publicEnabled: json['public_enabled'] == true,
      publicRegistered: json['public_registered'] == true,
      publicManagerBaseUrl: json['public_manager_base_url']?.toString() ?? '',
      runtimeConfig: json['runtime_config'] is Map
          ? ExperienceDhtRuntimeState.fromJson(
              (json['runtime_config'] as Map).cast<String, dynamic>(),
            )
          : null,
      updatedAt: DateTime.tryParse(
        json['updated_at']?.toString() ?? '',
      )?.toUtc(),
    );
  }
}

class ExperienceDhtAdminStatus {
  const ExperienceDhtAdminStatus({
    required this.state,
    this.boundPubkey = '',
    this.boundHash = '',
    this.publicConfig,
  });

  final ExperienceDhtAdminState state;
  final String boundPubkey;
  final String boundHash;
  final ExperienceDhtNode? publicConfig;

  static ExperienceDhtAdminStatus fromJson(Map<String, dynamic> json) {
    return ExperienceDhtAdminStatus(
      state: ExperienceDhtAdminState.fromJson(_mapFromJson(json['state'])),
      boundPubkey: json['bound_pubkey']?.toString() ?? '',
      boundHash: json['bound_hash']?.toString() ?? '',
      publicConfig: json['public_config'] is Map
          ? ExperienceDhtNode.fromJson(
              (json['public_config'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }
}

class ExperienceDhtPublicModeResult {
  const ExperienceDhtPublicModeResult({required this.state, this.node});

  final ExperienceDhtAdminState state;
  final ExperienceDhtNode? node;

  static ExperienceDhtPublicModeResult fromJson(Map<String, dynamic> json) {
    return ExperienceDhtPublicModeResult(
      state: ExperienceDhtAdminState.fromJson(_mapFromJson(json['state'])),
      node: json['node'] is Map
          ? ExperienceDhtNode.fromJson(
              (json['node'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }
}

class ExperiencePeerCandidate {
  const ExperiencePeerCandidate({
    required this.peerId,
    this.endpoints = const [],
  });

  final String peerId;
  final List<ExperienceNetworkEndpoint> endpoints;
}

class ExperienceDhtPresence {
  const ExperienceDhtPresence({
    required this.peerId,
    this.ownerPeerId,
    this.endpoints = const [],
    this.packageHashes = const [],
    this.ttlSeconds,
  });

  final String peerId;
  final String? ownerPeerId;
  final List<ExperienceNetworkEndpoint> endpoints;
  final List<String> packageHashes;
  final int? ttlSeconds;

  Map<String, dynamic> toJson() => {
    'peer_id': peerId,
    if (ownerPeerId != null && ownerPeerId!.trim().isNotEmpty)
      'owner_peer_id': ownerPeerId,
    'endpoints': endpoints.map((endpoint) => endpoint.toJson()).toList(),
    if (packageHashes.isNotEmpty) 'package_hashes': packageHashes,
    if (ttlSeconds != null) 'ttl_seconds': ttlSeconds,
  };
}

class ExperienceDhtProviderRecord {
  const ExperienceDhtProviderRecord({
    required this.peerId,
    this.ownerPeerId,
    this.endpoints = const [],
    this.packageHashes = const [],
    required this.expiresAt,
    required this.updatedAt,
  });

  final String peerId;
  final String? ownerPeerId;
  final List<ExperienceNetworkEndpoint> endpoints;
  final List<String> packageHashes;
  final DateTime? expiresAt;
  final DateTime? updatedAt;

  ExperiencePeerCandidate toPeerCandidate() {
    return ExperiencePeerCandidate(peerId: peerId, endpoints: endpoints);
  }

  bool isUsable(DateTime now, {String? packageHash}) {
    if (peerId.trim().isEmpty) return false;
    if (expiresAt != null && !expiresAt!.isAfter(now)) return false;
    if (!endpoints.any((endpoint) => endpoint.isValid)) return false;
    final requestedHash = packageHash?.trim();
    if (requestedHash != null &&
        requestedHash.isNotEmpty &&
        !packageHashes.contains(requestedHash)) {
      return false;
    }
    return true;
  }

  static ExperienceDhtProviderRecord fromJson(Map<String, dynamic> json) {
    final endpoints = json['endpoints'] is List
        ? (json['endpoints'] as List)
              .whereType<Map>()
              .map(
                (item) => ExperienceNetworkEndpoint.fromJson(
                  item.cast<String, dynamic>(),
                ),
              )
              .toList(growable: false)
        : const <ExperienceNetworkEndpoint>[];
    return ExperienceDhtProviderRecord(
      peerId: json['peer_id']?.toString() ?? '',
      ownerPeerId: _nullableString(json['owner_peer_id']),
      endpoints: endpoints,
      packageHashes: _stringList(json['package_hashes']),
      expiresAt: DateTime.tryParse(
        json['expires_at']?.toString() ?? '',
      )?.toUtc(),
      updatedAt: DateTime.tryParse(
        json['updated_at']?.toString() ?? '',
      )?.toUtc(),
    );
  }
}

class ExperiencePackageRequest {
  const ExperiencePackageRequest({
    this.schemaVersion = 'ph01.experience.package_request.v1',
    required this.requestId,
    required this.experienceId,
    required this.packageHash,
    required this.requesterPeerId,
    required this.requesterPublicKey,
    this.requesterOwnerPeerId,
    this.requesterAddrs = const [],
    this.preferredTransports = const [
      ExperienceTransport.ipv6Direct,
      ExperienceTransport.ipv4HolePunch,
      ExperienceTransport.dhtRelay,
      ExperienceTransport.managerSeed,
    ],
    this.dhtNodeId,
    required this.nonce,
    required this.timestamp,
    this.requesterSignature = '',
    this.ttlSeconds,
  });

  final String schemaVersion;
  final String requestId;
  final String experienceId;
  final String packageHash;
  final String requesterPeerId;
  final String requesterPublicKey;
  final String? requesterOwnerPeerId;
  final List<ExperienceNetworkEndpoint> requesterAddrs;
  final List<ExperienceTransport> preferredTransports;
  final String? dhtNodeId;
  final String nonce;
  final DateTime timestamp;
  final String requesterSignature;
  final int? ttlSeconds;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'request_id': requestId,
    'experience_id': experienceId,
    'package_hash': packageHash,
    'requester_peer_id': requesterPeerId,
    'requester_public_key': requesterPublicKey,
    if (requesterOwnerPeerId != null && requesterOwnerPeerId!.trim().isNotEmpty)
      'requester_owner_peer_id': requesterOwnerPeerId,
    'requester_addrs': requesterAddrs
        .map((endpoint) => endpoint.toJson())
        .toList(),
    'preferred_transports': preferredTransports
        .map((transport) => transport.wireName)
        .toList(),
    if (dhtNodeId != null) 'dht_node_id': dhtNodeId,
    'nonce': nonce,
    'timestamp': timestamp.toUtc().toIso8601String(),
    if (requesterSignature.trim().isNotEmpty)
      'requester_signature': requesterSignature,
    if (ttlSeconds != null) 'ttl_seconds': ttlSeconds,
  };

  static ExperiencePackageRequest fromJson(Map<String, dynamic> json) {
    return ExperiencePackageRequest(
      schemaVersion:
          json['schema_version']?.toString() ??
          'ph01.experience.package_request.v1',
      requestId: json['request_id']?.toString() ?? '',
      experienceId: json['experience_id']?.toString() ?? '',
      packageHash: json['package_hash']?.toString() ?? '',
      requesterPeerId: json['requester_peer_id']?.toString() ?? '',
      requesterPublicKey: json['requester_public_key']?.toString() ?? '',
      requesterOwnerPeerId: _nullableString(json['requester_owner_peer_id']),
      requesterAddrs: _endpointsFromJson(json['requester_addrs']),
      preferredTransports: _stringList(
        json['preferred_transports'],
      ).map(_transportFromWire).toList(growable: false),
      dhtNodeId: _nullableString(json['dht_node_id']),
      nonce: json['nonce']?.toString() ?? '',
      timestamp:
          DateTime.tryParse(json['timestamp']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      requesterSignature: json['requester_signature']?.toString() ?? '',
      ttlSeconds: json['ttl_seconds'] == null
          ? null
          : _intValue(json['ttl_seconds']),
    );
  }
}

class ExperiencePackageOffer {
  const ExperiencePackageOffer({
    this.schemaVersion = 'ph01.experience.package_offer.v1',
    required this.requestId,
    required this.experienceId,
    required this.packageHash,
    required this.providerPeerId,
    this.providerOwnerPeerId,
    this.providerAddrs = const [],
    this.availableTransports = const [],
    this.reviewMaterials,
    this.publisher = const {},
    required this.nonce,
    required this.timestamp,
    this.providerSignature = '',
  });

  final String schemaVersion;
  final String requestId;
  final String experienceId;
  final String packageHash;
  final String providerPeerId;
  final String? providerOwnerPeerId;
  final List<ExperienceNetworkEndpoint> providerAddrs;
  final List<ExperienceTransport> availableTransports;
  final ExperienceReviewMaterials? reviewMaterials;
  final Map<String, dynamic> publisher;
  final String nonce;
  final DateTime timestamp;
  final String providerSignature;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'request_id': requestId,
    'experience_id': experienceId,
    'package_hash': packageHash,
    'provider_peer_id': providerPeerId,
    if (providerOwnerPeerId != null && providerOwnerPeerId!.trim().isNotEmpty)
      'provider_owner_peer_id': providerOwnerPeerId,
    'provider_addrs': providerAddrs
        .map((endpoint) => endpoint.toJson())
        .toList(),
    'available_transports': availableTransports
        .map((transport) => transport.wireName)
        .toList(),
    if (reviewMaterials != null) 'review_materials': reviewMaterials!.toJson(),
    'publisher': publisher,
    'nonce': nonce,
    'timestamp': timestamp.toUtc().toIso8601String(),
    if (providerSignature.trim().isNotEmpty)
      'provider_signature': providerSignature,
  };

  static ExperiencePackageOffer fromJson(Map<String, dynamic> json) {
    return ExperiencePackageOffer(
      schemaVersion:
          json['schema_version']?.toString() ??
          'ph01.experience.package_offer.v1',
      requestId: json['request_id']?.toString() ?? '',
      experienceId: json['experience_id']?.toString() ?? '',
      packageHash: json['package_hash']?.toString() ?? '',
      providerPeerId: json['provider_peer_id']?.toString() ?? '',
      providerOwnerPeerId: _nullableString(json['provider_owner_peer_id']),
      providerAddrs: _endpointsFromJson(json['provider_addrs']),
      availableTransports: _stringList(
        json['available_transports'],
      ).map(_transportFromWire).toList(growable: false),
      reviewMaterials: json['review_materials'] is Map
          ? ExperienceReviewMaterials.fromJson(
              (json['review_materials'] as Map).cast<String, dynamic>(),
            )
          : null,
      publisher: json['publisher'] is Map
          ? (json['publisher'] as Map).cast<String, dynamic>()
          : const {},
      nonce: json['nonce']?.toString() ?? '',
      timestamp:
          DateTime.tryParse(json['timestamp']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      providerSignature: json['provider_signature']?.toString() ?? '',
    );
  }
}

class ExperiencePackageRequestRecord {
  const ExperiencePackageRequestRecord({
    required this.request,
    required this.expiresAt,
    required this.updatedAt,
  });

  final ExperiencePackageRequest request;
  final DateTime? expiresAt;
  final DateTime? updatedAt;

  static ExperiencePackageRequestRecord fromJson(Map<String, dynamic> json) {
    return ExperiencePackageRequestRecord(
      request: ExperiencePackageRequest.fromJson(json),
      expiresAt: DateTime.tryParse(
        json['expires_at']?.toString() ?? '',
      )?.toUtc(),
      updatedAt: DateTime.tryParse(
        json['updated_at']?.toString() ?? '',
      )?.toUtc(),
    );
  }
}

class ExperiencePackageOfferRecord {
  const ExperiencePackageOfferRecord({
    required this.offer,
    required this.offeredAt,
  });

  final ExperiencePackageOffer offer;
  final DateTime? offeredAt;

  static ExperiencePackageOfferRecord fromJson(Map<String, dynamic> json) {
    return ExperiencePackageOfferRecord(
      offer: ExperiencePackageOffer.fromJson(json),
      offeredAt: DateTime.tryParse(
        json['offered_at']?.toString() ?? '',
      )?.toUtc(),
    );
  }
}

class ExperienceDemandReturnHop {
  const ExperienceDemandReturnHop({
    required this.nodeId,
    this.apiBaseUrl = '',
    this.seenAt,
  });

  final String nodeId;
  final String apiBaseUrl;
  final DateTime? seenAt;

  Map<String, dynamic> toJson() => {
    'node_id': nodeId,
    if (apiBaseUrl.trim().isNotEmpty) 'api_base_url': apiBaseUrl.trim(),
    if (seenAt != null) 'seen_at': seenAt!.toUtc().toIso8601String(),
  };

  static ExperienceDemandReturnHop fromJson(Map<String, dynamic> json) {
    return ExperienceDemandReturnHop(
      nodeId: json['node_id']?.toString() ?? '',
      apiBaseUrl: json['api_base_url']?.toString() ?? '',
      seenAt: DateTime.tryParse(json['seen_at']?.toString() ?? '')?.toUtc(),
    );
  }
}

class ExperienceDemand {
  const ExperienceDemand({
    this.schemaVersion = 'ph01.experience.demand.v1',
    required this.requestId,
    required this.naturalLanguageQuery,
    this.queryLanguage = 'zh-CN',
    this.queryKeywords = const [],
    required this.requesterPeerId,
    this.requesterOwnerPeerId,
    this.requesterPubkeyHash = '',
    this.preferredTransports = const [
      ExperienceTransport.dhtRelay,
      ExperienceTransport.managerSeed,
    ],
    this.ttlSeconds,
    this.hopLimit = 8,
    this.returnPath = const [],
    required this.createdAt,
    this.nonce = '',
    this.requesterSignature = '',
  });

  final String schemaVersion;
  final String requestId;
  final String naturalLanguageQuery;
  final String queryLanguage;
  final List<String> queryKeywords;
  final String requesterPeerId;
  final String? requesterOwnerPeerId;
  final String requesterPubkeyHash;
  final List<ExperienceTransport> preferredTransports;
  final int? ttlSeconds;
  final int hopLimit;
  final List<ExperienceDemandReturnHop> returnPath;
  final DateTime createdAt;
  final String nonce;
  final String requesterSignature;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'request_id': requestId,
    'natural_language_query': naturalLanguageQuery,
    if (queryLanguage.trim().isNotEmpty) 'query_language': queryLanguage,
    if (queryKeywords.isNotEmpty) 'query_keywords': queryKeywords,
    'requester_peer_id': requesterPeerId,
    if (requesterOwnerPeerId != null && requesterOwnerPeerId!.trim().isNotEmpty)
      'requester_owner_peer_id': requesterOwnerPeerId,
    if (requesterPubkeyHash.trim().isNotEmpty)
      'requester_pubkey_hash': requesterPubkeyHash,
    'preferred_transports': preferredTransports
        .map((transport) => transport.wireName)
        .toList(growable: false),
    if (ttlSeconds != null) 'ttl_seconds': ttlSeconds,
    'hop_limit': hopLimit,
    if (returnPath.isNotEmpty)
      'return_path': returnPath.map((hop) => hop.toJson()).toList(),
    'created_at': createdAt.toUtc().toIso8601String(),
    if (nonce.trim().isNotEmpty) 'nonce': nonce,
    if (requesterSignature.trim().isNotEmpty)
      'requester_signature': requesterSignature,
  };

  static ExperienceDemand fromJson(Map<String, dynamic> json) {
    return ExperienceDemand(
      schemaVersion:
          json['schema_version']?.toString() ?? 'ph01.experience.demand.v1',
      requestId: json['request_id']?.toString() ?? '',
      naturalLanguageQuery: json['natural_language_query']?.toString() ?? '',
      queryLanguage: json['query_language']?.toString() ?? '',
      queryKeywords: _stringList(json['query_keywords']),
      requesterPeerId: json['requester_peer_id']?.toString() ?? '',
      requesterOwnerPeerId: _nullableString(json['requester_owner_peer_id']),
      requesterPubkeyHash: json['requester_pubkey_hash']?.toString() ?? '',
      preferredTransports: _stringList(
        json['preferred_transports'],
      ).map(_transportFromWire).toList(growable: false),
      ttlSeconds: json['ttl_seconds'] == null
          ? null
          : _intValue(json['ttl_seconds']),
      hopLimit: _intValue(json['hop_limit']),
      returnPath: _demandReturnPathFromJson(json['return_path']),
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      nonce: json['nonce']?.toString() ?? '',
      requesterSignature: json['requester_signature']?.toString() ?? '',
    );
  }
}

class ExperienceDemandRecord {
  const ExperienceDemandRecord({
    required this.demand,
    required this.expiresAt,
    required this.updatedAt,
  });

  final ExperienceDemand demand;
  final DateTime? expiresAt;
  final DateTime? updatedAt;

  static ExperienceDemandRecord fromJson(Map<String, dynamic> json) {
    return ExperienceDemandRecord(
      demand: ExperienceDemand.fromJson(json),
      expiresAt: DateTime.tryParse(
        json['expires_at']?.toString() ?? '',
      )?.toUtc(),
      updatedAt: DateTime.tryParse(
        json['updated_at']?.toString() ?? '',
      )?.toUtc(),
    );
  }
}

class ExperienceReviewChainRef {
  const ExperienceReviewChainRef({
    required this.digest,
    required this.length,
    this.url = '',
  });

  final String digest;
  final int length;
  final String url;

  Map<String, dynamic> toJson() => {
    'digest': digest,
    'length': length,
    if (url.trim().isNotEmpty) 'url': url.trim(),
  };

  static ExperienceReviewChainRef fromJson(Map<String, dynamic> json) {
    return ExperienceReviewChainRef(
      digest: json['digest']?.toString() ?? '',
      length: _intValue(json['length']),
      url: json['url']?.toString() ?? '',
    );
  }
}

class ExperienceDemandOffer {
  const ExperienceDemandOffer({
    this.schemaVersion = 'ph01.experience.demand_offer.v1',
    required this.requestId,
    required this.experienceId,
    required this.packageHash,
    this.title = '',
    this.brief = '',
    this.keywords = const [],
    this.matchedReason = '',
    this.reviewChain = const [],
    this.reviewChainDigest = '',
    this.reviewChainLength = 0,
    this.reviewChainRef,
    required this.providerPeerId,
    this.providerOwnerPeerId,
    this.providerAddrs = const [],
    this.availableTransports = const [],
    this.returnPath = const [],
    this.relaySessionId = '',
    this.nonce = '',
    required this.timestamp,
    this.providerSignature = '',
  });

  final String schemaVersion;
  final String requestId;
  final String experienceId;
  final String packageHash;
  final String title;
  final String brief;
  final List<String> keywords;
  final String matchedReason;
  final List<Map<String, dynamic>> reviewChain;
  final String reviewChainDigest;
  final int reviewChainLength;
  final ExperienceReviewChainRef? reviewChainRef;
  final String providerPeerId;
  final String? providerOwnerPeerId;
  final List<ExperienceNetworkEndpoint> providerAddrs;
  final List<ExperienceTransport> availableTransports;
  final List<ExperienceDemandReturnHop> returnPath;
  final String relaySessionId;
  final String nonce;
  final DateTime timestamp;
  final String providerSignature;

  int get effectiveReviewChainLength =>
      reviewChainLength > 0 ? reviewChainLength : reviewChain.length;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'request_id': requestId,
    'experience_id': experienceId,
    'package_hash': packageHash,
    if (title.trim().isNotEmpty) 'title': title,
    if (brief.trim().isNotEmpty) 'brief': brief,
    if (keywords.isNotEmpty) 'keywords': keywords,
    if (matchedReason.trim().isNotEmpty) 'matched_reason': matchedReason,
    'review_chain': reviewChain,
    if (reviewChainDigest.trim().isNotEmpty)
      'review_chain_digest': reviewChainDigest,
    'review_chain_length': effectiveReviewChainLength,
    if (reviewChainRef != null) 'review_chain_ref': reviewChainRef!.toJson(),
    'provider_peer_id': providerPeerId,
    if (providerOwnerPeerId != null && providerOwnerPeerId!.trim().isNotEmpty)
      'provider_owner_peer_id': providerOwnerPeerId,
    if (providerAddrs.isNotEmpty)
      'provider_addrs': providerAddrs
          .map((endpoint) => endpoint.toJson())
          .toList(growable: false),
    if (availableTransports.isNotEmpty)
      'available_transports': availableTransports
          .map((transport) => transport.wireName)
          .toList(growable: false),
    if (returnPath.isNotEmpty)
      'return_path': returnPath.map((hop) => hop.toJson()).toList(),
    if (relaySessionId.trim().isNotEmpty) 'relay_session_id': relaySessionId,
    if (nonce.trim().isNotEmpty) 'nonce': nonce,
    'timestamp': timestamp.toUtc().toIso8601String(),
    if (providerSignature.trim().isNotEmpty)
      'provider_signature': providerSignature,
  };

  static ExperienceDemandOffer fromJson(Map<String, dynamic> json) {
    return ExperienceDemandOffer(
      schemaVersion:
          json['schema_version']?.toString() ??
          'ph01.experience.demand_offer.v1',
      requestId: json['request_id']?.toString() ?? '',
      experienceId: json['experience_id']?.toString() ?? '',
      packageHash: json['package_hash']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      brief: json['brief']?.toString() ?? '',
      keywords: _stringList(json['keywords']),
      matchedReason: json['matched_reason']?.toString() ?? '',
      reviewChain: _jsonMapList(json['review_chain']),
      reviewChainDigest: json['review_chain_digest']?.toString() ?? '',
      reviewChainLength: _intValue(json['review_chain_length']),
      reviewChainRef: _reviewChainRefFromJson(json['review_chain_ref']),
      providerPeerId: json['provider_peer_id']?.toString() ?? '',
      providerOwnerPeerId: _nullableString(json['provider_owner_peer_id']),
      providerAddrs: _endpointsFromJson(json['provider_addrs']),
      availableTransports: _stringList(
        json['available_transports'],
      ).map(_transportFromWire).toList(growable: false),
      returnPath: _demandReturnPathFromJson(json['return_path']),
      relaySessionId: json['relay_session_id']?.toString() ?? '',
      nonce: json['nonce']?.toString() ?? '',
      timestamp:
          DateTime.tryParse(json['timestamp']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      providerSignature: json['provider_signature']?.toString() ?? '',
    );
  }
}

class ExperienceDhtPackageCacheRecord {
  const ExperienceDhtPackageCacheRecord({
    required this.packageHash,
    this.experienceId = '',
    this.bytes = 0,
    this.payloadSha256 = '',
    this.storedAt,
    this.expiresAt,
  });

  final String packageHash;
  final String experienceId;
  final int bytes;
  final String payloadSha256;
  final DateTime? storedAt;
  final DateTime? expiresAt;

  static ExperienceDhtPackageCacheRecord fromJson(Map<String, dynamic> json) {
    return ExperienceDhtPackageCacheRecord(
      packageHash: json['package_hash']?.toString() ?? '',
      experienceId: json['experience_id']?.toString() ?? '',
      bytes: _intValue(json['bytes']),
      payloadSha256: json['payload_sha256']?.toString() ?? '',
      storedAt: DateTime.tryParse(json['stored_at']?.toString() ?? '')?.toUtc(),
      expiresAt: DateTime.tryParse(
        json['expires_at']?.toString() ?? '',
      )?.toUtc(),
    );
  }
}

class ExperienceDemandOfferRecord {
  const ExperienceDemandOfferRecord({
    required this.offer,
    required this.offeredAt,
  });

  final ExperienceDemandOffer offer;
  final DateTime? offeredAt;

  static ExperienceDemandOfferRecord fromJson(Map<String, dynamic> json) {
    return ExperienceDemandOfferRecord(
      offer: ExperienceDemandOffer.fromJson(json),
      offeredAt: DateTime.tryParse(
        json['offered_at']?.toString() ?? '',
      )?.toUtc(),
    );
  }
}

class ExperienceDhtRelaySessionRequest {
  const ExperienceDhtRelaySessionRequest({
    this.schemaVersion = 'ph01.experience.relay_session_request.v1',
    required this.requestId,
    this.experienceId = '',
    required this.packageHash,
    required this.requesterPeerId,
    this.requesterOwnerPeerId,
    required this.providerPeerId,
    this.providerOwnerPeerId,
    this.ttlSeconds,
    this.maxBytes,
  });

  final String schemaVersion;
  final String requestId;
  final String experienceId;
  final String packageHash;
  final String requesterPeerId;
  final String? requesterOwnerPeerId;
  final String providerPeerId;
  final String? providerOwnerPeerId;
  final int? ttlSeconds;
  final int? maxBytes;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'request_id': requestId,
    if (experienceId.trim().isNotEmpty) 'experience_id': experienceId,
    'package_hash': packageHash,
    'requester_peer_id': requesterPeerId,
    if (requesterOwnerPeerId != null && requesterOwnerPeerId!.trim().isNotEmpty)
      'requester_owner_peer_id': requesterOwnerPeerId,
    'provider_peer_id': providerPeerId,
    if (providerOwnerPeerId != null && providerOwnerPeerId!.trim().isNotEmpty)
      'provider_owner_peer_id': providerOwnerPeerId,
    if (ttlSeconds != null) 'ttl_seconds': ttlSeconds,
    if (maxBytes != null) 'max_bytes': maxBytes,
  };
}

class ExperienceDhtRelaySession {
  const ExperienceDhtRelaySession({
    this.schemaVersion = 'ph01.experience.relay_session.v1',
    required this.sessionId,
    required this.requestId,
    this.experienceId = '',
    required this.packageHash,
    required this.requesterPeerId,
    required this.providerPeerId,
    required this.expiresAt,
    required this.maxBytes,
    required this.status,
    this.bytes = 0,
    this.payloadSha256 = '',
  });

  final String schemaVersion;
  final String sessionId;
  final String requestId;
  final String experienceId;
  final String packageHash;
  final String requesterPeerId;
  final String providerPeerId;
  final DateTime? expiresAt;
  final int maxBytes;
  final String status;
  final int bytes;
  final String payloadSha256;

  bool get hasPayload => status == 'uploaded' && bytes > 0;

  static ExperienceDhtRelaySession fromJson(Map<String, dynamic> json) {
    return ExperienceDhtRelaySession(
      schemaVersion:
          json['schema_version']?.toString() ??
          'ph01.experience.relay_session.v1',
      sessionId: json['session_id']?.toString() ?? '',
      requestId: json['request_id']?.toString() ?? '',
      experienceId: json['experience_id']?.toString() ?? '',
      packageHash: json['package_hash']?.toString() ?? '',
      requesterPeerId: json['requester_peer_id']?.toString() ?? '',
      providerPeerId: json['provider_peer_id']?.toString() ?? '',
      expiresAt: DateTime.tryParse(
        json['expires_at']?.toString() ?? '',
      )?.toUtc(),
      maxBytes: _intValue(json['max_bytes']),
      status: json['status']?.toString() ?? '',
      bytes: _intValue(json['bytes']),
      payloadSha256: json['payload_sha256']?.toString() ?? '',
    );
  }
}

class ExperienceDhtHolePunchSessionRequest {
  const ExperienceDhtHolePunchSessionRequest({
    this.schemaVersion = 'ph01.experience.hole_punch_request.v1',
    required this.requestId,
    this.experienceId = '',
    required this.packageHash,
    required this.requesterPeerId,
    this.requesterOwnerPeerId,
    this.requesterAddrs = const [],
    required this.providerPeerId,
    this.providerOwnerPeerId,
    this.providerAddrs = const [],
    this.ttlSeconds,
  });

  final String schemaVersion;
  final String requestId;
  final String experienceId;
  final String packageHash;
  final String requesterPeerId;
  final String? requesterOwnerPeerId;
  final List<ExperienceNetworkEndpoint> requesterAddrs;
  final String providerPeerId;
  final String? providerOwnerPeerId;
  final List<ExperienceNetworkEndpoint> providerAddrs;
  final int? ttlSeconds;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'request_id': requestId,
    if (experienceId.trim().isNotEmpty) 'experience_id': experienceId,
    'package_hash': packageHash,
    'requester_peer_id': requesterPeerId,
    if (requesterOwnerPeerId != null && requesterOwnerPeerId!.trim().isNotEmpty)
      'requester_owner_peer_id': requesterOwnerPeerId,
    if (requesterAddrs.isNotEmpty)
      'requester_addrs': requesterAddrs
          .map((endpoint) => endpoint.toJson())
          .toList(),
    'provider_peer_id': providerPeerId,
    if (providerOwnerPeerId != null && providerOwnerPeerId!.trim().isNotEmpty)
      'provider_owner_peer_id': providerOwnerPeerId,
    if (providerAddrs.isNotEmpty)
      'provider_addrs': providerAddrs
          .map((endpoint) => endpoint.toJson())
          .toList(),
    if (ttlSeconds != null) 'ttl_seconds': ttlSeconds,
  };
}

class ExperienceDhtHolePunchReport {
  const ExperienceDhtHolePunchReport({
    required this.peerId,
    required this.role,
    required this.result,
    this.observedEndpoint,
    this.localEndpoints = const [],
    this.message = '',
    this.updatedAt,
  });

  final String peerId;
  final String role;
  final String result;
  final ExperienceNetworkEndpoint? observedEndpoint;
  final List<ExperienceNetworkEndpoint> localEndpoints;
  final String message;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'peer_id': peerId,
    'role': role,
    'result': result,
    if (observedEndpoint != null)
      'observed_endpoint': observedEndpoint!.toJson(),
    if (localEndpoints.isNotEmpty)
      'local_endpoints': localEndpoints
          .map((endpoint) => endpoint.toJson())
          .toList(),
    if (message.trim().isNotEmpty) 'message': message,
    if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
  };

  static ExperienceDhtHolePunchReport fromJson(Map<String, dynamic> json) {
    return ExperienceDhtHolePunchReport(
      peerId: json['peer_id']?.toString() ?? '',
      role: json['role']?.toString() ?? '',
      result: json['result']?.toString() ?? '',
      observedEndpoint: json['observed_endpoint'] is Map
          ? ExperienceNetworkEndpoint.fromJson(
              (json['observed_endpoint'] as Map).cast<String, dynamic>(),
            )
          : null,
      localEndpoints: _endpointsFromJson(json['local_endpoints']),
      message: json['message']?.toString() ?? '',
      updatedAt: DateTime.tryParse(
        json['updated_at']?.toString() ?? '',
      )?.toUtc(),
    );
  }
}

class ExperienceDhtHolePunchSession {
  const ExperienceDhtHolePunchSession({
    this.schemaVersion = 'ph01.experience.hole_punch_session.v1',
    required this.sessionId,
    required this.requestId,
    this.experienceId = '',
    required this.packageHash,
    required this.requesterPeerId,
    this.requesterAddrs = const [],
    required this.providerPeerId,
    this.providerAddrs = const [],
    required this.punchToken,
    required this.expiresAt,
    required this.status,
    this.requesterReport,
    this.providerReport,
  });

  final String schemaVersion;
  final String sessionId;
  final String requestId;
  final String experienceId;
  final String packageHash;
  final String requesterPeerId;
  final List<ExperienceNetworkEndpoint> requesterAddrs;
  final String providerPeerId;
  final List<ExperienceNetworkEndpoint> providerAddrs;
  final String punchToken;
  final DateTime? expiresAt;
  final String status;
  final ExperienceDhtHolePunchReport? requesterReport;
  final ExperienceDhtHolePunchReport? providerReport;

  static ExperienceDhtHolePunchSession fromJson(Map<String, dynamic> json) {
    return ExperienceDhtHolePunchSession(
      schemaVersion:
          json['schema_version']?.toString() ??
          'ph01.experience.hole_punch_session.v1',
      sessionId: json['session_id']?.toString() ?? '',
      requestId: json['request_id']?.toString() ?? '',
      experienceId: json['experience_id']?.toString() ?? '',
      packageHash: json['package_hash']?.toString() ?? '',
      requesterPeerId: json['requester_peer_id']?.toString() ?? '',
      requesterAddrs: _endpointsFromJson(json['requester_addrs']),
      providerPeerId: json['provider_peer_id']?.toString() ?? '',
      providerAddrs: _endpointsFromJson(json['provider_addrs']),
      punchToken: json['punch_token']?.toString() ?? '',
      expiresAt: DateTime.tryParse(
        json['expires_at']?.toString() ?? '',
      )?.toUtc(),
      status: json['status']?.toString() ?? '',
      requesterReport: json['requester_report'] is Map
          ? ExperienceDhtHolePunchReport.fromJson(
              (json['requester_report'] as Map).cast<String, dynamic>(),
            )
          : null,
      providerReport: json['provider_report'] is Map
          ? ExperienceDhtHolePunchReport.fromJson(
              (json['provider_report'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }
}

class ExperienceConnectionAttempt {
  const ExperienceConnectionAttempt({
    required this.transport,
    required this.peerId,
    this.endpoint,
    this.dhtNodeId,
    required this.reason,
  });

  final ExperienceTransport transport;
  final String peerId;
  final ExperienceNetworkEndpoint? endpoint;
  final String? dhtNodeId;
  final String reason;

  Map<String, dynamic> toJson() => {
    'transport': transport.wireName,
    'peer_id': peerId,
    if (endpoint != null) 'endpoint': endpoint!.toJson(),
    if (dhtNodeId != null) 'dht_node_id': dhtNodeId,
    'reason': reason,
  };
}

class ExperienceConnectionPlanner {
  const ExperienceConnectionPlanner();

  List<ExperienceConnectionAttempt> plan({
    required ExperiencePeerCandidate provider,
    required String requesterPeerId,
    List<ExperienceDhtNode> dhtNodes = const [],
    DateTime? now,
    bool managerSeedAvailable = true,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final attempts = <ExperienceConnectionAttempt>[];
    final endpoints = provider.endpoints.where((item) => item.isValid).toList();

    for (final endpoint in endpoints.where(
      (item) => item.isIPv6 && !item.requiresHolePunch,
    )) {
      attempts.add(
        ExperienceConnectionAttempt(
          transport: ExperienceTransport.ipv6Direct,
          peerId: provider.peerId,
          endpoint: endpoint,
          reason: 'IPv6 直连优先',
        ),
      );
    }

    for (final endpoint in endpoints.where((item) => item.isIPv4)) {
      attempts.add(
        ExperienceConnectionAttempt(
          transport: ExperienceTransport.ipv4HolePunch,
          peerId: provider.peerId,
          endpoint: endpoint,
          reason: endpoint.requiresHolePunch ? 'IPv4 打洞' : 'IPv4 候选',
        ),
      );
    }

    final relayNodes =
        dhtNodes
            .where((node) => node.isUsable(timestamp))
            .where(
              (node) => node.canRelayBetween(
                requesterPeerId: requesterPeerId,
                providerPeerId: provider.peerId,
              ),
            )
            .toList()
          ..sort(_compareDhtNodes);
    for (final node in relayNodes) {
      attempts.add(
        ExperienceConnectionAttempt(
          transport: ExperienceTransport.dhtRelay,
          peerId: provider.peerId,
          dhtNodeId: node.nodeId,
          reason: node.relayPolicy == ExperienceRelayPolicy.ownerOnly
              ? 'owner-only DHT relay'
              : '公共 DHT relay',
        ),
      );
    }

    if (managerSeedAvailable) {
      attempts.add(
        ExperienceConnectionAttempt(
          transport: ExperienceTransport.managerSeed,
          peerId: 'experience-manager',
          reason: '管理端超级节点兜底',
        ),
      );
    }
    return attempts;
  }

  int _compareDhtNodes(ExperienceDhtNode a, ExperienceDhtNode b) {
    final region = a.region.compareTo(b.region);
    if (region != 0) return region;
    return a.load.relayActiveSessions.compareTo(b.load.relayActiveSessions);
  }
}

class ExperienceNetworkManagerClient {
  static const defaultManagerBaseUrl = 'https://experience.xn--lbtx0e.cn';

  ExperienceNetworkManagerClient({
    String managerBaseUrl = defaultManagerBaseUrl,
    Dio? dio,
  }) : managerBaseUrl = _normalizeBaseUrl(managerBaseUrl, 'managerBaseUrl'),
       _dio = dio ?? Dio();

  final String managerBaseUrl;
  final Dio _dio;

  Future<List<ExperienceDhtNode>> fetchPublicDhtNodes({
    DateTime? now,
    String? bearerToken,
  }) async {
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse('$managerBaseUrl/api/v1/dht/nodes'),
      options: Options(
        contentType: Headers.jsonContentType,
        headers: _authHeaders(bearerToken),
      ),
    );
    final items = resp.data?['items'];
    if (items is! List) return const [];
    final timestamp = (now ?? DateTime.now()).toUtc();
    return items
        .whereType<Map>()
        .map((item) => ExperienceDhtNode.fromJson(item.cast<String, dynamic>()))
        .where((node) => node.isUsable(timestamp))
        .toList(growable: false);
  }

  Future<ExperienceReviewMaterials> fetchReviewMaterials({
    required String experienceId,
    String? bearerToken,
  }) async {
    final id = experienceId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(
        experienceId,
        'experienceId',
        'must not be empty',
      );
    }
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse('$managerBaseUrl/api/v1/experiences/$id/review-materials'),
      options: Options(
        contentType: Headers.jsonContentType,
        headers: _authHeaders(bearerToken),
      ),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('管理端未返回审核签名材料');
    }
    return ExperienceReviewMaterials.fromJson(data);
  }

  Future<Uint8List> fetchPackage({
    required String experienceId,
    String? bearerToken,
  }) async {
    final id = experienceId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(
        experienceId,
        'experienceId',
        'must not be empty',
      );
    }
    final resp = await _dio.getUri<List<int>>(
      Uri.parse('$managerBaseUrl/api/v1/experiences/$id/package'),
      options: Options(
        responseType: ResponseType.bytes,
        headers: _authHeaders(bearerToken),
      ),
    );
    final data = resp.data;
    if (data == null || data.isEmpty) {
      throw StateError('管理端未返回完整经验包');
    }
    return Uint8List.fromList(data);
  }

  Future<ExperiencePackagePowChallenge> startPackagePowChallenge({
    required String packageSha256,
    required String pubkeyHash,
  }) async {
    late final Response<Map<String, dynamic>> resp;
    try {
      resp = await _dio.postUri<Map<String, dynamic>>(
        Uri.parse('$managerBaseUrl/api/v1/experiences/package-pow/challenge'),
        data: {
          'package_sha256': packageSha256.trim().toLowerCase(),
          'pubkey_hash': pubkeyHash.trim().toLowerCase(),
        },
        options: Options(contentType: Headers.jsonContentType),
      );
    } on DioException catch (e) {
      throw _experienceNetworkException(e, '申请经验包工作量证明挑战失败');
    }
    final data = resp.data;
    if (data == null) {
      throw StateError('经验管理端未返回工作量证明挑战');
    }
    return ExperiencePackagePowChallenge.fromJson(data);
  }

  Future<ExperienceSubmissionResult> submitPackageForReview({
    required Uint8List packageBytes,
    required HanakoKeyPair keyPair,
    required ExperiencePackagePowProof packagePow,
    String filename = '',
  }) async {
    if (packageBytes.isEmpty) {
      throw ArgumentError.value(packageBytes.length, 'packageBytes', 'empty');
    }
    final packageSha256 = sha256.convert(packageBytes).toString();
    if (packagePow.packageSha256.trim().toLowerCase() != packageSha256) {
      throw ArgumentError.value(
        packagePow.packageSha256,
        'packagePow.packageSha256',
        'mismatch packageBytes sha256',
      );
    }
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: {
        'schema_version': 'ph01.experience.upload.v1',
        if (filename.trim().isNotEmpty) 'filename': filename.trim(),
        'package_base64': base64Encode(packageBytes),
        'package_sha256': packageSha256,
        'package_pow': packagePow.toJson(),
      },
    );
    late final Response<Map<String, dynamic>> resp;
    try {
      resp = await _dio.postUri<Map<String, dynamic>>(
        Uri.parse('$managerBaseUrl/api/v1/experiences'),
        data: signed.toJson(),
        options: Options(contentType: Headers.jsonContentType),
      );
    } on DioException catch (e) {
      throw _experienceNetworkException(e, '提交经验审核失败');
    }
    final data = resp.data;
    if (data == null) {
      throw StateError('经验管理端未返回提审结果');
    }
    return ExperienceSubmissionResult.fromJson(data);
  }
}

ExperienceNetworkRequestException _experienceNetworkException(
  DioException error,
  String action,
) {
  final response = error.response;
  final bodyText = _dioBodyText(response?.data);
  final decoded = _decodeJsonMap(response?.data);
  final code = decoded?['error']?.toString().trim() ?? '';
  final decodedMessage = decoded?['message']?.toString().trim() ?? '';
  final message = decodedMessage.ifEmpty(
    bodyText.trim().ifEmpty(error.message ?? '网络请求失败'),
  );
  return ExperienceNetworkRequestException(
    action: action,
    statusCode: response?.statusCode,
    errorCode: code,
    message: message,
    rawBody: bodyText,
  );
}

Map<String, dynamic>? _decodeJsonMap(Object? data) {
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return data.cast<String, dynamic>();
  if (data is String && data.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
  }
  return null;
}

String _dioBodyText(Object? data) {
  if (data == null) return '';
  if (data is String) return data;
  if (data is List<int>) return utf8.decode(data, allowMalformed: true);
  try {
    return const JsonEncoder.withIndent('  ').convert(data);
  } catch (_) {
    return data.toString();
  }
}

extension _ExperienceStringExt on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class ExperiencePackagePowChallenge {
  const ExperiencePackagePowChallenge({
    required this.challengeId,
    this.expiresAt = 0,
  });

  factory ExperiencePackagePowChallenge.fromJson(Map<String, dynamic> json) {
    return ExperiencePackagePowChallenge(
      challengeId: json['challenge_id'] as String,
      expiresAt: (json['expires_at'] as num?)?.toInt() ?? 0,
    );
  }

  final String challengeId;
  final int expiresAt;
}

class ExperiencePackagePowProof {
  const ExperiencePackagePowProof({
    required this.challengeId,
    required this.packageSha256,
    required this.pubkeyHash,
  });

  Map<String, dynamic> toJson() {
    return {
      'challenge_id': challengeId,
      'package_sha256': packageSha256,
      'pubkey_hash': pubkeyHash,
    };
  }

  final String challengeId;
  final String packageSha256;
  final String pubkeyHash;
}

class ExperienceSubmissionResult {
  const ExperienceSubmissionResult({
    required this.experienceId,
    required this.status,
    this.title = '',
    this.path = '',
    this.packagePath = '',
    this.contentHash = '',
    this.reviewReason = '',
    this.raw = const {},
  });

  final String experienceId;
  final String status;
  final String title;
  final String path;
  final String packagePath;
  final String contentHash;
  final String reviewReason;
  final Map<String, dynamic> raw;

  bool get approved => status == 'network';
  bool get pendingReview => status == 'inbox';

  static ExperienceSubmissionResult fromJson(Map<String, dynamic> json) {
    return ExperienceSubmissionResult(
      experienceId: json['experience_id']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      packagePath: json['package_path']?.toString() ?? '',
      contentHash: json['content_hash']?.toString() ?? '',
      reviewReason: json['review_reason']?.toString() ?? '',
      raw: json,
    );
  }
}

class ExperienceDhtHttpClient {
  ExperienceDhtHttpClient({required String dhtBaseUrl, Dio? dio})
    : dhtBaseUrl = _normalizeBaseUrl(dhtBaseUrl, 'dhtBaseUrl'),
      _dio = dio ?? Dio();

  final String dhtBaseUrl;
  final Dio _dio;

  Future<Map<String, dynamic>> healthz() async {
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/healthz'),
      options: Options(contentType: Headers.jsonContentType),
    );
    return resp.data ?? const {};
  }

  Future<ExperienceDhtAdminState> bindAdmin({
    required String initPassword,
    required String pubkeyHex,
    String managerBaseUrl = '',
    ExperienceDhtRuntimeConfig? runtimeConfig,
  }) async {
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/admin/bind'),
      data: {
        'init_password': initPassword.trim(),
        'pubkey_hex': pubkeyHex.trim(),
        if (managerBaseUrl.trim().isNotEmpty)
          'manager_base_url': managerBaseUrl.trim(),
        if (runtimeConfig != null) 'runtime_config': runtimeConfig.toJson(),
      },
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回绑定状态');
    }
    return ExperienceDhtAdminState.fromJson(_mapFromJson(data['state']));
  }

  Future<ExperienceDhtAdminStatus> fetchAdminStatus({
    required HanakoKeyPair keyPair,
  }) async {
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: {'op': 'status'},
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/admin/status'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回管理状态');
    }
    return ExperienceDhtAdminStatus.fromJson(data);
  }

  Future<ExperienceDhtAdminState> setBootstrapManager({
    required HanakoKeyPair keyPair,
    required String managerBaseUrl,
  }) async {
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: {'manager_base_url': managerBaseUrl.trim()},
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/admin/bootstrap'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回 bootstrap 管理端状态');
    }
    return ExperienceDhtAdminState.fromJson(_mapFromJson(data['state']));
  }

  Future<ExperienceDhtAdminState> setRuntimeConfig({
    required HanakoKeyPair keyPair,
    required ExperienceDhtRuntimeConfig runtimeConfig,
  }) async {
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: {'runtime_config': runtimeConfig.toJson()},
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/admin/config'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回运行配置状态');
    }
    return ExperienceDhtAdminState.fromJson(_mapFromJson(data['state']));
  }

  Future<ExperienceDhtPublicModeResult> setPublicMode({
    required bool enabled,
    required HanakoKeyPair keyPair,
    String managerBaseUrl = '',
  }) async {
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: {
        'enabled': enabled,
        if (managerBaseUrl.trim().isNotEmpty)
          'manager_base_url': managerBaseUrl.trim(),
      },
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/admin/public'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回公开模式状态');
    }
    return ExperienceDhtPublicModeResult.fromJson(data);
  }

  Future<ExperienceDhtProviderRecord> announcePresence({
    required ExperienceDhtPresence presence,
    required HanakoKeyPair keyPair,
  }) async {
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: presence.toJson(),
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/peers/presence'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回 presence 记录');
    }
    return ExperienceDhtProviderRecord.fromJson(data);
  }

  Future<List<ExperienceDhtProviderRecord>> fetchProviders({
    required String packageHash,
    DateTime? now,
  }) async {
    final hash = packageHash.trim();
    if (hash.isEmpty) {
      throw ArgumentError.value(
        packageHash,
        'packageHash',
        'must not be empty',
      );
    }
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse(
        '$dhtBaseUrl/api/v1/providers',
      ).replace(queryParameters: {'package_hash': hash}),
      options: Options(contentType: Headers.jsonContentType),
    );
    final items = resp.data?['items'];
    if (items is! List) return const [];
    final timestamp = (now ?? DateTime.now()).toUtc();
    return items
        .whereType<Map>()
        .map(
          (item) => ExperienceDhtProviderRecord.fromJson(
            item.cast<String, dynamic>(),
          ),
        )
        .where((record) => record.isUsable(timestamp, packageHash: hash))
        .toList(growable: false);
  }

  Future<ExperiencePackageRequestRecord> publishPackageRequest({
    required ExperiencePackageRequest request,
    required HanakoKeyPair keyPair,
  }) async {
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: request.toJson(),
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/package-requests'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回包请求记录');
    }
    return ExperiencePackageRequestRecord.fromJson(data);
  }

  Future<List<ExperiencePackageRequestRecord>> fetchPackageRequests({
    required String packageHash,
  }) async {
    final hash = packageHash.trim();
    if (hash.isEmpty) {
      throw ArgumentError.value(
        packageHash,
        'packageHash',
        'must not be empty',
      );
    }
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse(
        '$dhtBaseUrl/api/v1/package-requests',
      ).replace(queryParameters: {'package_hash': hash}),
      options: Options(contentType: Headers.jsonContentType),
    );
    final items = resp.data?['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map(
          (item) => ExperiencePackageRequestRecord.fromJson(
            item.cast<String, dynamic>(),
          ),
        )
        .toList(growable: false);
  }

  Future<ExperiencePackageOfferRecord> publishPackageOffer({
    required String requestId,
    required ExperiencePackageOffer offer,
    required HanakoKeyPair keyPair,
  }) async {
    final id = _requiredID(requestId, 'requestId');
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: offer.toJson(),
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/package-requests/$id/offers'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回包 offer 记录');
    }
    return ExperiencePackageOfferRecord.fromJson(data);
  }

  Future<List<ExperiencePackageOfferRecord>> fetchPackageOffers({
    required String requestId,
  }) async {
    final id = _requiredID(requestId, 'requestId');
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/package-requests/$id/offers'),
      options: Options(contentType: Headers.jsonContentType),
    );
    final items = resp.data?['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map(
          (item) => ExperiencePackageOfferRecord.fromJson(
            item.cast<String, dynamic>(),
          ),
        )
        .toList(growable: false);
  }

  Future<ExperienceDemandRecord> publishExperienceDemand({
    required ExperienceDemand demand,
    required HanakoKeyPair keyPair,
  }) async {
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: demand.toJson(),
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/experience-demands'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回经验需求记录');
    }
    return ExperienceDemandRecord.fromJson(data);
  }

  Future<List<ExperienceDemandRecord>> fetchExperienceDemands({
    String query = '',
    String requestId = '',
    int limit = 100,
  }) async {
    final params = <String, String>{};
    if (query.trim().isNotEmpty) params['q'] = query.trim();
    if (requestId.trim().isNotEmpty) params['request_id'] = requestId.trim();
    if (limit > 0) params['limit'] = limit.toString();
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse(
        '$dhtBaseUrl/api/v1/experience-demands',
      ).replace(queryParameters: params.isEmpty ? null : params),
      options: Options(contentType: Headers.jsonContentType),
    );
    final items = resp.data?['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map(
          (item) =>
              ExperienceDemandRecord.fromJson(item.cast<String, dynamic>()),
        )
        .toList(growable: false);
  }

  Future<ExperienceDemandOfferRecord> publishExperienceDemandOffer({
    required String requestId,
    required ExperienceDemandOffer offer,
    required HanakoKeyPair keyPair,
  }) async {
    final id = _requiredID(requestId, 'requestId');
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: offer.toJson(),
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/experience-demands/$id/offers'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回经验需求 offer');
    }
    return ExperienceDemandOfferRecord.fromJson(data);
  }

  Future<List<ExperienceDemandOfferRecord>> fetchExperienceDemandOffers({
    required String requestId,
    bool includeReviewChain = true,
  }) async {
    final id = _requiredID(requestId, 'requestId');
    final params = includeReviewChain
        ? null
        : const <String, String>{'include_review_chain': 'false'};
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse(
        '$dhtBaseUrl/api/v1/experience-demands/$id/offers',
      ).replace(queryParameters: params),
      options: Options(contentType: Headers.jsonContentType),
    );
    final items = resp.data?['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map(
          (item) => ExperienceDemandOfferRecord.fromJson(
            item.cast<String, dynamic>(),
          ),
        )
        .toList(growable: false);
  }

  Future<ExperienceDhtPackageCacheRecord> uploadCachedPackage({
    required String packageHash,
    required Uint8List packageBytes,
    String experienceId = '',
    String? baseUrl,
  }) async {
    if (packageBytes.isEmpty) {
      throw ArgumentError.value(
        packageBytes,
        'packageBytes',
        'must not be empty',
      );
    }
    final root = _normalizeOptionalBaseUrl(baseUrl) ?? dhtBaseUrl;
    final segment = _hashPathSegment(packageHash, 'packageHash');
    final resp = await _dio.putUri<Map<String, dynamic>>(
      Uri.parse('$root/api/v1/cache/packages/${Uri.encodeComponent(segment)}'),
      data: packageBytes,
      options: Options(
        contentType: 'application/octet-stream',
        headers: experienceId.trim().isEmpty
            ? null
            : {'X-PH01-Experience-ID': experienceId.trim()},
      ),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回缓存写入结果');
    }
    return ExperienceDhtPackageCacheRecord.fromJson(data);
  }

  Future<int> uploadCachedPackageToReturnPath({
    required String packageHash,
    required Uint8List packageBytes,
    String experienceId = '',
    List<ExperienceDemandReturnHop> returnPath = const [],
  }) async {
    var uploaded = 0;
    for (final baseUrl in _returnPathCacheBaseUrls(
      returnPath,
      dhtBaseUrl,
      reversePath: true,
    )) {
      try {
        await uploadCachedPackage(
          packageHash: packageHash,
          packageBytes: packageBytes,
          experienceId: experienceId,
          baseUrl: baseUrl,
        );
        uploaded++;
      } catch (_) {
        continue;
      }
    }
    return uploaded;
  }

  Future<Uint8List> downloadCachedPackage({
    required String packageHash,
    List<ExperienceDemandReturnHop> returnPath = const [],
  }) async {
    final segment = _hashPathSegment(packageHash, 'packageHash');
    Object? lastError;
    for (final baseUrl in _returnPathCacheBaseUrls(returnPath, dhtBaseUrl)) {
      try {
        final resp = await _dio.getUri<List<int>>(
          Uri.parse(
            '$baseUrl/api/v1/cache/packages/${Uri.encodeComponent(segment)}',
          ),
          options: Options(responseType: ResponseType.bytes),
        );
        final data = resp.data;
        if (data != null && data.isNotEmpty) {
          return Uint8List.fromList(data);
        }
      } catch (err) {
        lastError = err;
      }
    }
    throw StateError('DHT 缓存未命中：$lastError');
  }

  Future<List<Map<String, dynamic>>> fetchReviewChainByDigest({
    required String digest,
    String? baseUrl,
  }) async {
    final root = _normalizeOptionalBaseUrl(baseUrl) ?? dhtBaseUrl;
    final segment = _hashPathSegment(digest, 'digest');
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse('$root/api/v1/review-chains/${Uri.encodeComponent(segment)}'),
      options: Options(contentType: Headers.jsonContentType),
    );
    return _jsonMapList(resp.data?['review_chain']);
  }

  Future<ExperienceDhtRelaySession> createRelaySession({
    required ExperienceDhtRelaySessionRequest request,
    required HanakoKeyPair keyPair,
  }) async {
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: request.toJson(),
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/relay/sessions'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回 relay 会话');
    }
    return ExperienceDhtRelaySession.fromJson(data);
  }

  Future<ExperienceDhtRelaySession> uploadRelayPackage({
    required String sessionId,
    required Uint8List packageBytes,
  }) async {
    final id = _requiredID(sessionId, 'sessionId');
    if (packageBytes.isEmpty) {
      throw ArgumentError.value(
        packageBytes,
        'packageBytes',
        'must not be empty',
      );
    }
    final resp = await _dio.putUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/relay/sessions/$id/package'),
      data: packageBytes,
      options: Options(contentType: 'application/octet-stream'),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回 relay 上传状态');
    }
    return ExperienceDhtRelaySession.fromJson(data);
  }

  Future<Uint8List> downloadRelayPackage({required String sessionId}) async {
    final id = _requiredID(sessionId, 'sessionId');
    final resp = await _dio.getUri<List<int>>(
      Uri.parse('$dhtBaseUrl/api/v1/relay/sessions/$id/package'),
      options: Options(responseType: ResponseType.bytes),
    );
    final data = resp.data;
    if (data == null || data.isEmpty) {
      throw StateError('DHT relay 未返回包字节');
    }
    return Uint8List.fromList(data);
  }

  Future<ExperienceDhtHolePunchSession> createHolePunchSession({
    required ExperienceDhtHolePunchSessionRequest request,
    required HanakoKeyPair keyPair,
  }) async {
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: request.toJson(),
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/hole-punch/sessions'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回打洞协调会话');
    }
    return ExperienceDhtHolePunchSession.fromJson(data);
  }

  Future<ExperienceDhtHolePunchSession> reportHolePunch({
    required String sessionId,
    required ExperienceDhtHolePunchReport report,
    required HanakoKeyPair keyPair,
  }) async {
    final id = _requiredID(sessionId, 'sessionId');
    final signed = ph01.signRequest(
      keyPair: keyPair,
      businessPayload: report.toJson(),
    );
    final resp = await _dio.postUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/hole-punch/sessions/$id/reports'),
      data: signed.toJson(),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回打洞协调状态');
    }
    return ExperienceDhtHolePunchSession.fromJson(data);
  }

  Future<ExperienceDhtHolePunchSession> fetchHolePunchSession({
    required String sessionId,
  }) async {
    final id = _requiredID(sessionId, 'sessionId');
    final resp = await _dio.getUri<Map<String, dynamic>>(
      Uri.parse('$dhtBaseUrl/api/v1/hole-punch/sessions/$id'),
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = resp.data;
    if (data == null) {
      throw StateError('DHT 未返回打洞协调状态');
    }
    return ExperienceDhtHolePunchSession.fromJson(data);
  }
}

enum ExperienceNetworkPathStatus {
  unavailable,
  direct,
  holePunchable,
  notPunchable;

  String get label => switch (this) {
    ExperienceNetworkPathStatus.direct => '直连',
    ExperienceNetworkPathStatus.holePunchable => '可打洞',
    ExperienceNetworkPathStatus.notPunchable => '不可打洞',
    ExperienceNetworkPathStatus.unavailable => '不可用',
  };
}

class ExperienceLocalNetworkState {
  const ExperienceLocalNetworkState({
    required this.hasIPv4,
    required this.hasIPv6,
  });

  final bool hasIPv4;
  final bool hasIPv6;

  static Future<ExperienceLocalNetworkState> detect() async {
    var hasIPv4 = false;
    var hasIPv6 = false;
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final address in iface.addresses) {
        if (address.type == InternetAddressType.IPv4) {
          hasIPv4 = true;
        } else if (address.type == InternetAddressType.IPv6) {
          hasIPv6 = true;
        }
      }
    }
    return ExperienceLocalNetworkState(hasIPv4: hasIPv4, hasIPv6: hasIPv6);
  }
}

class ExperienceDhtConnectionStatus {
  const ExperienceDhtConnectionStatus({
    required this.node,
    required this.apiBaseUrl,
    required this.connected,
    this.error,
  });

  final ExperienceDhtNode node;
  final String? apiBaseUrl;
  final bool connected;
  final String? error;
}

class ExperienceNetworkStatus {
  const ExperienceNetworkStatus({
    required this.managerBaseUrl,
    required this.publicDhtCount,
    required this.configuredDhtCount,
    required this.connectedDhtCount,
    required this.ipv6Status,
    required this.ipv4Status,
    this.connections = const [],
    required this.checkedAt,
    this.error,
  });

  final String managerBaseUrl;
  final int publicDhtCount;
  final int configuredDhtCount;
  final int connectedDhtCount;
  final ExperienceNetworkPathStatus ipv6Status;
  final ExperienceNetworkPathStatus ipv4Status;
  final List<ExperienceDhtConnectionStatus> connections;
  final DateTime checkedAt;
  final String? error;

  bool get hasConnectedDht => connectedDhtCount > 0;
  bool get hasIPv6Direct => ipv6Status == ExperienceNetworkPathStatus.direct;
  bool get hasIPv4HolePunch =>
      ipv4Status == ExperienceNetworkPathStatus.holePunchable;

  String get bestModeLabel {
    if (hasIPv6Direct) return 'IPv6 可以直连';
    if (hasIPv4HolePunch) return 'IPv4 打洞成功';
    if (ipv4Status == ExperienceNetworkPathStatus.notPunchable) {
      return 'IPv4 不可打洞';
    }
    return '未连接';
  }

  static ExperienceNetworkStatus unavailable({
    String managerBaseUrl =
        ExperienceNetworkManagerClient.defaultManagerBaseUrl,
    String? error,
    DateTime? checkedAt,
  }) {
    return ExperienceNetworkStatus(
      managerBaseUrl: managerBaseUrl,
      publicDhtCount: 0,
      configuredDhtCount: 0,
      connectedDhtCount: 0,
      ipv6Status: ExperienceNetworkPathStatus.unavailable,
      ipv4Status: ExperienceNetworkPathStatus.unavailable,
      checkedAt: (checkedAt ?? DateTime.now()).toUtc(),
      error: error,
    );
  }
}

typedef ExperienceLocalNetworkStateProvider =
    Future<ExperienceLocalNetworkState> Function();

class ExperienceNetworkStatusProbe {
  ExperienceNetworkStatusProbe({
    required ExperienceDhtClientConfig config,
    required String fallbackManagerBaseUrl,
    Dio? dio,
    ExperienceLocalNetworkStateProvider? localNetworkStateProvider,
    Duration probeTimeout = const Duration(seconds: 2),
  }) : _config = config,
       _fallbackManagerBaseUrl = fallbackManagerBaseUrl,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: probeTimeout,
               receiveTimeout: probeTimeout,
               sendTimeout: probeTimeout,
             ),
           ),
       _localNetworkStateProvider =
           localNetworkStateProvider ?? ExperienceLocalNetworkState.detect,
       _probeTimeout = probeTimeout;

  final ExperienceDhtClientConfig _config;
  final String _fallbackManagerBaseUrl;
  final Dio _dio;
  final ExperienceLocalNetworkStateProvider _localNetworkStateProvider;
  final Duration _probeTimeout;

  Future<ExperienceNetworkStatus> probe({DateTime? now}) async {
    final checkedAt = (now ?? DateTime.now()).toUtc();
    final managerBaseUrl = _managerBaseUrl();
    final publicNodes = await _fetchPublicNodes(managerBaseUrl, checkedAt);
    final privateNode = _privateNode();
    final nodes = <ExperienceDhtNode>[...publicNodes, ?privateNode];
    final connections = await Future.wait(
      nodes.map(_probeDhtNode),
      eagerError: false,
    );
    final localState = await _localNetworkStateProvider();
    final connectedNodes = connections
        .where((item) => item.connected)
        .map((item) => item.node)
        .toList(growable: false);
    return ExperienceNetworkStatus(
      managerBaseUrl: managerBaseUrl,
      publicDhtCount: publicNodes.length,
      configuredDhtCount: nodes.length,
      connectedDhtCount: connections.where((item) => item.connected).length,
      ipv6Status: _ipv6Status(localState, connectedNodes),
      ipv4Status: _ipv4Status(localState, connectedNodes),
      connections: connections,
      checkedAt: checkedAt,
    );
  }

  String _managerBaseUrl() {
    final fallback = _fallbackManagerBaseUrl.trim();
    if (fallback.isNotEmpty) return fallback;
    return ExperienceNetworkManagerClient.defaultManagerBaseUrl;
  }

  Future<List<ExperienceDhtNode>> _fetchPublicNodes(
    String managerBaseUrl,
    DateTime now,
  ) async {
    if (managerBaseUrl.trim().isEmpty) return const [];
    try {
      return await ExperienceNetworkManagerClient(
        managerBaseUrl: managerBaseUrl,
        dio: _dio,
      ).fetchPublicDhtNodes(now: now);
    } catch (_) {
      return const [];
    }
  }

  ExperienceDhtNode? _privateNode() {
    final candidateEndpoints = _config.effectiveCandidateEndpoints
        .where((endpoint) => endpoint.isValid)
        .toList(growable: false);
    if (!_config.isCustomPrivate && candidateEndpoints.isEmpty) {
      return null;
    }
    final endpoints = <ExperienceNetworkEndpoint>[...candidateEndpoints];
    final apiEndpoint = _httpEndpointFromBaseUrl(_config.adminBaseUrl);
    if (apiEndpoint != null) {
      endpoints.insert(0, apiEndpoint);
    }
    return ExperienceDhtNode(
      nodeId: 'custom_private',
      ownerKind: ExperienceDhtOwnerKind.user,
      dhtPeerId: 'custom_private',
      endpoints: endpoints,
      capabilities: const {'relay': true, 'hole_punch': true},
      relayPolicy: _config.relayPolicy,
      healthStatus: ExperienceDhtHealthStatus.healthy,
    );
  }

  Future<ExperienceDhtConnectionStatus> _probeDhtNode(
    ExperienceDhtNode node,
  ) async {
    final apiBaseUrl = node.apiBaseUrl;
    if (apiBaseUrl == null) {
      return ExperienceDhtConnectionStatus(
        node: node,
        apiBaseUrl: null,
        connected: false,
        error: '缺少 HTTP API 端点',
      );
    }
    try {
      final resp = await _dio.getUri<Map<String, dynamic>>(
        Uri.parse('$apiBaseUrl/healthz'),
        options: Options(
          contentType: Headers.jsonContentType,
          receiveTimeout: _probeTimeout,
          sendTimeout: _probeTimeout,
        ),
      );
      final data = resp.data ?? const {};
      final ok =
          resp.statusCode != null &&
          resp.statusCode! >= 200 &&
          resp.statusCode! < 300 &&
          data['ok'] != false;
      return ExperienceDhtConnectionStatus(
        node: node,
        apiBaseUrl: apiBaseUrl,
        connected: ok,
        error: ok ? null : 'healthz 未通过',
      );
    } catch (e) {
      return ExperienceDhtConnectionStatus(
        node: node,
        apiBaseUrl: apiBaseUrl,
        connected: false,
        error: '$e',
      );
    }
  }

  ExperienceNetworkPathStatus _ipv6Status(
    ExperienceLocalNetworkState localState,
    List<ExperienceDhtNode> connectedNodes,
  ) {
    if (!localState.hasIPv6) return ExperienceNetworkPathStatus.unavailable;
    final hasIPv6Dht = connectedNodes.any(
      (node) => node.endpoints.any(
        (endpoint) => endpoint.isIPv6 && !endpoint.requiresHolePunch,
      ),
    );
    return hasIPv6Dht
        ? ExperienceNetworkPathStatus.direct
        : ExperienceNetworkPathStatus.unavailable;
  }

  ExperienceNetworkPathStatus _ipv4Status(
    ExperienceLocalNetworkState localState,
    List<ExperienceDhtNode> connectedNodes,
  ) {
    if (!localState.hasIPv4) return ExperienceNetworkPathStatus.unavailable;
    final hasPunchableDht = connectedNodes.any(
      (node) =>
          node.supportsHolePunch &&
          node.endpoints.any(
            (endpoint) =>
                endpoint.isIPv4 &&
                endpoint.isUdpCandidate &&
                endpoint.requiresHolePunch,
          ),
    );
    if (hasPunchableDht) return ExperienceNetworkPathStatus.holePunchable;
    final hasConnectedIPv4Dht = connectedNodes.any(
      (node) => node.endpoints.any((endpoint) => endpoint.isIPv4),
    );
    if (hasConnectedIPv4Dht) return ExperienceNetworkPathStatus.notPunchable;
    return ExperienceNetworkPathStatus.unavailable;
  }
}

int _intValue(Object? value) => switch (value) {
  int v => v,
  num v => v.toInt(),
  String v => int.tryParse(v.trim()) ?? 0,
  _ => 0,
};

Map<String, dynamic> _mapFromJson(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return const {};
}

String _normalizeBaseUrl(String value, String argumentName) {
  final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, argumentName, 'must not be empty');
  }
  return normalized;
}

String? _normalizeOptionalBaseUrl(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return text.replaceFirst(RegExp(r'/+$'), '');
}

Map<String, String>? _authHeaders(String? bearerToken) {
  final token = bearerToken?.trim();
  if (token == null || token.isEmpty) return null;
  return {'Authorization': 'Bearer $token'};
}

String? _nullableString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String _requiredID(String value, String argumentName) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, argumentName, 'must not be empty');
  }
  return normalized;
}

String _hashPathSegment(String value, String argumentName) {
  final normalized = _requiredID(value, argumentName);
  return normalized.replaceFirst(RegExp('^sha256:', caseSensitive: false), '');
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value
      .map((item) => item.toString())
      .where((item) => item.trim().isNotEmpty)
      .toList(growable: false);
}

List<Map<String, dynamic>> _jsonMapList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList(growable: false);
}

ExperienceReviewChainRef? _reviewChainRefFromJson(Object? value) {
  if (value is! Map) return null;
  final ref = ExperienceReviewChainRef.fromJson(value.cast<String, dynamic>());
  return ref.digest.trim().isEmpty ? null : ref;
}

List<ExperienceNetworkEndpoint> _endpointsFromJson(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map(
        (item) =>
            ExperienceNetworkEndpoint.fromJson(item.cast<String, dynamic>()),
      )
      .toList(growable: false);
}

List<String> _returnPathCacheBaseUrls(
  List<ExperienceDemandReturnHop> returnPath,
  String dhtBaseUrl, {
  bool reversePath = false,
}) {
  final out = <String>[];
  final seen = <String>{};
  void add(String value) {
    final normalized = _normalizeOptionalBaseUrl(value);
    if (normalized == null || !seen.add(normalized)) return;
    out.add(normalized);
  }

  final hops = reversePath ? returnPath.reversed : returnPath;
  for (final hop in hops) {
    add(hop.apiBaseUrl);
  }
  add(dhtBaseUrl);
  return out;
}

List<ExperienceDemandReturnHop> _demandReturnPathFromJson(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map(
        (item) =>
            ExperienceDemandReturnHop.fromJson(item.cast<String, dynamic>()),
      )
      .where((hop) => hop.nodeId.trim().isNotEmpty)
      .toList(growable: false);
}

ExperienceNetworkEndpoint? _httpEndpointFromBaseUrl(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  final uri = Uri.tryParse(normalized);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final host = uri.host.trim();
  if (host.isEmpty) return null;
  final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
  return ExperienceNetworkEndpoint(network: scheme, host: host, port: port);
}
