import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/experience/experience.dart';
import 'package:hanako/identity/keypair.dart';

void main() {
  test('连接策略优先 IPv6 直连，然后 IPv4，最后 DHT 和管理端兜底', () {
    final planner = ExperienceConnectionPlanner();
    final attempts = planner.plan(
      requesterPeerId: 'peer_requester',
      provider: const ExperiencePeerCandidate(
        peerId: 'peer_provider',
        endpoints: [
          ExperienceNetworkEndpoint(
            network: 'tcp',
            host: '198.51.100.20',
            port: 41002,
            requiresHolePunch: true,
          ),
          ExperienceNetworkEndpoint(
            network: 'tcp',
            host: '2001:db8::20',
            port: 41002,
          ),
        ],
      ),
      dhtNodes: [_publicDht('dht_public', load: const ExperienceDhtLoad())],
      now: DateTime.utc(2026, 5, 9),
    );

    expect(attempts.map((item) => item.transport).toList(), [
      ExperienceTransport.ipv6Direct,
      ExperienceTransport.ipv4HolePunch,
      ExperienceTransport.dhtRelay,
      ExperienceTransport.managerSeed,
    ]);
    expect(attempts.first.endpoint?.host, '2001:db8::20');
  });

  test('过期或 unhealthy 的公共 DHT 不参与 relay 候选', () {
    final planner = ExperienceConnectionPlanner();
    final attempts = planner.plan(
      requesterPeerId: 'peer_requester',
      provider: const ExperiencePeerCandidate(peerId: 'peer_provider'),
      dhtNodes: [
        _publicDht('expired', expiresAt: DateTime.utc(2026, 5, 8)),
        _publicDht('bad', healthStatus: ExperienceDhtHealthStatus.unhealthy),
      ],
      now: DateTime.utc(2026, 5, 9),
    );

    expect(attempts.map((item) => item.transport).toList(), [
      ExperienceTransport.managerSeed,
    ]);
  });

  test('私有 DHT owner_only 只允许自己或所属用户参与 relay', () {
    final privateDht = ExperienceDhtNode(
      nodeId: 'private_dht',
      ownerKind: ExperienceDhtOwnerKind.user,
      ownerPeerId: 'owner_peer',
      dhtPeerId: 'dht_peer',
      endpoints: const [
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '203.0.113.8',
          port: 41001,
        ),
      ],
      relayPolicy: ExperienceRelayPolicy.ownerOnly,
      capabilities: const {'relay': true, 'hole_punch': true},
      expiresAt: DateTime.utc(2026, 5, 10),
    );

    expect(
      privateDht.canRelayBetween(
        requesterPeerId: 'owner_peer',
        providerPeerId: 'other_peer',
      ),
      isTrue,
    );
    expect(
      privateDht.canRelayBetween(
        requesterPeerId: 'alice_peer',
        providerPeerId: 'bob_peer',
      ),
      isFalse,
    );
  });

  test('私有 DHT 不能以其他用户身份外发', () {
    final privateDht = ExperienceDhtNode(
      nodeId: 'private_dht',
      ownerPeerId: 'owner_peer',
      dhtPeerId: 'dht_peer',
      relayPolicy: ExperienceRelayPolicy.ownerOnly,
    );

    expect(privateDht.canSendAs('owner_peer'), isTrue);
    expect(privateDht.canSendAs('dht_peer'), isTrue);
    expect(privateDht.canSendAs('other_peer'), isFalse);
  });

  test('DHT 节点与客户端私有配置 JSON 字段保持协议形状', () {
    final node = _publicDht('dht_json').toJson();
    expect(node['schema_version'], 'ph01.experience.dht_node.v1');
    expect(node['node_id'], 'dht_json');
    expect(node['relay_policy'], 'public');
    expect(node['endpoints'], isA<List>());

    const config = ExperienceDhtClientConfig(
      mode: 'custom_private',
      candidateEndpoints: [
        ExperienceNetworkEndpoint(
          network: 'quic',
          host: '203.0.113.9',
          port: 41002,
        ),
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '203.0.113.9',
          port: 41001,
        ),
      ],
      managerBaseUrl: 'https://experience.test',
      adminBaseUrl: 'https://dht.test',
    );
    expect(config.toJson().containsKey('manager_base_url'), isFalse);
    final decoded = ExperienceDhtClientConfig.fromJson(config.toJson());
    expect(decoded.isCustomPrivate, isTrue);
    expect(decoded.relayPolicy, ExperienceRelayPolicy.ownerOnly);
    expect(decoded.effectiveCandidateEndpoints.length, 2);
    expect(decoded.effectiveCandidateEndpoints.first.network, 'quic');
    expect(decoded.effectiveCandidateEndpoints.last.network, 'udp');
    expect(decoded.effectiveCandidateEndpoints.last.host, '203.0.113.9');
    expect(decoded.managerBaseUrl, isEmpty);
    expect(decoded.adminBaseUrl, 'https://dht.test');

    const runtimeConfig = ExperienceDhtRuntimeConfig(
      publicApiBaseUrl: 'https://dht.test',
      candidateEndpoints: [
        ExperienceNetworkEndpoint(
          network: 'quic',
          host: '203.0.113.9',
          port: 41002,
        ),
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '203.0.113.9',
          port: 41001,
        ),
      ],
    );
    final runtimeJson = runtimeConfig.toJson();
    final runtimeEndpoints = runtimeJson['candidate_endpoints'] as List;
    expect(runtimeEndpoints.length, 2);
    expect(runtimeEndpoints.first['network'], 'quic');
    expect(runtimeJson['public_network'], 'udp');
    expect(runtimeJson['public_port'], 41001);
  });

  test('客户端可绑定、查询并切换 DHT 管理状态', () async {
    final keyPair = HanakoKeyPair.generate();
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/admin/bind') {
        final body = await _readJsonBody(requestStream);
        expect(body['init_password'], 'init_secret');
        expect(body['pubkey_hex'], keyPair.publicKeyHex);
        expect(body['manager_base_url'], 'https://experience.test');
        final runtime = body['runtime_config'] as Map<String, dynamic>;
        expect(runtime['public_api_base_url'], 'https://dht.test');
        expect(runtime['public_network'], 'udp');
        expect(runtime['public_host'], '203.0.113.20');
        expect(runtime['public_port'], 41001);
        expect(runtime['relay_policy'], 'owner_only');
        return ResponseBody.fromString(
          jsonEncode({
            'state': _adminStateJson(
              keyPair.publicKeyHex,
              publicEnabled: false,
              publicRegistered: false,
              bootstrapManagerBaseUrl: 'https://experience.test',
            ),
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/admin/status') {
        final envelope = await _readJsonBody(requestStream);
        expect(envelope['pubkey'], keyPair.publicKeyHex);
        expect(envelope['signature'], isA<String>());
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        expect(payload['op'], 'status');
        return ResponseBody.fromString(
          jsonEncode({
            'state': _adminStateJson(
              keyPair.publicKeyHex,
              publicEnabled: false,
              publicRegistered: false,
            ),
            'bound_pubkey': keyPair.publicKeyHex,
            'bound_hash': 'hash_1',
            'public_config': _publicDht('dht_admin').toJson(),
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/admin/config') {
        final envelope = await _readJsonBody(requestStream);
        expect(envelope['pubkey'], keyPair.publicKeyHex);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        final runtime = payload['runtime_config'] as Map<String, dynamic>;
        expect(runtime['public_api_base_url'], 'https://dht.test');
        expect(runtime['public_host'], '203.0.113.20');
        return ResponseBody.fromString(
          jsonEncode({
            'state': _adminStateJson(
              keyPair.publicKeyHex,
              publicEnabled: false,
              publicRegistered: false,
            ),
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      expect(options.method, 'POST');
      expect(options.uri.path, '/api/v1/admin/public');
      final envelope = await _readJsonBody(requestStream);
      expect(envelope['pubkey'], keyPair.publicKeyHex);
      final payload =
          jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
      expect(payload['enabled'], isTrue);
      expect(payload['manager_base_url'], 'https://experience.test');
      return ResponseBody.fromString(
        jsonEncode({
          'state': _adminStateJson(
            keyPair.publicKeyHex,
            publicEnabled: true,
            publicRegistered: true,
            publicManagerBaseUrl: 'https://experience.test',
          ),
          'node': _publicDht('dht_admin').toJson(),
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceDhtHttpClient(
      dhtBaseUrl: 'https://dht.test/',
      dio: dio,
    );

    final bound = await client.bindAdmin(
      initPassword: ' init_secret ',
      pubkeyHex: ' ${keyPair.publicKeyHex} ',
      managerBaseUrl: ' https://experience.test ',
      runtimeConfig: const ExperienceDhtRuntimeConfig(
        publicApiBaseUrl: ' https://dht.test ',
        endpoint: ExperienceNetworkEndpoint(
          network: 'udp',
          host: '203.0.113.20',
          port: 41001,
        ),
        relayPolicy: ExperienceRelayPolicy.ownerOnly,
      ),
    );
    final status = await client.fetchAdminStatus(keyPair: keyPair);
    await client.setRuntimeConfig(
      keyPair: keyPair,
      runtimeConfig: const ExperienceDhtRuntimeConfig(
        publicApiBaseUrl: 'https://dht.test',
        endpoint: ExperienceNetworkEndpoint(
          network: 'udp',
          host: '203.0.113.20',
          port: 41001,
        ),
        relayPolicy: ExperienceRelayPolicy.ownerOnly,
      ),
    );
    final publicMode = await client.setPublicMode(
      enabled: true,
      keyPair: keyPair,
      managerBaseUrl: ' https://experience.test ',
    );

    expect(bound.bound, isTrue);
    expect(bound.publicEnabled, isFalse);
    expect(bound.bootstrapManagerBaseUrl, 'https://experience.test');
    expect(status.boundHash, 'hash_1');
    expect(status.publicConfig?.nodeId, 'dht_admin');
    expect(publicMode.state.publicEnabled, isTrue);
    expect(publicMode.state.publicRegistered, isTrue);
    expect(publicMode.state.publicManagerBaseUrl, 'https://experience.test');
    expect(publicMode.node?.nodeId, 'dht_admin');
  });

  test('客户端从管理端拉取公共 DHT 列表并过滤不可用节点', () async {
    final dio = Dio();
    dio.httpClientAdapter = _StaticAdapter((options) async {
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/dht/nodes');
      return ResponseBody.fromString(
        jsonEncode({
          'items': [
            _publicDht('usable').toJson(),
            _publicDht('expired', expiresAt: DateTime.utc(2026, 5, 8)).toJson(),
            _publicDht(
              'bad',
              healthStatus: ExperienceDhtHealthStatus.unhealthy,
            ).toJson(),
            const ExperienceDhtNode(
              nodeId: 'owner_only',
              relayPolicy: ExperienceRelayPolicy.ownerOnly,
              healthStatus: ExperienceDhtHealthStatus.unhealthy,
              endpoints: [
                ExperienceNetworkEndpoint(
                  network: 'udp',
                  host: '203.0.113.20',
                  port: 41001,
                ),
              ],
            ).toJson(),
          ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceNetworkManagerClient(
      managerBaseUrl: 'https://experience.test/',
      dio: dio,
    );

    final nodes = await client.fetchPublicDhtNodes(
      now: DateTime.utc(2026, 5, 9),
    );

    expect(nodes.map((item) => item.nodeId).toList(), ['usable']);
  });

  test('DHT 节点可从 HTTP endpoint 推导 API base URL', () {
    const node = ExperienceDhtNode(
      nodeId: 'dht_api',
      endpoints: [
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '198.51.100.10',
          port: 41001,
        ),
        ExperienceNetworkEndpoint(
          network: 'https',
          host: 'dht.test',
          port: 443,
        ),
      ],
    );

    expect(node.apiBaseUrl, 'https://dht.test:443');
  });

  test('经验网络状态探测会拉取管理端 DHT 并统计可连接节点与网络模式', () async {
    final liveNode = ExperienceDhtNode(
      nodeId: 'dht_live',
      endpoints: const [
        ExperienceNetworkEndpoint(
          network: 'https',
          host: 'dht.test',
          port: 8091,
        ),
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '2001:db8::10',
          port: 41001,
        ),
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '198.51.100.10',
          port: 41001,
          requiresHolePunch: true,
        ),
      ],
      capabilities: const {'relay': true, 'hole_punch': true},
      relayPolicy: ExperienceRelayPolicy.public,
      expiresAt: DateTime.utc(2026, 5, 10),
    );
    final dio = Dio();
    dio.httpClientAdapter = _StaticAdapter((options) async {
      if (options.uri.host == 'experience.test') {
        expect(options.method, 'GET');
        expect(options.uri.path, '/api/v1/dht/nodes');
        return ResponseBody.fromString(
          jsonEncode({
            'items': [liveNode.toJson()],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      expect(options.method, 'GET');
      expect(options.uri.host, 'dht.test');
      expect(options.uri.path, '/healthz');
      return ResponseBody.fromString(
        jsonEncode({'ok': true, 'service': 'experience-dht'}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final probe = ExperienceNetworkStatusProbe(
      config: const ExperienceDhtClientConfig(
        managerBaseUrl: 'https://attacker.test',
      ),
      fallbackManagerBaseUrl: 'https://experience.test',
      dio: dio,
      localNetworkStateProvider: () async =>
          const ExperienceLocalNetworkState(hasIPv4: true, hasIPv6: true),
    );

    final status = await probe.probe(now: DateTime.utc(2026, 5, 9));

    expect(status.publicDhtCount, 1);
    expect(status.managerBaseUrl, 'https://experience.test');
    expect(status.connectedDhtCount, 1);
    expect(status.ipv6Status, ExperienceNetworkPathStatus.direct);
    expect(status.ipv4Status, ExperienceNetworkPathStatus.holePunchable);
    expect(status.bestModeLabel, 'IPv6 可以直连');
  });

  test('状态探测按已连接 DHT 显示最优 IPv4 打洞环境', () async {
    final nodes = List.generate(10, (index) {
      return ExperienceDhtNode(
        nodeId: 'dht_$index',
        endpoints: [
          ExperienceNetworkEndpoint(
            network: 'https',
            host: 'dht$index.test',
            port: 8091,
          ),
          const ExperienceNetworkEndpoint(
            network: 'udp',
            host: '198.51.100.10',
            port: 41001,
            requiresHolePunch: true,
          ),
        ],
        capabilities: const {'hole_punch': true},
        relayPolicy: ExperienceRelayPolicy.public,
        expiresAt: DateTime.utc(2026, 5, 10),
      );
    });
    final dio = Dio();
    dio.httpClientAdapter = _StaticAdapter((options) async {
      if (options.uri.host == 'experience.test') {
        return ResponseBody.fromString(
          jsonEncode({'items': nodes.map((node) => node.toJson()).toList()}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      final ok =
          options.uri.host == 'dht0.test' || options.uri.host == 'dht1.test';
      return ResponseBody.fromString(
        jsonEncode({'ok': ok, 'service': 'experience-dht'}),
        ok ? 200 : 503,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final probe = ExperienceNetworkStatusProbe(
      config: const ExperienceDhtClientConfig(
        managerBaseUrl: 'https://attacker.test',
      ),
      fallbackManagerBaseUrl: 'https://experience.test',
      dio: dio,
      localNetworkStateProvider: () async =>
          const ExperienceLocalNetworkState(hasIPv4: true, hasIPv6: false),
    );

    final status = await probe.probe(now: DateTime.utc(2026, 5, 9));

    expect(status.configuredDhtCount, 10);
    expect(status.connectedDhtCount, 2);
    expect(status.ipv6Status, ExperienceNetworkPathStatus.unavailable);
    expect(status.ipv4Status, ExperienceNetworkPathStatus.holePunchable);
    expect(status.bestModeLabel, 'IPv4 打洞成功');
  });

  test('客户端可从管理端只取回审核签名材料', () async {
    final dio = Dio();
    dio.httpClientAdapter = _StaticAdapter((options) async {
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/experiences/exp_1/review-materials');
      return ResponseBody.fromString(
        jsonEncode({
          'schema_version': 'ph01.experience.review_materials.v1',
          'root_key_id': 'test-root',
          'signature_algorithm': ExperiencePublisher.algorithm,
          'signature_payload_sha256': 'abc',
          'manager_review_signature': 'def',
          'signature_payload': {'experience_id': 'exp_1'},
          'manager_certificate': {'certificate': {}},
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceNetworkManagerClient(
      managerBaseUrl: 'https://experience.test/',
      dio: dio,
    );

    final materials = await client.fetchReviewMaterials(experienceId: 'exp_1');

    expect(materials.schemaVersion, 'ph01.experience.review_materials.v1');
    expect(materials.signaturePayload['experience_id'], 'exp_1');
  });

  test('客户端可从管理端下载完整经验包', () async {
    final dio = Dio();
    dio.httpClientAdapter = _StaticAdapter((options) async {
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/experiences/exp_1/package');
      return ResponseBody.fromBytes(
        [1, 2, 3],
        200,
        headers: {
          Headers.contentTypeHeader: ['application/zip'],
        },
      );
    });
    final client = ExperienceNetworkManagerClient(
      managerBaseUrl: 'https://experience.test/',
      dio: dio,
    );

    final bytes = await client.fetchPackage(experienceId: 'exp_1');

    expect(bytes, [1, 2, 3]);
  });

  test('客户端先向经验管理端申请包级 PoW challenge id', () async {
    final keyPair = HanakoKeyPair.generate();
    final packageHash = sha256.convert([1, 2, 3, 4]).toString();
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      expect(options.method, 'POST');
      expect(options.uri.path, '/api/v1/experiences/package-pow/challenge');
      final body = await _readJsonBody(requestStream);
      expect(body['package_sha256'], packageHash);
      expect(body['pubkey_hash'], keyPair.publicKeyHash);
      return ResponseBody.fromString(
        jsonEncode({'challenge_id': 'pow_ch_1', 'expires_at': 1770000000}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceNetworkManagerClient(
      managerBaseUrl: 'https://experience.test/',
      dio: dio,
    );

    final challenge = await client.startPackagePowChallenge(
      experienceId: 'exp_1',
      packageSha256: packageHash,
      pubkeyHash: keyPair.publicKeyHash,
    );

    expect(challenge.challengeId, 'pow_ch_1');
    expect(challenge.expiresAt, 1770000000);
  });

  test('经验管理端错误会保留 HTTP 状态与 JSON 错误正文', () async {
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      await _readJsonBody(requestStream);
      return ResponseBody.fromString(
        jsonEncode({
          'error': 'experience_pow_challenge_failed',
          'message': 'auth_center.base_url is required',
        }),
        502,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceNetworkManagerClient(
      managerBaseUrl: 'https://experience.test/',
      dio: dio,
    );

    await expectLater(
      client.startPackagePowChallenge(
        experienceId: 'exp_1',
        packageSha256: 'a' * 64,
        pubkeyHash: 'b' * 64,
      ),
      throwsA(
        isA<ExperienceNetworkRequestException>()
            .having((e) => e.statusCode, 'statusCode', 502)
            .having(
              (e) => e.errorCode,
              'errorCode',
              'experience_pow_challenge_failed',
            )
            .having(
              (e) => e.message,
              'message',
              'auth_center.base_url is required',
            ),
      ),
    );
  });

  test('申请包级 PoW 时管理端重复提审响应会转为已提交异常', () async {
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      final body = await _readJsonBody(requestStream);
      expect(body['experience_id'], 'exp_1');
      return ResponseBody.fromString(
        jsonEncode({
          'error': 'experience_already_submitted',
          'message': 'experience already submitted',
          'already_submitted': true,
          'experience_id': 'exp_1',
          'status': 'inbox',
        }),
        409,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceNetworkManagerClient(
      managerBaseUrl: 'https://experience.test/',
      dio: dio,
    );

    await expectLater(
      client.startPackagePowChallenge(
        experienceId: 'exp_1',
        packageSha256: 'a' * 64,
        pubkeyHash: 'b' * 64,
      ),
      throwsA(
        isA<ExperienceAlreadySubmittedException>()
            .having((e) => e.result.experienceId, 'experienceId', 'exp_1')
            .having((e) => e.result.pendingReview, 'pendingReview', true),
      ),
    );
  });

  test('取回审核材料 404 会转为可识别的经验网络异常', () async {
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/experiences/exp_1/review-materials');
      return ResponseBody.fromString(
        jsonEncode({'error': 'not_found', 'message': ''}),
        404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceNetworkManagerClient(
      managerBaseUrl: 'https://experience.test/',
      dio: dio,
    );

    await expectLater(
      client.fetchReviewMaterials(experienceId: 'exp_1'),
      throwsA(
        isA<ExperienceNetworkRequestException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.errorCode, 'errorCode', 'not_found'),
      ),
    );
  });

  test('客户端普通用户提审使用 PH01 SignedRequest 上传经验包', () async {
    final keyPair = HanakoKeyPair.generate();
    final packageBytes = Uint8List.fromList([1, 2, 3, 4]);
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      expect(options.method, 'POST');
      expect(options.uri.path, '/api/v1/experiences');
      expect(options.contentType, Headers.jsonContentType);
      final envelope = await _readJsonBody(requestStream);
      expect(envelope['pubkey'], keyPair.publicKeyHex);
      expect(envelope['signature'], isA<String>());
      final payload =
          jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
      expect(payload['schema_version'], 'ph01.experience.upload.v1');
      expect(payload['filename'], 'exp_1.hxp');
      expect(payload['package_base64'], base64Encode(packageBytes));
      expect(
        payload['package_sha256'],
        sha256.convert(packageBytes).toString(),
      );
      expect(payload['package_pow'], {
        'challenge_id': 'pow_exp_1',
        'package_sha256': sha256.convert(packageBytes).toString(),
        'pubkey_hash': keyPair.publicKeyHash,
      });
      return ResponseBody.fromString(
        jsonEncode({
          'experience_id': 'exp_1',
          'title': '经验 1',
          'status': 'inbox',
          'path': 'inbox/exp_1',
          'package_path': 'inbox/exp_1/package.hxp',
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceNetworkManagerClient(
      managerBaseUrl: 'https://experience.test/',
      dio: dio,
    );

    final result = await client.submitPackageForReview(
      packageBytes: packageBytes,
      keyPair: keyPair,
      packagePow: ExperiencePackagePowProof(
        challengeId: 'pow_exp_1',
        packageSha256: sha256.convert(packageBytes).toString(),
        pubkeyHash: keyPair.publicKeyHash,
      ),
      filename: 'exp_1.hxp',
    );

    expect(result.experienceId, 'exp_1');
    expect(result.pendingReview, isTrue);
    expect(result.approved, isFalse);
  });

  test('管理端拒绝重复提审时客户端返回可同步的已提交状态', () async {
    final keyPair = HanakoKeyPair.generate();
    final packageBytes = Uint8List.fromList([1, 2, 3, 4]);
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      expect(options.method, 'POST');
      expect(options.uri.path, '/api/v1/experiences');
      return ResponseBody.fromString(
        jsonEncode({
          'error': 'experience_already_submitted',
          'message': 'experience already submitted',
          'already_submitted': true,
          'experience_id': 'exp_1',
          'title': '经验 1',
          'status': 'inbox',
          'path': 'inbox/exp_1',
          'package_path': 'packages/exp_1.hxp',
        }),
        409,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceNetworkManagerClient(
      managerBaseUrl: 'https://experience.test/',
      dio: dio,
    );

    final result = await client.submitPackageForReview(
      packageBytes: packageBytes,
      keyPair: keyPair,
      packagePow: ExperiencePackagePowProof(
        challengeId: 'pow_exp_1',
        packageSha256: sha256.convert(packageBytes).toString(),
        pubkeyHash: keyPair.publicKeyHash,
      ),
      filename: 'exp_1.hxp',
    );

    expect(result.alreadySubmitted, isTrue);
    expect(result.experienceId, 'exp_1');
    expect(result.pendingReview, isTrue);
  });

  test('DHT presence 与 provider record JSON 保持协议字段', () {
    const presence = ExperienceDhtPresence(
      peerId: 'peer_owner',
      ownerPeerId: 'owner_1',
      endpoints: [
        ExperienceNetworkEndpoint(
          network: 'tcp',
          host: '2001:db8::2',
          port: 41002,
        ),
      ],
      packageHashes: ['sha256:abc'],
      ttlSeconds: 60,
    );

    final json = presence.toJson();
    expect(json['peer_id'], 'peer_owner');
    expect(json['owner_peer_id'], 'owner_1');
    expect(json['package_hashes'], ['sha256:abc']);
    expect(json['ttl_seconds'], 60);

    final record = ExperienceDhtProviderRecord.fromJson({
      'peer_id': 'peer_owner',
      'owner_peer_id': 'owner_1',
      'endpoints': [
        {
          'network': 'tcp',
          'host': '198.51.100.2',
          'port': 41002,
          'requires_hole_punch': true,
        },
      ],
      'package_hashes': ['sha256:abc'],
      'expires_at': '2026-05-09T10:00:00Z',
      'updated_at': '2026-05-09T09:55:00Z',
    });

    expect(record.peerId, 'peer_owner');
    expect(record.toPeerCandidate().endpoints.single.requiresHolePunch, isTrue);
    expect(record.expiresAt, DateTime.utc(2026, 5, 9, 10));
  });

  test('客户端向 DHT 上报 presence 时使用 PH01 SignedRequest 包裹', () async {
    final keyPair = HanakoKeyPair.generate();
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      expect(options.method, 'POST');
      expect(options.uri.path, '/api/v1/peers/presence');
      final envelope = await _readJsonBody(requestStream);
      expect(envelope['pubkey'], keyPair.publicKeyHex);
      expect(envelope['signature'], isA<String>());
      expect(envelope['payload'], isA<String>());

      final payload =
          jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
      expect(payload['peer_id'], 'peer_owner');
      expect(payload['package_hashes'], ['sha256:abc']);

      return ResponseBody.fromString(
        jsonEncode({
          'peer_id': 'peer_owner',
          'endpoints': [
            {'network': 'tcp', 'host': '2001:db8::2', 'port': 41002},
          ],
          'package_hashes': ['sha256:abc'],
          'expires_at': '2026-05-09T10:00:00Z',
          'updated_at': '2026-05-09T09:55:00Z',
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceDhtHttpClient(
      dhtBaseUrl: 'https://dht.test/',
      dio: dio,
    );

    final record = await client.announcePresence(
      keyPair: keyPair,
      presence: const ExperienceDhtPresence(
        peerId: 'peer_owner',
        endpoints: [
          ExperienceNetworkEndpoint(
            network: 'tcp',
            host: '2001:db8::2',
            port: 41002,
          ),
        ],
        packageHashes: ['sha256:abc'],
      ),
    );

    expect(record.peerId, 'peer_owner');
    expect(record.packageHashes, ['sha256:abc']);
  });

  test('客户端可从 DHT 查询 provider 列表并过滤空 peer', () async {
    final dio = Dio();
    dio.httpClientAdapter = _StaticAdapter((options) async {
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/providers');
      expect(options.uri.queryParameters['package_hash'], 'sha256:abc');
      return ResponseBody.fromString(
        jsonEncode({
          'items': [
            {
              'peer_id': 'peer_provider',
              'endpoints': [
                {
                  'network': 'tcp',
                  'host': '198.51.100.2',
                  'port': 41002,
                  'requires_hole_punch': true,
                },
              ],
              'package_hashes': ['sha256:abc'],
              'expires_at': '2026-05-09T10:00:00Z',
              'updated_at': '2026-05-09T09:55:00Z',
            },
            {
              'peer_id': 'expired_peer',
              'endpoints': [
                {'network': 'tcp', 'host': '198.51.100.3', 'port': 41003},
              ],
              'package_hashes': ['sha256:abc'],
              'expires_at': '2026-05-09T08:55:00Z',
              'updated_at': '2026-05-09T08:50:00Z',
            },
            {
              'peer_id': 'no_endpoint',
              'endpoints': [],
              'package_hashes': ['sha256:abc'],
              'expires_at': '2026-05-09T10:00:00Z',
              'updated_at': '2026-05-09T09:55:00Z',
            },
            {
              'peer_id': '',
              'endpoints': [],
              'expires_at': '2026-05-09T10:00:00Z',
              'updated_at': '2026-05-09T09:55:00Z',
            },
          ],
          'total': 4,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceDhtHttpClient(
      dhtBaseUrl: 'https://dht.test/',
      dio: dio,
    );

    final providers = await client.fetchProviders(
      packageHash: 'sha256:abc',
      now: DateTime.utc(2026, 5, 9, 9),
    );

    expect(providers.map((item) => item.peerId).toList(), ['peer_provider']);
    expect(providers.single.endpoints.single.requiresHolePunch, isTrue);
  });

  test('客户端可从 DHT 查询活跃 peer 并过滤不可用记录', () async {
    final dio = Dio();
    dio.httpClientAdapter = _StaticAdapter((options) async {
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/peers');
      expect(options.uri.queryParameters['limit'], '50');
      return ResponseBody.fromString(
        jsonEncode({
          'items': [
            {
              'peer_id': 'peer_active',
              'endpoints': [
                {
                  'network': 'udp',
                  'host': '198.51.100.2',
                  'port': 41002,
                  'requires_hole_punch': true,
                },
              ],
              'package_hashes': ['sha256:abc'],
              'expires_at': '2026-05-09T10:00:00Z',
              'updated_at': '2026-05-09T09:55:00Z',
            },
            {
              'peer_id': 'expired_peer',
              'endpoints': [
                {'network': 'udp', 'host': '198.51.100.3', 'port': 41003},
              ],
              'expires_at': '2026-05-09T08:55:00Z',
              'updated_at': '2026-05-09T08:50:00Z',
            },
            {
              'peer_id': 'no_endpoint',
              'endpoints': [],
              'expires_at': '2026-05-09T10:00:00Z',
              'updated_at': '2026-05-09T09:55:00Z',
            },
            {
              'peer_id': '',
              'endpoints': [
                {'network': 'udp', 'host': '198.51.100.4', 'port': 41004},
              ],
              'expires_at': '2026-05-09T10:00:00Z',
              'updated_at': '2026-05-09T09:55:00Z',
            },
          ],
          'total': 4,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceDhtHttpClient(
      dhtBaseUrl: 'https://dht.test/',
      dio: dio,
    );

    final peers = await client.fetchActivePeers(
      limit: 50,
      now: DateTime.utc(2026, 5, 9, 9),
    );

    expect(peers.map((item) => item.peerId).toList(), ['peer_active']);
    expect(peers.single.endpoints.single.isUdpCandidate, isTrue);
  });

  test('P2P gossip demand 签名可验，篡改查询后失败', () {
    final requester = HanakoKeyPair.generate();
    final demand = P2pDemandPacket(
      demandId: 'dem_p2p',
      requesterPubKey: requester.publicKeyHex,
      signature: '',
      query: '窗口自动化经验',
      tags: const ['窗口', '自动化'],
      maxResponses: 2,
      createdAt: DateTime.utc(2026, 5, 9, 9).millisecondsSinceEpoch,
    )..signWith(requester);

    final decoded = P2pDemandPacket.fromJson(demand.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.signature, isNotEmpty);
    expect(decoded.verifySignature(), isTrue);

    final tamperedJson = Map<String, dynamic>.from(demand.toJson())
      ..['query'] = '别的查询';
    final tampered = P2pDemandPacket.fromJson(tamperedJson);
    expect(tampered, isNotNull);
    expect(tampered!.verifySignature(), isFalse);

    final dirty = P2pDemandPacket.fromJson({
      ...demand.toJson(),
      'tags': ['ok', 123, '', null],
    });
    expect(dirty?.tags, ['ok']);
  });

  test('P2P gossip response 只签名包指纹，不携带 UDP 包体', () {
    final provider = HanakoKeyPair.generate();
    final response = P2pResponsePacket(
      demandId: 'dem_p2p',
      providerPubKey: provider.publicKeyHex,
      providerSig: '',
      fingerprints: const [
        P2pPackageFingerprint(
          packageHash: 'sha256:abc',
          sizeBytes: 1234,
          title: '窗口经验',
        ),
      ],
      forwardPath: const [
        P2pPathEntry(
          nodeId: 'requester',
          host: '198.51.100.10',
          port: 41001,
          timestamp: 1778323200000,
        ),
      ],
    )..signWith(provider);

    final json = response.toJson();
    expect(json.containsKey('packageData'), isFalse);
    final decoded = P2pResponsePacket.fromJson(json);
    expect(decoded, isNotNull);
    expect(decoded!.verifySignature(), isTrue);

    decoded.returnPath.add(
      const P2pPathEntry(
        nodeId: 'relay',
        host: '198.51.100.20',
        port: 41002,
        timestamp: 1778323201000,
      ),
    );
    expect(decoded.verifySignature(), isTrue);

    final tamperedJson = Map<String, dynamic>.from(json)
      ..['fingerprints'] = [
        {
          'packageHash': 'sha256:tampered',
          'sizeBytes': 1234,
          'title': '窗口经验',
        },
      ];
    final tampered = P2pResponsePacket.fromJson(tamperedJson);
    expect(tampered, isNotNull);
    expect(tampered!.verifySignature(), isFalse);
  });

  test('P2P 缓存导入会拒绝与签名指纹不一致的经验包', () async {
    final tmp = Directory.systemTemp.createTempSync('hanako_p2p_hash_guard_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    final source = ExperienceStore(agentDir: Directory('${tmp.path}/source'));
    final keyPair = HanakoKeyPair.generate();
    final saved = await source.savePrivateExperience(
      title: 'P2P Hash Guard',
      conversation: '[2026-05-09T00:00:00Z] 用户: 指纹保护\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final generated = await source.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );
    final review = _reviewFixture(generated.publisher);
    final attached = await source.attachReviewMaterialsToPrivatePackage(
      experienceId: saved.experienceId,
      reviewMaterials: review.materials,
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9),
    );
    final bytes = File(attached.cachePath!).readAsBytesSync();
    final target = ExperienceStore(agentDir: Directory('${tmp.path}/target'));

    final mismatch = await target.importNetworkPackage(
      bytes,
      trustAnchor: review.anchor,
      expectedPackageHash:
          'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      now: DateTime.utc(2026, 5, 9),
    );
    expect(mismatch.ok, isFalse);
    expect(
      Directory(
        '${tmp.path}/target/experience/network/${saved.experienceId}',
      ).existsSync(),
      isFalse,
    );

    final imported = await target.importNetworkPackage(
      bytes,
      trustAnchor: review.anchor,
      expectedPackageHash: generated.packageHash,
      now: DateTime.utc(2026, 5, 9),
    );
    expect(imported.ok, isTrue);
    expect(imported.packageHash, generated.packageHash);
  });

  test('P2P offer announce 签名可验，篡改 hash 后失败', () {
    final provider = HanakoKeyPair.generate();
    final announce = P2pOfferAnnounce(
      demandId: 'dem_p2p',
      providedPackageHashes: const ['sha256:abc'],
      providerPubKey: provider.publicKeyHex,
      providerSig: '',
    )..signWith(provider);

    final decoded = P2pOfferAnnounce.fromJson(announce.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.verifySignature(), isTrue);

    final tamperedJson = Map<String, dynamic>.from(announce.toJson())
      ..['providedPackageHashes'] = ['sha256:def'];
    final tampered = P2pOfferAnnounce.fromJson(tamperedJson);
    expect(tampered, isNotNull);
    expect(tampered!.verifySignature(), isFalse);

    final dirty = P2pOfferAnnounce.fromJson({
      ...announce.toJson(),
      'providedPackageHashes': ['sha256:abc', 99, '', null],
    });
    expect(dirty?.providedPackageHashes, ['sha256:abc']);
  });

  test('P2P 包请求与供给响应 JSON 保留签名和传输字段', () {
    final timestamp = DateTime.utc(2026, 5, 9, 9);
    final request = ExperiencePackageRequest(
      requestId: 'req_1',
      experienceId: 'exp_1',
      packageHash: 'sha256:abc',
      requesterPeerId: 'peer_requester',
      requesterPublicKey: 'pub_requester',
      requesterAddrs: const [
        ExperienceNetworkEndpoint(
          network: 'tcp',
          host: '2001:db8::2',
          port: 41002,
        ),
      ],
      preferredTransports: const [
        ExperienceTransport.ipv6Direct,
        ExperienceTransport.dhtRelay,
      ],
      dhtNodeId: 'dht_1',
      nonce: 'nonce_1',
      timestamp: timestamp,
      requesterSignature: 'sig_requester',
    );

    final decodedRequest = ExperiencePackageRequest.fromJson(request.toJson());
    expect(decodedRequest.schemaVersion, 'ph01.experience.package_request.v1');
    expect(decodedRequest.requesterPublicKey, 'pub_requester');
    expect(decodedRequest.preferredTransports, [
      ExperienceTransport.ipv6Direct,
      ExperienceTransport.dhtRelay,
    ]);
    expect(decodedRequest.requesterSignature, 'sig_requester');

    final offer = ExperiencePackageOffer(
      requestId: 'req_1',
      experienceId: 'exp_1',
      packageHash: 'sha256:abc',
      providerPeerId: 'peer_provider',
      providerAddrs: const [
        ExperienceNetworkEndpoint(
          network: 'tcp',
          host: '198.51.100.2',
          port: 41002,
          requiresHolePunch: true,
        ),
      ],
      availableTransports: const [
        ExperienceTransport.ipv4HolePunch,
        ExperienceTransport.dhtRelay,
      ],
      reviewMaterials: const ExperienceReviewMaterials(
        rootKeyId: 'test-root',
        signatureAlgorithm: ExperiencePublisher.algorithm,
        signaturePayloadSha256: 'payload_hash',
        managerReviewSignature: 'manager_sig',
        signaturePayload: {'experience_id': 'exp_1'},
        managerCertificate: {'certificate': {}},
      ),
      publisher: const {'pubkey': 'pub_provider'},
      nonce: 'nonce_2',
      timestamp: timestamp,
      providerSignature: 'sig_provider',
    );

    final decodedOffer = ExperiencePackageOffer.fromJson(offer.toJson());
    expect(decodedOffer.schemaVersion, 'ph01.experience.package_offer.v1');
    expect(decodedOffer.providerAddrs.single.requiresHolePunch, isTrue);
    expect(decodedOffer.availableTransports, [
      ExperienceTransport.ipv4HolePunch,
      ExperienceTransport.dhtRelay,
    ]);
    expect(decodedOffer.reviewMaterials?.rootKeyId, 'test-root');
    expect(decodedOffer.publisher['pubkey'], 'pub_provider');
    expect(decodedOffer.providerSignature, 'sig_provider');
  });

  test('自然语言经验需求与 offer JSON 保留回传路径和完整评价链', () {
    final timestamp = DateTime.utc(2026, 5, 9, 9);
    final demand = ExperienceDemand(
      requestId: 'dem_1',
      naturalLanguageQuery: '我想要一个窗口自动化经验',
      queryKeywords: const ['窗口', '自动化'],
      requesterPeerId: 'peer_requester',
      requesterPubkeyHash: 'hash_requester',
      returnPath: [
        ExperienceDemandReturnHop(
          nodeId: 'dht_1',
          apiBaseUrl: 'https://dht.test',
          seenAt: timestamp,
        ),
      ],
      createdAt: timestamp,
      nonce: 'nonce_1',
      requesterSignature: 'sig_requester',
    );

    final decodedDemand = ExperienceDemand.fromJson(demand.toJson());
    expect(decodedDemand.schemaVersion, 'ph01.experience.demand.v1');
    expect(decodedDemand.naturalLanguageQuery, contains('窗口自动化'));
    expect(decodedDemand.queryKeywords, ['窗口', '自动化']);
    expect(decodedDemand.returnPath.single.nodeId, 'dht_1');
    expect(decodedDemand.requesterSignature, 'sig_requester');

    final offer = ExperienceDemandOffer(
      requestId: 'dem_1',
      experienceId: 'exp_1',
      packageHash: 'sha256:abc',
      title: '窗口自动化经验',
      matchedReason: '关键词命中',
      reviewChain: const [
        {'schema_version': 'ph01.experience.ratings.v1', 'type': 'root'},
      ],
      providerPeerId: 'peer_provider',
      providerAddrs: const [
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '198.51.100.20',
          port: 41020,
          requiresHolePunch: true,
        ),
      ],
      availableTransports: const [ExperienceTransport.dhtRelay],
      returnPath: demand.returnPath,
      relaySessionId: 'relay_1',
      timestamp: timestamp,
      providerSignature: 'sig_provider',
    );

    final decodedOffer = ExperienceDemandOffer.fromJson(offer.toJson());
    expect(decodedOffer.schemaVersion, 'ph01.experience.demand_offer.v1');
    expect(decodedOffer.effectiveReviewChainLength, 1);
    expect(decodedOffer.reviewChain.single['type'], 'root');
    expect(decodedOffer.providerAddrs.single.requiresHolePunch, isTrue);
    expect(decodedOffer.availableTransports, [ExperienceTransport.dhtRelay]);
    expect(decodedOffer.returnPath.single.apiBaseUrl, 'https://dht.test');
    expect(decodedOffer.relaySessionId, 'relay_1');
  });

  test('客户端可通过 DHT 发布自然语言需求并查询 offer', () async {
    final keyPair = HanakoKeyPair.generate();
    final timestamp = DateTime.utc(2026, 5, 9, 9);
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/experience-demands') {
        final envelope = await _readJsonBody(requestStream);
        expect(envelope['pubkey'], keyPair.publicKeyHex);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        expect(payload['schema_version'], 'ph01.experience.demand.v1');
        expect(payload['request_id'], 'dem_1');
        expect(payload['natural_language_query'], contains('窗口'));
        return ResponseBody.fromString(
          jsonEncode({
            ...payload,
            'return_path': [
              {
                'node_id': 'dht_1',
                'api_base_url': 'https://dht.test',
                'seen_at': timestamp.toIso8601String(),
              },
            ],
            'expires_at': '2026-05-09T10:00:00Z',
            'updated_at': '2026-05-09T09:00:00Z',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'GET' &&
          options.uri.path == '/api/v1/experience-demands') {
        expect(options.uri.queryParameters['q'], '窗口');
        return ResponseBody.fromString(
          jsonEncode({
            'items': [
              {
                'schema_version': 'ph01.experience.demand.v1',
                'request_id': 'dem_1',
                'natural_language_query': '窗口自动化经验',
                'query_keywords': ['窗口'],
                'requester_peer_id': 'peer_requester',
                'preferred_transports': ['dht_relay', 'manager_seed'],
                'created_at': timestamp.toIso8601String(),
                'expires_at': '2026-05-09T10:00:00Z',
                'updated_at': '2026-05-09T09:00:00Z',
              },
            ],
            'total': 1,
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/experience-demands/dem_1/offers') {
        final envelope = await _readJsonBody(requestStream);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        expect(payload['schema_version'], 'ph01.experience.demand_offer.v1');
        expect(payload['review_chain'], isA<List>());
        expect(payload['provider_peer_id'], 'peer_provider');
        return ResponseBody.fromString(
          jsonEncode({...payload, 'offered_at': '2026-05-09T09:01:00Z'}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/experience-demands/dem_1/offers');
      return ResponseBody.fromString(
        jsonEncode({
          'items': [
            {
              'schema_version': 'ph01.experience.demand_offer.v1',
              'request_id': 'dem_1',
              'experience_id': 'exp_1',
              'package_hash': 'sha256:abc',
              'title': '窗口自动化经验',
              'review_chain': [
                {
                  'schema_version': 'ph01.experience.ratings.v1',
                  'type': 'root',
                },
              ],
              'review_chain_length': 1,
              'provider_peer_id': 'peer_provider',
              'available_transports': ['dht_relay'],
              'timestamp': timestamp.toIso8601String(),
              'offered_at': '2026-05-09T09:01:00Z',
            },
          ],
          'total': 1,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceDhtHttpClient(
      dhtBaseUrl: 'https://dht.test/',
      dio: dio,
    );

    final demand = await client.publishExperienceDemand(
      keyPair: keyPair,
      demand: ExperienceDemand(
        requestId: 'dem_1',
        naturalLanguageQuery: '窗口自动化经验',
        requesterPeerId: 'peer_requester',
        requesterPubkeyHash: keyPair.publicKeyHash,
        createdAt: timestamp,
      ),
    );
    final demands = await client.fetchExperienceDemands(query: '窗口');
    final offer = await client.publishExperienceDemandOffer(
      requestId: 'dem_1',
      keyPair: keyPair,
      offer: ExperienceDemandOffer(
        requestId: 'dem_1',
        experienceId: 'exp_1',
        packageHash: 'sha256:abc',
        reviewChain: const [
          {'schema_version': 'ph01.experience.ratings.v1', 'type': 'root'},
        ],
        providerPeerId: 'peer_provider',
        timestamp: timestamp,
      ),
    );
    final offers = await client.fetchExperienceDemandOffers(requestId: 'dem_1');

    expect(demand.demand.returnPath.single.nodeId, 'dht_1');
    expect(demands.single.demand.requestId, 'dem_1');
    expect(offer.offer.reviewChain.single['type'], 'root');
    expect(offers.single.offer.providerPeerId, 'peer_provider');
  });

  test('客户端可通过 DHT 发布包请求并查询供给 offer', () async {
    final keyPair = HanakoKeyPair.generate();
    final timestamp = DateTime.utc(2026, 5, 9, 9);
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/package-requests') {
        final envelope = await _readJsonBody(requestStream);
        expect(envelope['pubkey'], keyPair.publicKeyHex);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        expect(payload['schema_version'], 'ph01.experience.package_request.v1');
        expect(payload['request_id'], 'req_1');
        expect(payload['requester_peer_id'], 'peer_requester');
        return ResponseBody.fromString(
          jsonEncode({
            ...payload,
            'expires_at': '2026-05-09T10:00:00Z',
            'updated_at': '2026-05-09T09:00:00Z',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'GET' &&
          options.uri.path == '/api/v1/package-requests') {
        expect(options.uri.queryParameters['package_hash'], 'sha256:abc');
        return ResponseBody.fromString(
          jsonEncode({
            'items': [
              {
                'schema_version': 'ph01.experience.package_request.v1',
                'request_id': 'req_1',
                'experience_id': 'exp_1',
                'package_hash': 'sha256:abc',
                'requester_peer_id': 'peer_requester',
                'requester_public_key': keyPair.publicKeyHex,
                'requester_addrs': [
                  {'network': 'udp', 'host': '198.51.100.10', 'port': 41010},
                ],
                'preferred_transports': ['ipv4_hole_punch', 'dht_relay'],
                'nonce': 'nonce_1',
                'timestamp': timestamp.toIso8601String(),
                'expires_at': '2026-05-09T10:00:00Z',
                'updated_at': '2026-05-09T09:00:00Z',
              },
            ],
            'total': 1,
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/package-requests/req_1/offers') {
        final envelope = await _readJsonBody(requestStream);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        expect(payload['schema_version'], 'ph01.experience.package_offer.v1');
        expect(payload['provider_peer_id'], 'peer_provider');
        return ResponseBody.fromString(
          jsonEncode({...payload, 'offered_at': '2026-05-09T09:01:00Z'}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/package-requests/req_1/offers');
      return ResponseBody.fromString(
        jsonEncode({
          'items': [
            {
              'schema_version': 'ph01.experience.package_offer.v1',
              'request_id': 'req_1',
              'experience_id': 'exp_1',
              'package_hash': 'sha256:abc',
              'provider_peer_id': 'peer_provider',
              'provider_addrs': [
                {'network': 'udp', 'host': '198.51.100.20', 'port': 41020},
              ],
              'available_transports': ['ipv4_hole_punch', 'dht_relay'],
              'publisher': {'pubkey': 'pub_provider'},
              'nonce': 'nonce_2',
              'timestamp': timestamp.toIso8601String(),
              'offered_at': '2026-05-09T09:01:00Z',
            },
          ],
          'total': 1,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceDhtHttpClient(
      dhtBaseUrl: 'https://dht.test/',
      dio: dio,
    );

    final requestRecord = await client.publishPackageRequest(
      keyPair: keyPair,
      request: ExperiencePackageRequest(
        requestId: 'req_1',
        experienceId: 'exp_1',
        packageHash: 'sha256:abc',
        requesterPeerId: 'peer_requester',
        requesterPublicKey: keyPair.publicKeyHex,
        requesterAddrs: const [
          ExperienceNetworkEndpoint(
            network: 'udp',
            host: '198.51.100.10',
            port: 41010,
          ),
        ],
        preferredTransports: const [
          ExperienceTransport.ipv4HolePunch,
          ExperienceTransport.dhtRelay,
        ],
        nonce: 'nonce_1',
        timestamp: timestamp,
      ),
    );
    final requests = await client.fetchPackageRequests(
      packageHash: 'sha256:abc',
    );
    final offerRecord = await client.publishPackageOffer(
      requestId: 'req_1',
      keyPair: keyPair,
      offer: ExperiencePackageOffer(
        requestId: 'req_1',
        experienceId: 'exp_1',
        packageHash: 'sha256:abc',
        providerPeerId: 'peer_provider',
        providerAddrs: const [
          ExperienceNetworkEndpoint(
            network: 'udp',
            host: '198.51.100.20',
            port: 41020,
          ),
        ],
        availableTransports: const [
          ExperienceTransport.ipv4HolePunch,
          ExperienceTransport.dhtRelay,
        ],
        publisher: const {'pubkey': 'pub_provider'},
        nonce: 'nonce_2',
        timestamp: timestamp,
      ),
    );
    final offers = await client.fetchPackageOffers(requestId: 'req_1');

    expect(requestRecord.request.requestId, 'req_1');
    expect(requests.single.request.preferredTransports, [
      ExperienceTransport.ipv4HolePunch,
      ExperienceTransport.dhtRelay,
    ]);
    expect(offerRecord.offer.providerPeerId, 'peer_provider');
    expect(offers.single.offer.providerAddrs.single.host, '198.51.100.20');
  });

  test('供给方工作流可从本地完整包发布 offer 并上传 relay 缓存', () async {
    final tmp = Directory.systemTemp.createTempSync('hanako_supply_flow_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    final store = ExperienceStore(agentDir: tmp);
    final keyPair = HanakoKeyPair.generate();
    final saved = await store.savePrivateExperience(
      title: '供给方工作流测试',
      conversation: '[2026-05-09T00:00:00Z] 用户: 本地完整包\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final generated = await store.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );
    final review = _reviewFixture(generated.publisher);
    await store.attachReviewMaterialsToPrivatePackage(
      experienceId: saved.experienceId,
      reviewMaterials: review.materials,
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9),
    );
    final cacheBytes = File(generated.cachePath).readAsBytesSync();

    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/package-requests/req_1/offers') {
        final envelope = await _readJsonBody(requestStream);
        expect(envelope['pubkey'], keyPair.publicKeyHex);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        expect(payload['schema_version'], 'ph01.experience.package_offer.v1');
        expect(payload['experience_id'], saved.experienceId);
        expect(payload['provider_peer_id'], 'peer_provider');
        expect(payload['review_materials'], isA<Map>());
        return ResponseBody.fromString(
          jsonEncode({...payload, 'offered_at': '2026-05-09T09:01:00Z'}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/relay/sessions') {
        final envelope = await _readJsonBody(requestStream);
        expect(envelope['pubkey'], keyPair.publicKeyHex);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        expect(
          payload['schema_version'],
          'ph01.experience.relay_session_request.v1',
        );
        expect(payload['request_id'], 'req_1');
        expect(payload['provider_peer_id'], 'peer_provider');
        return ResponseBody.fromString(
          jsonEncode({
            'schema_version': 'ph01.experience.relay_session.v1',
            'session_id': 'relay_1',
            'request_id': 'req_1',
            'experience_id': saved.experienceId,
            'package_hash': generated.publisher.packageHash,
            'requester_peer_id': 'peer_requester',
            'provider_peer_id': 'peer_provider',
            'expires_at': '2026-05-09T10:00:00Z',
            'max_bytes': 1024,
            'status': 'open',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      expect(options.method, 'PUT');
      expect(options.uri.path, '/api/v1/relay/sessions/relay_1/package');
      final body = await _readRawBody(requestStream);
      expect(body, cacheBytes);
      return ResponseBody.fromString(
        jsonEncode({
          'schema_version': 'ph01.experience.relay_session.v1',
          'session_id': 'relay_1',
          'request_id': 'req_1',
          'experience_id': saved.experienceId,
          'package_hash': generated.publisher.packageHash,
          'requester_peer_id': 'peer_requester',
          'provider_peer_id': 'peer_provider',
          'expires_at': '2026-05-09T10:00:00Z',
          'max_bytes': 1024,
          'status': 'uploaded',
          'bytes': cacheBytes.length,
          'payload_sha256': 'hash_1',
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });

    final client = ExperienceDhtHttpClient(
      dhtBaseUrl: 'https://dht.test/',
      dio: dio,
    );
    final workflow = ExperiencePackageSupplyWorkflow(
      store: store,
      dhtClient: client,
    );

    final offerRecord = await workflow.publishLocalPackageOffer(
      experienceId: saved.experienceId,
      requestId: 'req_1',
      providerPeerId: 'peer_provider',
      keyPair: keyPair,
      providerAddrs: const [
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '198.51.100.20',
          port: 41020,
        ),
      ],
      availableTransports: const [
        ExperienceTransport.ipv4HolePunch,
        ExperienceTransport.dhtRelay,
      ],
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9, 9, 0, 0),
    );
    final relaySession = await client.createRelaySession(
      keyPair: keyPair,
      request: ExperienceDhtRelaySessionRequest(
        requestId: 'req_1',
        experienceId: saved.experienceId,
        packageHash: generated.publisher.packageHash,
        requesterPeerId: 'peer_requester',
        providerPeerId: 'peer_provider',
        maxBytes: 1024,
      ),
    );
    final uploaded = await workflow.uploadLocalPackageToRelay(
      experienceId: saved.experienceId,
      sessionId: relaySession.sessionId,
      now: DateTime.utc(2026, 5, 9, 9, 0, 0),
      trustAnchor: review.anchor,
    );

    expect(offerRecord.offer.requestId, 'req_1');
    expect(offerRecord.offer.reviewMaterials?.rootKeyId, 'test-root');
    expect(relaySession.sessionId, 'relay_1');
    expect(uploaded.status, 'uploaded');
    expect(uploaded.bytes, cacheBytes.length);
  });

  test('自然语言需求工作流可收集 offer 并通过管理端兜底导入经验包', () async {
    final tmp = Directory.systemTemp.createTempSync('hanako_demand_flow_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    final store = ExperienceStore(agentDir: tmp);
    final keyPair = HanakoKeyPair.generate();
    final saved = await store.savePrivateExperience(
      title: '自然语言需求导入测试',
      conversation: '[2026-05-09T00:00:00Z] 用户: 需求命中\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final generated = await store.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );
    final review = _reviewFixture(generated.publisher);
    await store.attachReviewMaterialsToPrivatePackage(
      experienceId: saved.experienceId,
      reviewMaterials: review.materials,
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9),
    );
    final cacheBytes = File(generated.cachePath).readAsBytesSync();
    var requestId = '';

    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/experience-demands') {
        final envelope = await _readJsonBody(requestStream);
        expect(envelope['pubkey'], keyPair.publicKeyHex);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        requestId = payload['request_id'] as String;
        expect(payload['natural_language_query'], contains('窗口'));
        return ResponseBody.fromString(
          jsonEncode({
            ...payload,
            'return_path': [
              {'node_id': 'dht_1', 'api_base_url': 'https://dht.test'},
            ],
            'expires_at': '2026-05-09T10:00:00Z',
            'updated_at': '2026-05-09T09:00:00Z',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'GET' &&
          options.uri.path == '/api/v1/experience-demands/$requestId/offers') {
        return ResponseBody.fromString(
          jsonEncode({
            'items': [
              {
                'schema_version': 'ph01.experience.demand_offer.v1',
                'request_id': requestId,
                'experience_id': saved.experienceId,
                'package_hash': generated.publisher.packageHash,
                'title': saved.metadata.title,
                'review_chain': [
                  {
                    'schema_version': 'ph01.experience.ratings.v1',
                    'type': 'root',
                  },
                ],
                'review_chain_length': 1,
                'provider_peer_id': 'peer_provider',
                'available_transports': ['manager_seed'],
                'timestamp': '2026-05-09T09:01:00Z',
                'offered_at': '2026-05-09T09:01:00Z',
              },
            ],
            'total': 1,
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      expect(options.method, 'GET');
      expect(
        options.uri.path,
        '/api/v1/experiences/${saved.experienceId}/package',
      );
      return ResponseBody.fromBytes(
        cacheBytes,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/zip'],
        },
      );
    });

    final workflow = ExperienceDemandPullWorkflow(
      store: store,
      dhtClient: ExperienceDhtHttpClient(
        dhtBaseUrl: 'https://dht.test/',
        dio: dio,
      ),
      managerClient: ExperienceNetworkManagerClient(
        managerBaseUrl: 'https://experience.test/',
        dio: dio,
      ),
    );

    final result = await workflow.requestAndImportBestOffer(
      query: '我想找窗口自动化经验',
      requesterPeerId: 'peer_requester',
      keyPair: keyPair,
      trustAnchor: review.anchor,
      pollAttempts: 1,
      now: DateTime.utc(2026, 5, 9, 9),
    );

    expect(result.demand.demand.requestId, startsWith('dem_'));
    expect(result.selectedOffer?.offer.experienceId, saved.experienceId);
    expect(result.importResult.ok, isTrue);
    expect(result.importResult.experienceId, saved.experienceId);
  });

  test('供给方工作流可轮询自然语言需求并发布带评价链的 demand offer', () async {
    final tmp = Directory.systemTemp.createTempSync('hanako_demand_supply_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    final store = ExperienceStore(agentDir: tmp);
    final keyPair = HanakoKeyPair.generate();
    final saved = await store.savePrivateExperience(
      title: '窗口自动化供给测试',
      conversation: '[2026-05-09T00:00:00Z] 用户: 窗口 自动化\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final generated = await store.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );
    final review = _reviewFixture(generated.publisher);
    await store.attachReviewMaterialsToPrivatePackage(
      experienceId: saved.experienceId,
      reviewMaterials: review.materials,
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9),
    );

    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      if (options.method == 'GET' &&
          options.uri.path == '/api/v1/experience-demands') {
        expect(options.uri.queryParameters['q'], '窗口');
        return ResponseBody.fromString(
          jsonEncode({
            'items': [
              {
                'schema_version': 'ph01.experience.demand.v1',
                'request_id': 'dem_supply',
                'natural_language_query': '窗口 自动化',
                'requester_peer_id': 'peer_requester',
                'preferred_transports': ['dht_relay', 'manager_seed'],
                'return_path': [
                  {'node_id': 'dht_1', 'api_base_url': 'https://dht.test'},
                ],
                'created_at': '2026-05-09T09:00:00Z',
                'expires_at': '2026-05-09T10:00:00Z',
                'updated_at': '2026-05-09T09:00:00Z',
              },
            ],
            'total': 1,
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      expect(options.method, 'POST');
      expect(options.uri.path, '/api/v1/experience-demands/dem_supply/offers');
      final envelope = await _readJsonBody(requestStream);
      expect(envelope['pubkey'], keyPair.publicKeyHex);
      final payload =
          jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
      expect(payload['schema_version'], 'ph01.experience.demand_offer.v1');
      expect(payload['experience_id'], saved.experienceId);
      expect(payload['package_hash'], generated.publisher.packageHash);
      expect(payload['review_chain'], isA<List>());
      expect((payload['review_chain'] as List), isNotEmpty);
      expect(payload['return_path'], isA<List>());
      return ResponseBody.fromString(
        jsonEncode({...payload, 'offered_at': '2026-05-09T09:01:00Z'}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final workflow = ExperiencePackageSupplyWorkflow(
      store: store,
      dhtClient: ExperienceDhtHttpClient(
        dhtBaseUrl: 'https://dht.test/',
        dio: dio,
      ),
    );

    final offers = await workflow.answerMatchingExperienceDemands(
      providerPeerId: 'peer_provider',
      keyPair: keyPair,
      query: '窗口',
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9, 9),
    );

    expect(offers.single.offer.experienceId, saved.experienceId);
    expect(offers.single.offer.reviewChain, isNotEmpty);
  });

  test('客户端可创建 DHT relay 会话并上传下载包字节', () async {
    final keyPair = HanakoKeyPair.generate();
    final packageBytes = Uint8List.fromList([1, 2, 3, 4]);
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      if (options.method == 'POST') {
        expect(options.uri.path, '/api/v1/relay/sessions');
        final envelope = await _readJsonBody(requestStream);
        expect(envelope['pubkey'], keyPair.publicKeyHex);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        expect(
          payload['schema_version'],
          'ph01.experience.relay_session_request.v1',
        );
        expect(payload['request_id'], 'req_1');
        expect(payload['package_hash'], 'sha256:abc');
        return ResponseBody.fromString(
          jsonEncode({
            'schema_version': 'ph01.experience.relay_session.v1',
            'session_id': 'relay_1',
            'request_id': 'req_1',
            'experience_id': 'exp_1',
            'package_hash': 'sha256:abc',
            'requester_peer_id': 'peer_requester',
            'provider_peer_id': 'peer_provider',
            'expires_at': '2026-05-09T10:00:00Z',
            'max_bytes': 1024,
            'status': 'open',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'PUT') {
        expect(options.uri.path, '/api/v1/relay/sessions/relay_1/package');
        final body = await _readRawBody(requestStream);
        expect(body, packageBytes);
        return ResponseBody.fromString(
          jsonEncode({
            'schema_version': 'ph01.experience.relay_session.v1',
            'session_id': 'relay_1',
            'request_id': 'req_1',
            'experience_id': 'exp_1',
            'package_hash': 'sha256:abc',
            'requester_peer_id': 'peer_requester',
            'provider_peer_id': 'peer_provider',
            'expires_at': '2026-05-09T10:00:00Z',
            'max_bytes': 1024,
            'status': 'uploaded',
            'bytes': 4,
            'payload_sha256': 'hash_1',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/relay/sessions/relay_1/package');
      return ResponseBody.fromBytes(
        packageBytes,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/octet-stream'],
        },
      );
    });
    final client = ExperienceDhtHttpClient(
      dhtBaseUrl: 'https://dht.test/',
      dio: dio,
    );

    final session = await client.createRelaySession(
      keyPair: keyPair,
      request: const ExperienceDhtRelaySessionRequest(
        requestId: 'req_1',
        experienceId: 'exp_1',
        packageHash: 'sha256:abc',
        requesterPeerId: 'peer_requester',
        providerPeerId: 'peer_provider',
        maxBytes: 1024,
      ),
    );
    final uploaded = await client.uploadRelayPackage(
      sessionId: session.sessionId,
      packageBytes: packageBytes,
    );
    final downloaded = await client.downloadRelayPackage(
      sessionId: session.sessionId,
    );

    expect(session.status, 'open');
    expect(uploaded.hasPayload, isTrue);
    expect(uploaded.payloadSha256, 'hash_1');
    expect(downloaded, packageBytes);
  });

  test('客户端可沿需求回传路径缓存包并按需拉取评价链', () async {
    final packageBytes = Uint8List.fromList([7, 8, 9]);
    final calls = <String>[];
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      if (options.method == 'PUT') {
        expect(options.uri.path, '/api/v1/cache/packages/abc');
        expect(options.headers['X-PH01-Experience-ID'], 'exp_1');
        final body = await _readRawBody(requestStream);
        expect(body, packageBytes);
        calls.add('PUT ${options.uri.host}');
        return ResponseBody.fromString(
          jsonEncode({
            'package_hash': 'sha256:abc',
            'experience_id': 'exp_1',
            'bytes': packageBytes.length,
            'payload_sha256': 'hash_1',
            'stored_at': '2026-05-09T09:00:00Z',
            'expires_at': '2026-05-16T09:00:00Z',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'GET' &&
          options.uri.path == '/api/v1/cache/packages/abc') {
        calls.add('GET ${options.uri.host}');
        return ResponseBody.fromBytes(
          packageBytes,
          200,
          headers: {
            Headers.contentTypeHeader: ['application/octet-stream'],
          },
        );
      }
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/review-chains/chain');
      calls.add('GET_CHAIN ${options.uri.host}');
      return ResponseBody.fromString(
        jsonEncode({
          'review_chain': [
            {'type': 'root', 'score': 1},
            {'type': 'review', 'score': 2},
          ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceDhtHttpClient(
      dhtBaseUrl: 'https://local-dht.test/',
      dio: dio,
    );
    const returnPath = [
      ExperienceDemandReturnHop(nodeId: 'dht_a', apiBaseUrl: 'https://a.test'),
      ExperienceDemandReturnHop(nodeId: 'dht_b', apiBaseUrl: 'https://b.test'),
    ];

    final uploaded = await client.uploadCachedPackageToReturnPath(
      packageHash: 'sha256:abc',
      packageBytes: packageBytes,
      experienceId: 'exp_1',
      returnPath: returnPath,
    );
    final downloaded = await client.downloadCachedPackage(
      packageHash: 'sha256:abc',
      returnPath: returnPath,
    );
    final chain = await client.fetchReviewChainByDigest(digest: 'sha256:chain');

    expect(uploaded, 3);
    expect(downloaded, packageBytes);
    expect(chain, hasLength(2));
    expect(calls, [
      'PUT b.test',
      'PUT a.test',
      'PUT local-dht.test',
      'GET a.test',
      'GET_CHAIN local-dht.test',
    ]);
  });

  test('客户端可创建 DHT 打洞协调会话并上报查询状态', () async {
    final keyPair = HanakoKeyPair.generate();
    final dio = Dio();
    dio.httpClientAdapter = _InspectingAdapter((options, requestStream) async {
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/hole-punch/sessions') {
        final envelope = await _readJsonBody(requestStream);
        expect(envelope['pubkey'], keyPair.publicKeyHex);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        expect(
          payload['schema_version'],
          'ph01.experience.hole_punch_request.v1',
        );
        expect(payload['request_id'], 'req_1');
        expect(payload['requester_addrs'], isA<List>());
        return ResponseBody.fromString(
          jsonEncode({
            'schema_version': 'ph01.experience.hole_punch_session.v1',
            'session_id': 'hp_1',
            'request_id': 'req_1',
            'experience_id': 'exp_1',
            'package_hash': 'sha256:abc',
            'requester_peer_id': 'peer_requester',
            'requester_addrs': [
              {
                'network': 'udp',
                'host': '198.51.100.10',
                'port': 41010,
                'requires_hole_punch': true,
              },
            ],
            'provider_peer_id': 'peer_provider',
            'provider_addrs': [
              {
                'network': 'udp',
                'host': '198.51.100.20',
                'port': 41020,
                'requires_hole_punch': true,
              },
            ],
            'punch_token': 'token_1',
            'expires_at': '2026-05-09T10:00:00Z',
            'status': 'open',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      if (options.method == 'POST' &&
          options.uri.path == '/api/v1/hole-punch/sessions/hp_1/reports') {
        final envelope = await _readJsonBody(requestStream);
        expect(envelope['pubkey'], keyPair.publicKeyHex);
        final payload =
            jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
        expect(payload['peer_id'], 'peer_requester');
        expect(payload['role'], 'requester');
        expect(payload['result'], 'attempting');
        return ResponseBody.fromString(
          jsonEncode({
            'schema_version': 'ph01.experience.hole_punch_session.v1',
            'session_id': 'hp_1',
            'request_id': 'req_1',
            'experience_id': 'exp_1',
            'package_hash': 'sha256:abc',
            'requester_peer_id': 'peer_requester',
            'provider_peer_id': 'peer_provider',
            'punch_token': 'token_1',
            'expires_at': '2026-05-09T10:00:00Z',
            'status': 'attempting',
            'requester_report': {
              'peer_id': 'peer_requester',
              'role': 'requester',
              'result': 'attempting',
              'observed_endpoint': {
                'network': 'udp',
                'host': '203.0.113.10',
                'port': 50000,
              },
              'updated_at': '2026-05-09T09:55:00Z',
            },
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      expect(options.method, 'GET');
      expect(options.uri.path, '/api/v1/hole-punch/sessions/hp_1');
      return ResponseBody.fromString(
        jsonEncode({
          'schema_version': 'ph01.experience.hole_punch_session.v1',
          'session_id': 'hp_1',
          'request_id': 'req_1',
          'experience_id': 'exp_1',
          'package_hash': 'sha256:abc',
          'requester_peer_id': 'peer_requester',
          'provider_peer_id': 'peer_provider',
          'punch_token': 'token_1',
          'expires_at': '2026-05-09T10:00:00Z',
          'status': 'succeeded',
          'provider_report': {
            'peer_id': 'peer_provider',
            'role': 'provider',
            'result': 'succeeded',
            'updated_at': '2026-05-09T09:56:00Z',
          },
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    });
    final client = ExperienceDhtHttpClient(
      dhtBaseUrl: 'https://dht.test/',
      dio: dio,
    );

    final session = await client.createHolePunchSession(
      keyPair: keyPair,
      request: const ExperienceDhtHolePunchSessionRequest(
        requestId: 'req_1',
        experienceId: 'exp_1',
        packageHash: 'sha256:abc',
        requesterPeerId: 'peer_requester',
        requesterAddrs: [
          ExperienceNetworkEndpoint(
            network: 'udp',
            host: '198.51.100.10',
            port: 41010,
            requiresHolePunch: true,
          ),
        ],
        providerPeerId: 'peer_provider',
        providerAddrs: [
          ExperienceNetworkEndpoint(
            network: 'udp',
            host: '198.51.100.20',
            port: 41020,
            requiresHolePunch: true,
          ),
        ],
      ),
    );
    final reported = await client.reportHolePunch(
      sessionId: session.sessionId,
      keyPair: keyPair,
      report: const ExperienceDhtHolePunchReport(
        peerId: 'peer_requester',
        role: 'requester',
        result: 'attempting',
        observedEndpoint: ExperienceNetworkEndpoint(
          network: 'udp',
          host: '203.0.113.10',
          port: 50000,
        ),
      ),
    );
    final fetched = await client.fetchHolePunchSession(
      sessionId: session.sessionId,
    );

    expect(session.punchToken, 'token_1');
    expect(session.requesterAddrs.single.requiresHolePunch, isTrue);
    expect(reported.status, 'attempting');
    expect(reported.requesterReport?.observedEndpoint?.host, '203.0.113.10');
    expect(fetched.status, 'succeeded');
    expect(fetched.providerReport?.result, 'succeeded');
  });
}

ExperienceDhtNode _publicDht(
  String id, {
  ExperienceDhtLoad load = const ExperienceDhtLoad(relayCapacity: 10),
  ExperienceDhtHealthStatus healthStatus = ExperienceDhtHealthStatus.healthy,
  DateTime? expiresAt,
}) {
  return ExperienceDhtNode(
    nodeId: id,
    endpoints: const [
      ExperienceNetworkEndpoint(
        network: 'udp',
        host: '203.0.113.10',
        port: 41001,
      ),
    ],
    capabilities: const {'relay': true, 'hole_punch': true},
    relayPolicy: ExperienceRelayPolicy.public,
    healthStatus: healthStatus,
    load: load,
    expiresAt: expiresAt ?? DateTime.utc(2026, 5, 10),
  );
}

Map<String, dynamic> _adminStateJson(
  String pubkeyHex, {
  required bool publicEnabled,
  required bool publicRegistered,
  String publicManagerBaseUrl = '',
  String bootstrapManagerBaseUrl = '',
}) {
  return {
    'schema_version': 'ph01.experience.dht_state.v1',
    'node_id': 'dht_admin',
    'bound_pubkey_hex': pubkeyHex,
    'bound_at': '2026-05-09T09:00:00Z',
    'public_enabled': publicEnabled,
    'public_registered': publicRegistered,
    if (bootstrapManagerBaseUrl.isNotEmpty)
      'bootstrap_manager_base_url': bootstrapManagerBaseUrl,
    if (publicManagerBaseUrl.isNotEmpty)
      'public_manager_base_url': publicManagerBaseUrl,
    'updated_at': '2026-05-09T09:01:00Z',
  };
}

class _ReviewFixture {
  const _ReviewFixture(this.materials, this.anchor);
  final ExperienceReviewMaterials materials;
  final ExperienceReviewTrustAnchor anchor;
}

_ReviewFixture _reviewFixture(ExperiencePublisher publisher) {
  final root = HanakoKeyPair.generate();
  final master = HanakoKeyPair.generate();
  const rootKeyId = 'test-root';
  const algorithm = ExperiencePublisher.algorithm;
  final certPayload = <String, dynamic>{
    'schema_version': 'ph01.experience.master_certificate.v1',
    'certificate_id': 'test-master',
    'role': 'experience_review_master',
    'issuer_root_key_id': rootKeyId,
    'algorithm': algorithm,
    'public_key_hex': master.publicKeyHex,
    'not_before': '2026-05-01T00:00:00Z',
    'not_after': '2026-06-01T00:00:00Z',
    'extensions': {'revoked_certificate_fingerprints': <String>[]},
  };
  final certPayloadBytes = Uint8List.fromList(
    utf8.encode(jsonEncode(certPayload)),
  );
  final managerCertificate = <String, dynamic>{
    'certificate': certPayload,
    'signature_algorithm': algorithm,
    'signature_payload_sha256': _sha256Hex(certPayloadBytes),
    'root_signature_hex': _hexEncode(root.sign(certPayloadBytes)),
  };
  final signaturePayload = <String, dynamic>{
    'schema_version': 'ph01.experience.review_payload.v1',
    'experience_id': publisher.experienceId,
    'package_hash_algorithm': 'sha256',
    'package_hash': publisher.packageHash,
    'publisher_pubkey': publisher.publisherPubkey,
    'review_status': 'network',
    'review_mode': 'manual_review',
    'reviewed_at': '2026-05-09T00:00:00Z',
    'certificate_id': 'test-master',
    'signer_role': 'experience_review_master',
    'signature_algorithm': algorithm,
  };
  final payloadBytes = Uint8List.fromList(
    utf8.encode(jsonEncode(signaturePayload)),
  );
  return _ReviewFixture(
    ExperienceReviewMaterials(
      rootKeyId: rootKeyId,
      signatureAlgorithm: algorithm,
      signaturePayloadSha256: _sha256Hex(payloadBytes),
      managerReviewSignature: _hexEncode(master.sign(payloadBytes)),
      signaturePayload: signaturePayload,
      managerCertificate: managerCertificate,
    ),
    ExperienceReviewTrustAnchor(
      rootKeyId: rootKeyId,
      algorithm: algorithm,
      rootPublicKeyHex: root.publicKeyHex,
    ),
  );
}

class _StaticAdapter implements HttpClientAdapter {
  _StaticAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

class _InspectingAdapter implements HttpClientAdapter {
  _InspectingAdapter(this.handler);

  final Future<ResponseBody> Function(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  )
  handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options, requestStream);
  }

  @override
  void close({bool force = false}) {}
}

Future<Map<String, dynamic>> _readJsonBody(
  Stream<Uint8List>? requestStream,
) async {
  final bytes = await _readRawBody(requestStream);
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}

Future<Uint8List> _readRawBody(Stream<Uint8List>? requestStream) async {
  final bytes = <int>[];
  if (requestStream != null) {
    await for (final chunk in requestStream) {
      bytes.addAll(chunk);
    }
  }
  return Uint8List.fromList(bytes);
}

String _sha256Hex(List<int> bytes) => sha256
    .convert(bytes)
    .bytes
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

String _hexEncode(Uint8List bytes) {
  const chars = '0123456789abcdef';
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer
      ..write(chars[(byte >> 4) & 0x0f])
      ..write(chars[byte & 0x0f]);
  }
  return buffer.toString();
}
