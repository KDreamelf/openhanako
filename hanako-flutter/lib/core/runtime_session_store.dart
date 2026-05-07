import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../llm/provider.dart';
import 'agent_runtime.dart';

class RuntimeSessionStore {
  RuntimeSessionStore._();

  static const currentVersion = 3;
  static const _uuid = Uuid();

  static void createSessionFile(
    String sessionPath, {
    String? sessionId,
    String? cwd,
  }) {
    final file = File(sessionPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${jsonEncode(_sessionHeader(sessionPath, sessionId: sessionId, cwd: cwd))}\n',
      flush: true,
    );
  }

  static List<RuntimeMessage> loadRuntimeMessages(String sessionPath) {
    final file = File(sessionPath);
    if (!file.existsSync()) return const [];
    final lines = file.readAsLinesSync();
    if (lines.isEmpty) return const [];
    final first = _tryDecodeMap(lines.first);
    if (first != null && first['type'] == 'session') {
      return _loadEntryMessages(lines);
    }
    final legacy = _loadLegacyMessages(lines);
    _migrateLegacyOnRead(sessionPath, legacy);
    return legacy;
  }

  static List<Message> loadVisibleMessages(String sessionPath) {
    return _visibleMessagesFromDisplay(loadDisplayMessages(sessionPath));
  }

  static List<RuntimeDisplayMessage> loadDisplayMessages(String sessionPath) {
    return _displayMessages(loadRuntimeMessages(sessionPath));
  }

  static void replaceVisibleMessages(
    String sessionPath,
    List<Message> messages, {
    String? sessionId,
    String? cwd,
  }) {
    final runtimeMessages = <RuntimeMessage>[];
    for (final message in messages) {
      final text = message.content.trim();
      if (text.isEmpty) continue;
      switch (message.role) {
        case 'user':
          runtimeMessages.add(RuntimeMessage.userText(message.content));
        case 'assistant':
          runtimeMessages.add(
            RuntimeMessage.assistant(
              blocks: [RuntimeTextBlock(message.content)],
              stopReason: 'stop',
            ),
          );
      }
    }
    _rewriteEntryFile(
      sessionPath,
      runtimeMessages,
      sessionId: sessionId,
      cwd: cwd,
    );
  }

  static void appendMessages(
    String sessionPath,
    List<RuntimeMessage> messages, {
    String? sessionId,
    String? cwd,
  }) {
    if (messages.isEmpty) return;
    _ensureEntryFile(sessionPath, sessionId: sessionId, cwd: cwd);
    final file = File(sessionPath);
    var parentId = _lastEntryId(file.readAsLinesSync());
    final now = DateTime.now().toUtc().toIso8601String();
    final sink = file.openSync(mode: FileMode.append);
    try {
      for (final message in messages) {
        final id = _uuid.v4().substring(0, 8);
        final entry = {
          'type': 'message',
          'id': id,
          'parentId': parentId,
          'timestamp': now,
          'message': message.toJson(),
        };
        sink.writeStringSync('${jsonEncode(entry)}\n');
        parentId = id;
      }
    } finally {
      sink.closeSync();
    }
  }

  static List<Map<String, dynamic>> loadOpenAiMessages(
    String sessionPath, {
    String? systemPrompt,
  }) {
    return runtimeMessagesToOpenAi(
      loadRuntimeMessages(sessionPath),
      systemPrompt: systemPrompt,
    );
  }

  static void _ensureEntryFile(
    String sessionPath, {
    String? sessionId,
    String? cwd,
  }) {
    final file = File(sessionPath);
    if (!file.existsSync()) {
      createSessionFile(sessionPath, sessionId: sessionId, cwd: cwd);
      return;
    }
    final lines = file.readAsLinesSync();
    if (lines.isEmpty || lines.every((line) => line.trim().isEmpty)) {
      createSessionFile(sessionPath, sessionId: sessionId, cwd: cwd);
      return;
    }
    final first = _tryDecodeMap(lines.first);
    if (first != null && first['type'] == 'session') return;
    final legacy = _loadLegacyMessages(lines);
    _rewriteEntryFile(sessionPath, legacy, sessionId: sessionId, cwd: cwd);
  }

  static void _migrateLegacyOnRead(
    String sessionPath,
    List<RuntimeMessage> messages,
  ) {
    try {
      _rewriteEntryFile(
        sessionPath,
        messages,
        sessionId: p.basenameWithoutExtension(sessionPath),
      );
    } catch (_) {
      // 读路径必须尽量宽容；迁移失败时保留已解析出的旧消息。
    }
  }

  static void _rewriteEntryFile(
    String sessionPath,
    List<RuntimeMessage> messages, {
    String? sessionId,
    String? cwd,
  }) {
    final file = File(sessionPath);
    file.parent.createSync(recursive: true);
    String? parentId;
    final lines = <String>[
      jsonEncode(_sessionHeader(sessionPath, sessionId: sessionId, cwd: cwd)),
    ];
    final now = DateTime.now().toUtc().toIso8601String();
    for (final message in messages) {
      final id = _uuid.v4().substring(0, 8);
      lines.add(
        jsonEncode({
          'type': 'message',
          'id': id,
          'parentId': parentId,
          'timestamp': now,
          'message': message.toJson(),
        }),
      );
      parentId = id;
    }
    file.writeAsStringSync('${lines.join('\n')}\n', flush: true);
  }

  static Map<String, dynamic> _sessionHeader(
    String sessionPath, {
    String? sessionId,
    String? cwd,
  }) => {
    'type': 'session',
    'version': currentVersion,
    'id': sessionId ?? p.basenameWithoutExtension(sessionPath),
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    if (cwd != null && cwd.trim().isNotEmpty) 'cwd': cwd,
  };

  static List<RuntimeMessage> _loadEntryMessages(List<String> lines) {
    final out = <RuntimeMessage>[];
    for (final line in lines.skip(1)) {
      final raw = _tryDecodeMap(line);
      if (raw == null || raw['type'] != 'message') continue;
      final message = raw['message'];
      if (message is Map<String, dynamic>) {
        final runtime = RuntimeMessage.fromJson(message);
        if (runtime != null) out.add(runtime);
      } else if (message is Map) {
        final runtime = RuntimeMessage.fromJson(
          message.cast<String, dynamic>(),
        );
        if (runtime != null) out.add(runtime);
      }
    }
    return out;
  }

  static List<RuntimeMessage> _loadLegacyMessages(List<String> lines) {
    final out = <RuntimeMessage>[];
    for (final line in lines) {
      final raw = _tryDecodeMap(line);
      if (raw == null) continue;
      final runtime = RuntimeMessage.fromOpenAiJson(raw);
      if (runtime != null) out.add(runtime);
    }
    return out;
  }

  static List<RuntimeDisplayMessage> _displayMessages(
    List<RuntimeMessage> runtimeMessages,
  ) {
    final out = <RuntimeDisplayMessage>[];
    var assistantBlocks = <RuntimeDisplayBlock>[];

    void flushAssistant() {
      if (assistantBlocks.isEmpty) return;
      out.add(
        RuntimeDisplayMessage(
          role: 'assistant',
          blocks: List<RuntimeDisplayBlock>.from(assistantBlocks),
        ),
      );
      assistantBlocks = <RuntimeDisplayBlock>[];
    }

    for (final message in runtimeMessages) {
      switch (message.role) {
        case 'user':
          flushAssistant();
          final text = message.visibleText.trim();
          if (text.isNotEmpty) {
            out.add(RuntimeDisplayMessage.userText(text));
          }
        case 'assistant':
          for (final block in message.content) {
            switch (block) {
              case RuntimeTextBlock(:final text):
                if (text.trim().isNotEmpty) {
                  assistantBlocks.add(RuntimeDisplayTextBlock(text));
                }
              case RuntimeThinkingBlock(:final thinking):
                if (thinking.trim().isNotEmpty) {
                  assistantBlocks.add(RuntimeDisplayThinkingBlock(thinking));
                }
              case RuntimeToolCallBlock():
                if (block.name.trim().isNotEmpty) {
                  assistantBlocks.add(
                    RuntimeDisplayToolCallBlock(
                      id: block.id,
                      name: block.name,
                      argsJson: block.openAiArgumentsJson,
                    ),
                  );
                }
              case RuntimeDetailsBlock():
                break;
            }
          }
        case 'toolResult':
          break;
      }
    }
    flushAssistant();
    return out;
  }

  static List<Message> _visibleMessagesFromDisplay(
    List<RuntimeDisplayMessage> displayMessages,
  ) {
    final out = <Message>[];
    for (final message in displayMessages) {
      final text = message.visibleText.trim();
      if (text.isEmpty) {
        continue;
      }
      out.add(Message(role: message.role, content: text));
    }
    return out;
  }

  static String? _lastEntryId(List<String> lines) {
    String? last;
    for (final line in lines.skip(1)) {
      final raw = _tryDecodeMap(line);
      if (raw == null || raw['type'] == 'session') continue;
      final id = raw['id'];
      if (id is String && id.trim().isNotEmpty) last = id;
    }
    return last;
  }

  static Map<String, dynamic>? _tryDecodeMap(String line) {
    if (line.trim().isEmpty) return null;
    try {
      final raw = jsonDecode(line);
      if (raw is Map<String, dynamic>) return raw;
      if (raw is Map) return raw.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }
}

class RuntimeDisplayMessage {
  const RuntimeDisplayMessage({required this.role, required this.blocks});

  factory RuntimeDisplayMessage.userText(String text) => RuntimeDisplayMessage(
    role: 'user',
    blocks: [RuntimeDisplayTextBlock(text)],
  );

  final String role;
  final List<RuntimeDisplayBlock> blocks;

  String get visibleText {
    final parts = <String>[];
    for (final block in blocks) {
      if (block is RuntimeDisplayTextBlock && block.text.trim().isNotEmpty) {
        parts.add(block.text.trim());
      }
    }
    return parts.join('\n\n');
  }

  String get copyText {
    final parts = <String>[];
    for (final block in blocks) {
      switch (block) {
        case RuntimeDisplayTextBlock(:final text):
          if (text.trim().isNotEmpty) parts.add(text.trim());
        case RuntimeDisplayThinkingBlock(:final text):
          if (text.trim().isNotEmpty) parts.add('思考：\n${text.trim()}');
        case RuntimeDisplayToolCallBlock(:final name, :final argsJson):
          parts.add(
            argsJson.trim().isEmpty || argsJson.trim() == '{}'
                ? '工具调用：$name'
                : '工具调用：$name\n$argsJson',
          );
      }
    }
    return parts.join('\n\n');
  }

  Message toVisibleMessage() => Message(role: role, content: visibleText);
}

sealed class RuntimeDisplayBlock {
  const RuntimeDisplayBlock();
}

class RuntimeDisplayTextBlock extends RuntimeDisplayBlock {
  const RuntimeDisplayTextBlock(this.text);
  final String text;
}

class RuntimeDisplayThinkingBlock extends RuntimeDisplayBlock {
  const RuntimeDisplayThinkingBlock(this.text);
  final String text;
}

class RuntimeDisplayToolCallBlock extends RuntimeDisplayBlock {
  const RuntimeDisplayToolCallBlock({
    required this.id,
    required this.name,
    required this.argsJson,
  });

  final String id;
  final String name;
  final String argsJson;
}
