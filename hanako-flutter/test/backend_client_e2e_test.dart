// Flutter 用户端到 ph01-backend 的本地端到端测试。
//
// 默认跳过，只有显式设置 HANAKO_BACKEND_E2E=1 才会访问本机服务。

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/identity/identity.dart';

void main() {
  const enabled = bool.fromEnvironment('HANAKO_BACKEND_E2E');
  if (!enabled) {
    test('backend e2e skipped', () {
      markTestSkipped('set --dart-define=HANAKO_BACKEND_E2E=true to run');
    });
    return;
  }

  final authBase = const String.fromEnvironment(
    'HANAKO_AUTH_BASE',
    defaultValue: 'http://localhost:8080',
  );
  final aiBase = const String.fromEnvironment(
    'HANAKO_AI_BASE',
    defaultValue: 'http://localhost:8081',
  );
  final aiAdminToken = const String.fromEnvironment('HANAKO_AI_ADMIN_TOKEN');
  final model = const String.fromEnvironment(
    'HANAKO_E2E_MODEL',
    defaultValue: 'mock-gpt',
  );
  final upstreamBase = const String.fromEnvironment(
    'HANAKO_E2E_UPSTREAM_BASE',
    defaultValue: 'http://localhost:18080/v1',
  );
  final e2eEmail = const String.fromEnvironment('HANAKO_E2E_EMAIL');
  final e2eEmailChallengeID = const String.fromEnvironment(
    'HANAKO_E2E_EMAIL_CHALLENGE_ID',
  );
  final e2eEmailCode = const String.fromEnvironment('HANAKO_E2E_EMAIL_CODE');
  final e2eUsername = const String.fromEnvironment('HANAKO_E2E_USERNAME');

  test(
    'register/login/recovery/handshake/chat full path',
    () async {
      expect(
        aiAdminToken,
        isNotEmpty,
        reason: 'HANAKO_AI_ADMIN_TOKEN is required',
      );

      final dio = Dio(
        BaseOptions(validateStatus: (status) => status != null && status < 500),
      );
      final upstreamID = await _ensureMockUpstream(
        dio: dio,
        aiBase: aiBase,
        token: aiAdminToken,
        upstreamBase: upstreamBase,
      );
      await _ensureMockMapping(
        dio: dio,
        aiBase: aiBase,
        token: aiAdminToken,
        upstreamID: upstreamID,
        model: model,
      );

      final client = HanakoBackendClient(
        authBaseUrl: authBase,
        aiBaseUrl: aiBase,
      );
      final keyPair = HanakoKeyPair.generate();
      final username = e2eUsername.isEmpty
          ? 'e2e_${DateTime.now().microsecondsSinceEpoch}'
          : e2eUsername;
      if (e2eEmail.isEmpty ||
          e2eEmailChallengeID.isEmpty ||
          e2eEmailCode.isEmpty) {
        markTestSkipped(
          'registration now requires email verification; provide '
          'HANAKO_E2E_USERNAME, HANAKO_E2E_EMAIL, HANAKO_E2E_EMAIL_CHALLENGE_ID and '
          'HANAKO_E2E_EMAIL_CODE',
        );
        return;
      }

      final availabilityBefore = await client.checkUsernameAvailability(
        username,
      );
      expect(availabilityBefore.available, isTrue);

      final reg = await client.register(
        keyPair: keyPair,
        username: username,
        nickname: 'E2E User',
        email: e2eEmail,
        emailChallengeId: e2eEmailChallengeID,
        emailCode: e2eEmailCode,
      );
      expect(reg.username, username);
      expect(reg.tier, 'free');
      expect(reg.pubkeyHash, keyPair.publicKeyHash);

      final availabilityAfter = await client.checkUsernameAvailability(
        username,
      );
      expect(availabilityAfter.available, isFalse);

      final login = await client.login(keyPair: keyPair, username: username);
      expect(login.userId, reg.userId);
      expect(login.pubkeyHash, keyPair.publicKeyHash);

      final candidates = await client.fetchRecoveryCandidates(username);
      expect(candidates, contains(keyPair.publicKeyHash));

      final channel = await client.handshake(keyPair: keyPair);
      expect(channel.channelId, isNotEmpty);
      expect(channel.allowedModels, contains(model));

      final resp = await client.chat(
        model: model,
        messages: [
          {'role': 'user', 'content': 'hello local backend'},
        ],
      );
      final content =
          (((resp['choices'] as List).first as Map)['message']
                  as Map)['content']
              as String;
      expect(content, contains('mock reply'));
      expect(content, contains('hello local backend'));

      final chunks = <String>[];
      await for (final chunk in client.chatStream(
        model: model,
        messages: [
          {'role': 'user', 'content': 'hello stream'},
        ],
      )) {
        chunks.add(chunk);
      }
      expect(chunks.join('\n'), contains('mock stream'));
      expect(chunks.join('\n'), contains('hello stream'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<int> _ensureMockUpstream({
  required Dio dio,
  required String aiBase,
  required String token,
  required String upstreamBase,
}) async {
  const name = 'mock-openai-local';
  final headers = {'Authorization': 'Bearer $token'};
  final list = await dio.get<Map<String, dynamic>>(
    '$aiBase/admin/upstreams',
    options: Options(headers: headers),
  );
  final items = (list.data!['items'] as List).cast<Map>();
  for (final item in items) {
    if (item['name'] == name) {
      return (item['id'] as num).toInt();
    }
  }

  final created = await dio.post<Map<String, dynamic>>(
    '$aiBase/admin/upstreams',
    data: {
      'name': name,
      'base_url': upstreamBase,
      'api_key': 'mock-key',
      'format': 'openai',
      'enabled': true,
    },
    options: Options(headers: headers),
  );
  expect(created.statusCode, 200);
  return (created.data!['id'] as num).toInt();
}

Future<void> _ensureMockMapping({
  required Dio dio,
  required String aiBase,
  required String token,
  required int upstreamID,
  required String model,
}) async {
  final headers = {'Authorization': 'Bearer $token'};
  final list = await dio.get<Map<String, dynamic>>(
    '$aiBase/admin/mappings',
    options: Options(headers: headers),
  );
  final items = (list.data!['items'] as List).cast<Map>();
  if (items.any((item) => item['public_name'] == model)) {
    return;
  }

  final created = await dio.post<Map<String, dynamic>>(
    '$aiBase/admin/mappings',
    data: {
      'public_name': model,
      'upstream_id': upstreamID,
      'upstream_name': model,
      'min_tier': 'free',
      'enabled': true,
    },
    options: Options(headers: headers),
  );
  expect(created.statusCode, 200);
}
