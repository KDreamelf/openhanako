import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/identity/identity.dart';
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

List<Map<String, dynamic>> _readJsonLines(File file) {
  return file
      .readAsLinesSync()
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList(growable: false);
}
