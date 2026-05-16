import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/identity/identity.dart';
import 'package:hanako/llm/provider.dart';
import 'package:hanako/shared/diagnostics_log.dart';

void main() {
  group('HanakoBackendClient 公开故事诊断日志', () {
    late Directory tmp;
    late File logFile;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp(
        'hanako_backend_diagnostics_',
      );
      logFile = File('${tmp.path}${Platform.pathSeparator}public-story.jsonl');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('模型列表成功记录请求与响应结构化字段', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StaticAdapter((options) async {
        expect(options.method, 'GET');
        expect(options.uri.path, '/api/v1/public/story/models');
        return ResponseBody.fromString(
          jsonEncode({
            'models': ['story-model'],
            'tier': 'public',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final client = HanakoBackendClient(
        aiBaseUrl: 'https://ai.test',
        authBaseUrl: 'https://auth.test',
        dio: dio,
        publicStoryDiagnosticsLog: DiagnosticsLog(logFile),
      );

      final models = await client.listPublicStoryModels();

      expect(models.models, ['story-model']);
      final lines = _readJsonLines(logFile);
      expect(lines, hasLength(2));
      expect(lines[0]['layer'], 'backend_client');
      expect(lines[0]['event'], 'transport_request');
      expect(lines[0]['operation'], 'public_story_models');
      expect(lines[0]['mode'], 'plaintext');
      expect(lines[1]['event'], 'transport_success');
      expect(lines[1]['status_code'], 200);
      expect(lines[1]['model_count'], 1);
      expect(lines[1]['response_keys'], contains('models'));
    });

    test('模型列表失败记录网关错误明文', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StaticAdapter((options) async {
        return ResponseBody.fromString(
          jsonEncode({
            'error': 'access_denied',
            'message': 'client IP is not allowed',
          }),
          403,
          statusMessage: 'Forbidden',
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final client = HanakoBackendClient(
        aiBaseUrl: 'https://ai.test',
        authBaseUrl: 'https://auth.test',
        dio: dio,
        publicStoryDiagnosticsLog: DiagnosticsLog(logFile),
      );

      await expectLater(
        client.listPublicStoryModels(),
        throwsA(isA<HanakoBackendException>()),
      );

      final lines = _readJsonLines(logFile);
      expect(lines, hasLength(2));
      final failure = lines[1];
      expect(failure['event'], 'transport_failure');
      expect(failure['operation'], 'public_story_models');
      expect(failure['status_code'], 403);
      expect(failure['gateway_error_code'], 'access_denied');
      expect(failure['gateway_error_message'], 'client IP is not allowed');
      expect(failure['details'], contains('服务端返回明文'));
    });

    test('注册邮箱发码遇到重复邮箱时给出明确错误', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StaticAdapter((options) async {
        expect(options.method, 'POST');
        expect(options.uri.path, '/api/v1/auth/register_email/start');
        return ResponseBody.fromString(
          jsonEncode({'error': 'email_taken'}),
          409,
          statusMessage: 'Conflict',
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final client = HanakoBackendClient(
        aiBaseUrl: 'https://ai.test',
        authBaseUrl: 'https://auth.test',
        dio: dio,
      );

      await expectLater(
        client.startRegistrationEmail(
          username: 'alice',
          email: 'taken@example.com',
        ),
        throwsA(
          isA<HanakoBackendException>().having(
            (e) => e.message,
            'message',
            contains('该邮箱已绑定其他账号'),
          ),
        ),
      );
    });

    test('工作量证明 400 按认证中心归因并透出明文原因', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StaticAdapter((options) async {
        expect(options.method, 'POST');
        expect(options.uri.path, '/api/v1/auth/pow/challenge');
        return ResponseBody.fromString(
          jsonEncode({
            'error': 'invalid_payload',
            'message': 'pubkey_hash invalid',
          }),
          400,
          statusMessage: 'Bad Request',
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final client = HanakoBackendClient(
        aiBaseUrl: 'https://ai.test',
        authBaseUrl: 'https://auth.test',
        dio: dio,
      );

      await expectLater(
        client.startUserPow(pubkeyHash: 'bad'),
        throwsA(
          isA<HanakoBackendException>()
              .having(
                (e) => e.message,
                'message',
                contains('pubkey_hash invalid'),
              )
              .having((e) => e.message, 'message', isNot(contains('AI 网关')))
              .having(
                (e) => e.details,
                'details',
                contains('请求：POST https://auth.test/api/v1/auth/pow/challenge'),
              ),
        ),
      );
    });

    test('认证中心 400 无明文原因时不误报 AI 网关', () async {
      final dio = Dio();
      dio.httpClientAdapter = _StaticAdapter((options) async {
        expect(options.method, 'POST');
        expect(options.uri.path, '/api/v1/auth/pubkeys/status');
        return ResponseBody.fromString(
          jsonEncode({'error': 'invalid_payload'}),
          400,
          statusMessage: 'Bad Request',
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      final client = HanakoBackendClient(
        aiBaseUrl: 'https://ai.test',
        authBaseUrl: 'https://auth.test',
        dio: dio,
      );

      await expectLater(
        client.fetchUserPowStatus(pubkeyHash: 'bad'),
        throwsA(
          isA<HanakoBackendException>()
              .having((e) => e.message, 'message', contains('认证中心拒绝了请求参数'))
              .having((e) => e.message, 'message', isNot(contains('AI 网关'))),
        ),
      );
    });

    test('流式工具调用按 index 继承前序 id 和 name', () async {
      final keyPair = HanakoKeyPair.generate();
      final dio = Dio();
      dio.httpClientAdapter = _EncryptedChatStreamAdapter([
        _chatSse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_exec',
                    'type': 'function',
                    'function': {'name': 'bash', 'arguments': ''},
                  },
                ],
              },
            },
          ],
        }),
        _chatSse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': '{"command"'},
                  },
                ],
              },
            },
          ],
        }),
        _chatSse({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': ':"echo hi"}'},
                  },
                ],
              },
            },
          ],
        }),
      ]);
      final client = HanakoBackendClient(
        aiBaseUrl: 'https://ai.test',
        authBaseUrl: 'https://auth.test',
        dio: dio,
      );
      await client.handshake(keyPair: keyPair);

      final events = await client
          .chatEvents(
            model: 'test-model',
            messages: const [
              {'role': 'user', 'content': 'run command'},
            ],
            tools: const [
              Tool(
                name: 'bash',
                description: 'run command',
                parameters: {
                  'type': 'object',
                  'properties': {
                    'command': {'type': 'string'},
                  },
                  'required': ['command'],
                },
              ),
            ],
          )
          .toList();

      final starts = events.whereType<ToolCallStart>().toList();
      expect(starts, hasLength(1));
      expect(starts.single.id, 'call_exec');
      expect(starts.single.name, 'bash');

      final args = events.whereType<ToolCallArgsDelta>().toList();
      expect(args, hasLength(2));
      expect(args.map((event) => event.id).toSet(), {'call_exec'});
      expect(
        args.map((event) => event.argsJson).join(),
        '{"command":"echo hi"}',
      );
    });
  });
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

class _EncryptedChatStreamAdapter implements HttpClientAdapter {
  _EncryptedChatStreamAdapter(this.plaintextChunks);

  final List<String> plaintextChunks;
  Uint8List? _aesKey;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    switch (options.uri.path) {
      case '/api/v1/channel/handshake':
        final serverKey = EphemeralKey.generate();
        final request = (options.data as Map).cast<String, dynamic>();
        final payload =
            jsonDecode(request['payload'] as String) as Map<String, dynamic>;
        _aesKey = deriveSharedAesKey(
          serverKey.privateKey,
          payload['ephemeral_pubkey'] as String,
        );
        return ResponseBody.fromString(
          jsonEncode({
            'channel_id': 'test_channel',
            'ephemeral_pubkey': serverKey.publicKeyHex,
            'idle_expires_in': 600,
            'allowed_models': ['test-model'],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      case '/api/v1/llm/chat':
        final key = _aesKey;
        if (key == null) {
          throw StateError('handshake was not called');
        }
        final body = StringBuffer();
        for (final chunk in plaintextChunks) {
          final encrypted = encryptGcm(
            key,
            Uint8List.fromList(utf8.encode(chunk)),
          );
          body
            ..write('data: ')
            ..write(
              jsonEncode({
                'nonce': encrypted.nonceHex,
                'ciphertext': encrypted.ciphertextHex,
                'tag': encrypted.tagHex,
              }),
            )
            ..write('\n\n');
        }
        body.write('data: [DONE]\n\n');
        return ResponseBody.fromString(
          body.toString(),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.textPlainContentType],
          },
        );
    }
    throw StateError('unexpected request: ${options.method} ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

String _chatSse(Map<String, dynamic> payload) =>
    'data: ${jsonEncode(payload)}\n\n';

List<Map<String, dynamic>> _readJsonLines(File file) {
  return file
      .readAsLinesSync()
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList(growable: false);
}
