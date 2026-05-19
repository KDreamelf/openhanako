import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:hanako/core/agent_runtime.dart';
import 'package:hanako/core/compact_threshold.dart';
import 'package:hanako/core/conversation_compact.dart';
import 'package:hanako/core/model_manager.dart';
import 'package:hanako/core/runtime_session_store.dart';

void main() {
  group('CompactThresholds', () {
    test('200K model thresholds match CC reference values', () {
      const model = ModelInfo(
        id: 'gpt-5.5',
        name: 'gpt-5.5',
        contextWindow: 200000,
        maxOutputTokens: 32000,
      );
      final t = computeThresholds(model);
      // reservedForSummary = min(32000, 20000) = 20000
      // effectiveWindow = 200000 - 20000 = 180000
      expect(t.effectiveWindow, 180000);
      // autoCompact = 180000 - 13000 = 167000
      expect(t.autoCompactThreshold, 167000);
      // warning = 167000 - 20000 = 147000
      expect(t.warningThreshold, 147000);
    });

    test('64K model thresholds are proportional', () {
      const model = ModelInfo(
        id: 'LongCat-Flash-Chat',
        name: 'LongCat-Flash-Chat',
        contextWindow: 64000,
        maxOutputTokens: 8000,
      );
      final t = computeThresholds(model);
      // reservedForSummary = min(8000, 20000) = 8000
      // effectiveWindow = 64000 - 8000 = 56000
      expect(t.effectiveWindow, 56000);
      expect(t.autoCompactThreshold, 56000 - 13000);
      expect(t.warningThreshold, 56000 - 13000 - 20000);
    });

    test('level classification', () {
      const model = ModelInfo(
        id: 'test',
        name: 'test',
        contextWindow: 200000,
        maxOutputTokens: 32000,
      );
      final t = computeThresholds(model);
      expect(t.level(100000), CompactLevel.normal);
      expect(t.level(t.warningThreshold), CompactLevel.warning);
      expect(t.level(t.warningThreshold + 1), CompactLevel.warning);
      expect(t.level(t.autoCompactThreshold), CompactLevel.critical);
      expect(t.level(t.autoCompactThreshold + 1), CompactLevel.critical);
    });

    test('usagePercent clamped to 0..1', () {
      const model = ModelInfo(
        id: 'test',
        name: 'test',
        contextWindow: 100000,
        maxOutputTokens: 10000,
      );
      final t = computeThresholds(model);
      expect(t.usagePercent(0), 0.0);
      expect(t.usagePercent(t.effectiveWindow), 1.0);
      expect(t.usagePercent(t.effectiveWindow * 2), 1.0);
    });
  });

  group('CompactBoundary in RuntimeMessage', () {
    test('roundtrip through JSON', () {
      final msg = RuntimeMessage.compactBoundary(
        summary: 'test summary',
        reinject: {'recentFiles': ['a.dart'], 'lastPlan': 'plan text'},
      );
      expect(msg.role, 'compactBoundary');
      expect(msg.visibleText, 'test summary');

      final json = msg.toJson();
      final restored = RuntimeMessage.fromJson(json);
      expect(restored, isNotNull);
      expect(restored!.role, 'compactBoundary');
      expect(restored.visibleText, 'test summary');
    });

    test('runtimeMessagesToOpenAi truncates at boundary', () {
      final messages = [
        RuntimeMessage.userText('old question'),
        RuntimeMessage.assistant(
          blocks: [const RuntimeTextBlock('old answer')],
          stopReason: 'stop',
        ),
        RuntimeMessage.compactBoundary(summary: 'summary of old convo'),
        RuntimeMessage.userText('new question'),
        RuntimeMessage.assistant(
          blocks: [const RuntimeTextBlock('new answer')],
          stopReason: 'stop',
        ),
      ];

      final openAi = runtimeMessagesToOpenAi(
        messages,
        systemPrompt: 'you are helpful',
      );

      // System prompt should contain the compact preamble
      final system = openAi.first;
      expect(system['role'], 'system');
      expect(
        (system['content'] as String).contains('summary of old convo'),
        isTrue,
      );

      // Should NOT contain old question/answer as separate messages
      final userMessages =
          openAi.where((m) => m['role'] == 'user').toList();
      expect(userMessages.length, 1);
      expect(userMessages.first['content'], 'new question');

      final assistantMessages =
          openAi.where((m) => m['role'] == 'assistant').toList();
      expect(assistantMessages.length, 1);
      expect(assistantMessages.first['content'], 'new answer');
    });
  });

  group('RuntimeSessionStore compact entries', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('compact_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('appendCompactBoundary creates compact entry in jsonl', () {
      final sessionPath = p.join(tempDir.path, 'test.jsonl');
      RuntimeSessionStore.createSessionFile(sessionPath, sessionId: 'test');
      RuntimeSessionStore.appendMessages(sessionPath, [
        RuntimeMessage.userText('hello'),
        RuntimeMessage.assistant(
          blocks: [const RuntimeTextBlock('hi there')],
          stopReason: 'stop',
        ),
      ]);

      RuntimeSessionStore.appendCompactBoundary(
        sessionPath,
        summary: 'user said hello, assistant said hi',
        reinject: {'recentFiles': ['a.dart']},
      );

      RuntimeSessionStore.appendMessages(sessionPath, [
        RuntimeMessage.userText('new question'),
      ]);

      final messages = RuntimeSessionStore.loadRuntimeMessages(sessionPath);
      expect(messages.length, 4); // user, assistant, boundary, user
      expect(messages[2].role, 'compactBoundary');
      expect(messages[2].visibleText, 'user said hello, assistant said hi');
    });

    test('display messages truncate at boundary', () {
      final sessionPath = p.join(tempDir.path, 'test.jsonl');
      RuntimeSessionStore.createSessionFile(sessionPath, sessionId: 'test');
      RuntimeSessionStore.appendMessages(sessionPath, [
        RuntimeMessage.userText('old msg'),
      ]);
      RuntimeSessionStore.appendCompactBoundary(
        sessionPath,
        summary: 'summary',
      );
      RuntimeSessionStore.appendMessages(sessionPath, [
        RuntimeMessage.userText('new msg'),
      ]);

      final display = RuntimeSessionStore.loadDisplayMessages(sessionPath);
      // Should have: boundary separator + new user message
      expect(display.length, 2);
      expect(display[0].role, 'compactBoundary');
      expect(display[1].role, 'user');
      expect(display[1].visibleText, 'new msg');
    });
  });

  group('buildCompactPreamble', () {
    test('includes transcript file references', () {
      final preamble = buildCompactPreamble('test summary', {
        'transcriptFile': '/path/to/transcript.md',
        'priorTranscripts': ['/path/to/old.md'],
        'recentFiles': ['a.dart', 'b.dart'],
        'lastPlan': 'implement feature X',
      });
      expect(preamble.contains('test summary'), isTrue);
      expect(preamble.contains('/path/to/transcript.md'), isTrue);
      expect(preamble.contains('/path/to/old.md'), isTrue);
      expect(preamble.contains('a.dart'), isTrue);
      expect(preamble.contains('implement feature X'), isTrue);
    });

    test('handles null reinject', () {
      final preamble = buildCompactPreamble('just a summary', null);
      expect(preamble.contains('just a summary'), isTrue);
      expect(preamble.contains('截留存档'), isFalse);
    });
  });
}
