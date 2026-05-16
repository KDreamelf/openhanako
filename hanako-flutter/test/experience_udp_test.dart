import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/experience/experience.dart';

void main() {
  test('UDP 打洞执行器可通过本地回环完成 probe/ack 握手', () async {
    final responder = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(responder.close);

    final seenProbe = Completer<void>();
    responder.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final datagram = responder.receive();
        if (datagram == null) break;
        final payload =
            jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
        expect(payload['schema_version'], 'ph01.experience.hole_punch_udp.v1');
        expect(payload['session_id'], 'hp_1');
        expect(payload['punch_token'], 'token_1');
        expect(payload['kind'], 'probe');
        final ack = {
          ...payload,
          'kind': 'ack',
          'peer_id': 'peer_provider',
          'role': 'provider',
        };
        responder.send(
          utf8.encode(jsonEncode(ack)),
          datagram.address,
          datagram.port,
        );
        if (!seenProbe.isCompleted) {
          seenProbe.complete();
        }
      }
    });

    final puncher = ExperienceUdpHolePuncher(
      timeout: const Duration(seconds: 2),
      probeInterval: const Duration(milliseconds: 50),
    );
    final session = ExperienceDhtHolePunchSession(
      sessionId: 'hp_1',
      requestId: 'req_1',
      packageHash: 'sha256:abc',
      requesterPeerId: 'peer_requester',
      requesterAddrs: const [],
      providerPeerId: 'peer_provider',
      providerAddrs: [
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '127.0.0.1',
          port: responder.port,
        ),
      ],
      punchToken: 'token_1',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      status: 'open',
    );

    final result = await puncher.punch(
      session: session,
      peerId: 'peer_requester',
      role: 'requester',
      remoteEndpoints: session.providerAddrs,
    );
    await seenProbe.future;

    expect(result.ok, isTrue);
    expect(result.result, 'succeeded');
    expect(result.observedEndpoint?.host, '127.0.0.1');
    expect(result.probesSent, greaterThan(0));
    expect(result.toReport().result, 'succeeded');
  });

  test('UDP 打洞执行器在无回应时超时失败', () async {
    final probeSocket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final unusedPort = probeSocket.port;
    probeSocket.close();

    final puncher = ExperienceUdpHolePuncher(
      timeout: const Duration(milliseconds: 250),
      probeInterval: const Duration(milliseconds: 50),
    );
    final session = ExperienceDhtHolePunchSession(
      sessionId: 'hp_2',
      requestId: 'req_2',
      packageHash: 'sha256:def',
      requesterPeerId: 'peer_requester',
      requesterAddrs: const [],
      providerPeerId: 'peer_provider',
      providerAddrs: [
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '127.0.0.1',
          port: unusedPort,
        ),
      ],
      punchToken: 'token_2',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      status: 'open',
    );

    final result = await puncher.punch(
      session: session,
      peerId: 'peer_requester',
      role: 'requester',
      remoteEndpoints: session.providerAddrs,
    );

    expect(result.ok, isFalse);
    expect(result.result, 'failed');
    expect(result.message, contains('timeout'));
  });
}
