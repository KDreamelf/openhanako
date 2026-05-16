import 'dart:io';

import '../core/runtime_session_store.dart';
import 'experience_store.dart';

class ExperienceSessionCapture {
  const ExperienceSessionCapture._();

  static Future<ExperienceSaveResult> saveSessionAsPrivateExperience({
    required Directory agentDir,
    required String sessionPath,
    required String title,
    String brief = '',
    List<String> keywords = const [],
    int maxMessages = 0,
    DateTime? now,
  }) async {
    final draft = buildDraftFromSession(
      sessionPath: sessionPath,
      maxMessages: maxMessages,
    );
    if (draft.conversation.trim().isEmpty) {
      throw StateError('当前会话没有可写入经验的上下文');
    }
    return ExperienceStore(agentDir: agentDir).savePrivateExperience(
      title: title,
      brief: brief,
      keywords: keywords,
      conversation: draft.conversation,
      events: draft.events,
      now: now,
    );
  }

  static ExperienceSessionDraft buildDraftFromSession({
    required String sessionPath,
    int maxMessages = 0,
  }) {
    final file = File(sessionPath);
    if (!file.existsSync()) {
      throw StateError('会话文件不存在：$sessionPath');
    }
    final messages = RuntimeSessionStore.loadDisplayMessages(sessionPath);
    final selected = maxMessages > 0 && messages.length > maxMessages
        ? messages.sublist(messages.length - maxMessages)
        : messages;
    final conversation = StringBuffer();
    final events = StringBuffer();
    for (var i = 0; i < selected.length; i++) {
      final message = selected[i];
      final role = switch (message.role) {
        'user' => '用户',
        'assistant' => 'AI',
        _ => message.role,
      };
      final text = _conversationText(message).trim();
      if (text.isNotEmpty) {
        conversation
          ..writeln('## ${i + 1}. $role')
          ..writeln()
          ..writeln(text)
          ..writeln();
      }
      for (final block in message.blocks) {
        if (block is! RuntimeDisplayToolCallBlock) continue;
        final args = block.argsJson.trim();
        final result = (block.resultContent ?? '').trim();
        events
          ..writeln('## ${i + 1}. $role 调用 ${block.name}')
          ..writeln()
          ..writeln(args.isEmpty ? '{}' : args);
        if (result.isNotEmpty) {
          events
            ..writeln()
            ..writeln(block.resultIsError ? '失败结果：' : '执行结果：')
            ..writeln(result);
        }
        events.writeln();
      }
    }
    return ExperienceSessionDraft(
      conversation: conversation.toString().trimRight(),
      events: events.toString().trimRight(),
    );
  }

  static String _conversationText(RuntimeDisplayMessage message) {
    final parts = <String>[];
    for (final block in message.blocks) {
      switch (block) {
        case RuntimeDisplayTextBlock(:final text):
          if (text.trim().isNotEmpty) {
            parts.add(text.trim());
          }
        case RuntimeDisplayImageBlock(:final label, :final path):
          final name = label?.trim().isNotEmpty == true
              ? label!.trim()
              : path?.trim().isNotEmpty == true
              ? path!.trim()
              : '图片';
          parts.add('[图片：$name]');
        case RuntimeDisplayFileBlock(:final label, :final path):
          parts.add('[文件：$label]\n$path');
        case RuntimeDisplayLinkBlock(:final label, :final url):
          parts.add('[链接：$label]\n$url');
        case RuntimeDisplayThinkingBlock():
          break;
        case RuntimeDisplayToolCallBlock():
          break;
      }
    }
    return parts.join('\n\n');
  }
}

class ExperienceSessionDraft {
  const ExperienceSessionDraft({
    required this.conversation,
    required this.events,
  });

  final String conversation;
  final String events;
}
