import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'experience_network.dart';

const String _kUdpPunchSchemaVersion = 'ph01.experience.hole_punch_udp.v1';

class ExperienceUdpHolePuncher {
  const ExperienceUdpHolePuncher({
    this.timeout = const Duration(seconds: 5),
    this.probeInterval = const Duration(milliseconds: 250),
  });

  final Duration timeout;
  final Duration probeInterval;

  Future<ExperienceUdpHolePunchResult> punch({
    required ExperienceDhtHolePunchSession session,
    required String peerId,
    required String role,
    List<ExperienceNetworkEndpoint> remoteEndpoints = const [],
    Duration? timeout,
    Duration? probeInterval,
  }) async {
    final sessionId = session.sessionId.trim();
    final punchToken = session.punchToken.trim();
    final normalizedPeerId = peerId.trim();
    final normalizedRole = role.trim();
    final validRemotes = remoteEndpoints
        .where((endpoint) => endpoint.isValid)
        .where(
          (endpoint) =>
              endpoint.network.toLowerCase().startsWith('udp') &&
              (endpoint.isIPv4 || endpoint.isIPv6),
        )
        .toList(growable: false);
    if (sessionId.isEmpty) {
      return ExperienceUdpHolePunchResult.failed(
        sessionId: '',
        peerId: normalizedPeerId,
        role: normalizedRole,
        message: 'hole-punch session_id 不能为空',
      );
    }
    if (punchToken.isEmpty) {
      return ExperienceUdpHolePunchResult.failed(
        sessionId: sessionId,
        peerId: normalizedPeerId,
        role: normalizedRole,
        message: 'hole-punch punch_token 不能为空',
      );
    }
    if (normalizedPeerId.isEmpty) {
      return ExperienceUdpHolePunchResult.failed(
        sessionId: sessionId,
        peerId: normalizedPeerId,
        role: normalizedRole,
        message: 'peer_id 不能为空',
      );
    }
    if (normalizedRole != 'requester' && normalizedRole != 'provider') {
      return ExperienceUdpHolePunchResult.failed(
        sessionId: sessionId,
        peerId: normalizedPeerId,
        role: normalizedRole,
        message: 'role 必须是 requester 或 provider',
      );
    }
    if (validRemotes.isEmpty) {
      return ExperienceUdpHolePunchResult.failed(
        sessionId: sessionId,
        peerId: normalizedPeerId,
        role: normalizedRole,
        message: '没有可用的 UDP 候选端点',
      );
    }
    if (session.expiresAt != null &&
        !session.expiresAt!.toUtc().isAfter(DateTime.now().toUtc())) {
      return ExperienceUdpHolePunchResult.failed(
        sessionId: sessionId,
        peerId: normalizedPeerId,
        role: normalizedRole,
        message: 'hole-punch session 已过期',
      );
    }

    final deadline = DateTime.now().toUtc().add(timeout ?? this.timeout);
    final interval = probeInterval ?? this.probeInterval;
    final hasIPv6 = validRemotes.any((endpoint) => endpoint.isIPv6);
    final hasIPv4 = validRemotes.any((endpoint) => endpoint.isIPv4);
    final families = <InternetAddressType>[
      if (hasIPv4 || !hasIPv6) InternetAddressType.IPv4,
      if (hasIPv6) InternetAddressType.IPv6,
    ];
    final sockets = <_BoundUdpSocket>[];
    final subscriptions = <StreamSubscription<RawSocketEvent>>[];
    final sentCounts = <String, int>{};
    final result = Completer<ExperienceUdpHolePunchResult>();
    try {
      for (final family in families) {
        final bindAddress = family == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4;
        final socket = await RawDatagramSocket.bind(
          bindAddress,
          0,
          reuseAddress: true,
        );
        sockets.add(_BoundUdpSocket(socket, family));
      }

      final localEndpoints = sockets
          .map(
            (bundle) => ExperienceNetworkEndpoint(
              network: 'udp',
              host: bundle.socket.address.host,
              port: bundle.socket.port,
            ),
          )
          .toList(growable: false);

      void complete(ExperienceUdpHolePunchResult value) {
        if (!result.isCompleted) {
          result.complete(value);
        }
      }

      Future<void> sendProbeRound() async {
        for (final remote in validRemotes) {
          final bundle = _socketForRemote(sockets, remote);
          if (bundle == null) continue;
          final packet = _buildPacket(
            sessionId: sessionId,
            punchToken: punchToken,
            peerId: normalizedPeerId,
            role: normalizedRole,
            kind: 'probe',
          );
          final sent = bundle.socket.send(
            utf8.encode(jsonEncode(packet)),
            InternetAddress.tryParse(remote.host) ??
                InternetAddress(remote.host),
            remote.port,
          );
          if (sent > 0) {
            sentCounts[remote.host] = (sentCounts[remote.host] ?? 0) + 1;
          }
        }
      }

      for (final bundle in sockets) {
        bundle.socket.readEventsEnabled = true;
        bundle.socket.writeEventsEnabled = true;
        subscriptions.add(
          bundle.socket.listen(
            (event) {
              if (event != RawSocketEvent.read || result.isCompleted) return;
              while (true) {
                final datagram = bundle.socket.receive();
                if (datagram == null) break;
                final payload = _decodePacket(datagram.data);
                if (payload == null) continue;
                if (payload['schema_version']?.toString() !=
                    _kUdpPunchSchemaVersion) {
                  continue;
                }
                if (payload['session_id']?.toString() != sessionId) continue;
                if (payload['punch_token']?.toString() != punchToken) continue;
                final remotePeerId = payload['peer_id']?.toString() ?? '';
                if (remotePeerId.isEmpty || remotePeerId == normalizedPeerId) {
                  continue;
                }
                final remoteRole = payload['role']?.toString() ?? '';
                final kind = payload['kind']?.toString() ?? 'probe';
                final observedEndpoint = ExperienceNetworkEndpoint(
                  network: 'udp',
                  host: datagram.address.host,
                  port: datagram.port,
                );
                if (kind == 'probe') {
                  final ack = utf8.encode(
                    jsonEncode(
                      _buildPacket(
                        sessionId: sessionId,
                        punchToken: punchToken,
                        peerId: normalizedPeerId,
                        role: normalizedRole,
                        kind: 'ack',
                      ),
                    ),
                  );
                  bundle.socket.send(ack, datagram.address, datagram.port);
                }
                complete(
                  ExperienceUdpHolePunchResult.succeeded(
                    sessionId: sessionId,
                    peerId: normalizedPeerId,
                    role: normalizedRole,
                    observedEndpoint: observedEndpoint,
                    localEndpoints: localEndpoints,
                    probesSent: sentCounts.values.fold(
                      0,
                      (sum, value) => sum + value,
                    ),
                    message: remoteRole.isEmpty
                        ? 'UDP punch succeeded'
                        : 'UDP punch succeeded via $remoteRole',
                  ),
                );
                return;
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              complete(
                ExperienceUdpHolePunchResult.failed(
                  sessionId: sessionId,
                  peerId: normalizedPeerId,
                  role: normalizedRole,
                  localEndpoints: localEndpoints,
                  probesSent: sentCounts.values.fold(
                    0,
                    (sum, value) => sum + value,
                  ),
                  message: 'UDP socket error: $error',
                ),
              );
            },
          ),
        );
      }

      await sendProbeRound();
      while (!result.isCompleted && DateTime.now().toUtc().isBefore(deadline)) {
        final remaining = deadline.difference(DateTime.now().toUtc());
        await Future.any([
          result.future,
          Future<void>.delayed(remaining < interval ? remaining : interval),
        ]);
        if (result.isCompleted) break;
        await sendProbeRound();
      }

      if (result.isCompleted) return result.future;
      return ExperienceUdpHolePunchResult.failed(
        sessionId: sessionId,
        peerId: normalizedPeerId,
        role: normalizedRole,
        localEndpoints: localEndpoints,
        probesSent: sentCounts.values.fold(0, (sum, value) => sum + value),
        message: 'UDP punch timeout',
      );
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      for (final bundle in sockets) {
        bundle.socket.close();
      }
    }
  }

  Map<String, dynamic> _buildPacket({
    required String sessionId,
    required String punchToken,
    required String peerId,
    required String role,
    required String kind,
  }) {
    return {
      'schema_version': _kUdpPunchSchemaVersion,
      'session_id': sessionId,
      'punch_token': punchToken,
      'peer_id': peerId,
      'role': role,
      'kind': kind,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic>? _decodePacket(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  _BoundUdpSocket? _socketForRemote(
    List<_BoundUdpSocket> sockets,
    ExperienceNetworkEndpoint remote,
  ) {
    final family = remote.isIPv6
        ? InternetAddressType.IPv6
        : InternetAddressType.IPv4;
    for (final bundle in sockets) {
      if (bundle.family == family) return bundle;
    }
    return sockets.isEmpty ? null : sockets.first;
  }
}

class ExperienceUdpHolePunchResult {
  const ExperienceUdpHolePunchResult._({
    required this.sessionId,
    required this.peerId,
    required this.role,
    required this.result,
    required this.message,
    this.observedEndpoint,
    this.localEndpoints = const [],
    this.probesSent = 0,
  });

  factory ExperienceUdpHolePunchResult.succeeded({
    required String sessionId,
    required String peerId,
    required String role,
    required ExperienceNetworkEndpoint observedEndpoint,
    List<ExperienceNetworkEndpoint> localEndpoints = const [],
    int probesSent = 0,
    String message = 'UDP punch succeeded',
  }) => ExperienceUdpHolePunchResult._(
    sessionId: sessionId,
    peerId: peerId,
    role: role,
    result: 'succeeded',
    message: message,
    observedEndpoint: observedEndpoint,
    localEndpoints: localEndpoints,
    probesSent: probesSent,
  );

  factory ExperienceUdpHolePunchResult.failed({
    required String sessionId,
    required String peerId,
    required String role,
    List<ExperienceNetworkEndpoint> localEndpoints = const [],
    int probesSent = 0,
    String message = 'UDP punch failed',
  }) => ExperienceUdpHolePunchResult._(
    sessionId: sessionId,
    peerId: peerId,
    role: role,
    result: 'failed',
    message: message,
    localEndpoints: localEndpoints,
    probesSent: probesSent,
  );

  final String sessionId;
  final String peerId;
  final String role;
  final String result;
  final String message;
  final ExperienceNetworkEndpoint? observedEndpoint;
  final List<ExperienceNetworkEndpoint> localEndpoints;
  final int probesSent;

  bool get ok => result == 'succeeded';

  ExperienceDhtHolePunchReport toReport({DateTime? now}) {
    return ExperienceDhtHolePunchReport(
      peerId: peerId,
      role: role,
      result: result,
      observedEndpoint: observedEndpoint,
      localEndpoints: localEndpoints,
      message: message,
      updatedAt: now ?? DateTime.now().toUtc(),
    );
  }
}

class _BoundUdpSocket {
  const _BoundUdpSocket(this.socket, this.family);

  final RawDatagramSocket socket;
  final InternetAddressType family;
}
