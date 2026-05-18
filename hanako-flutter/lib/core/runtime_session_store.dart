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
    var toolCallIndices = <String, int>{};

    void flushAssistant() {
      if (assistantBlocks.isEmpty) return;
      out.add(
        RuntimeDisplayMessage(
          role: 'assistant',
          blocks: List<RuntimeDisplayBlock>.from(assistantBlocks),
        ),
      );
      assistantBlocks = <RuntimeDisplayBlock>[];
      toolCallIndices = <String, int>{};
    }

    for (final message in runtimeMessages) {
      switch (message.role) {
        case 'user':
          flushAssistant();
          final blocks = _displayBlocksFromContent(message.content);
          if (blocks.isNotEmpty) {
            out.add(RuntimeDisplayMessage(role: 'user', blocks: blocks));
          }
        case 'assistant':
          final messageStartIndex = assistantBlocks.length;
          for (final block in message.content) {
            switch (block) {
              case RuntimeTextBlock(:final text):
                _appendAssistantDisplayBlocks(
                  assistantBlocks,
                  displayBlocksFromMarkdownLinks(text),
                  messageStartIndex: messageStartIndex,
                );
              case RuntimeImageBlock():
                final display = RuntimeDisplayImageBlock.fromRuntime(block);
                if (display != null) assistantBlocks.add(display);
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
                  toolCallIndices[block.id] = assistantBlocks.length - 1;
                }
              case RuntimeDetailsBlock():
                break;
            }
          }
        case 'toolResult':
          final toolCallId = message.toolCallId?.trim();
          if (toolCallId == null || toolCallId.isEmpty) break;
          final resultContent = message.visibleText;
          final resultDetails = _detailsFromMessage(message);
          final existingIndex = toolCallIndices[toolCallId];
          var attachedToExisting = false;
          if (existingIndex != null && existingIndex < assistantBlocks.length) {
            final existing = assistantBlocks[existingIndex];
            if (existing is RuntimeDisplayToolCallBlock) {
              assistantBlocks[existingIndex] = existing.copyWith(
                resultContent: resultContent,
                resultIsError: message.isError,
                resultDetails: resultDetails,
              );
              attachedToExisting = true;
            }
          }
          if (!attachedToExisting) {
            assistantBlocks.add(
              RuntimeDisplayToolCallBlock(
                id: toolCallId,
                name: message.toolName ?? 'unknown_tool',
                argsJson: '{}',
                resultContent: resultContent,
                resultIsError: message.isError,
                resultDetails: resultDetails,
              ),
            );
            toolCallIndices[toolCallId] = assistantBlocks.length - 1;
          }
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

  factory RuntimeDisplayMessage.userBlocks(List<RuntimeContentBlock> blocks) =>
      RuntimeDisplayMessage(
        role: 'user',
        blocks: _displayBlocksFromContent(blocks),
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
        case RuntimeDisplayImageBlock(:final label, :final path):
          final name = label?.trim().isNotEmpty == true
              ? label!.trim()
              : path?.trim().isNotEmpty == true
              ? p.basename(path!.trim())
              : '图片';
          parts.add('[图片：$name]');
        case RuntimeDisplayFileBlock(:final label, :final path, :final exists):
          parts.add('[文件：$label]\n$path${exists ? '' : '\n状态：文件不存在'}');
        case RuntimeDisplayLinkBlock(:final label, :final url):
          parts.add('[链接：$label]\n$url');
        case RuntimeDisplayThinkingBlock(:final text):
          if (text.trim().isNotEmpty) parts.add('思考：\n${text.trim()}');
        case RuntimeDisplayToolCallBlock(
          :final name,
          :final argsJson,
          :final resultContent,
          :final resultIsError,
        ):
          final lines = <String>[
            argsJson.trim().isEmpty || argsJson.trim() == '{}'
                ? '工具调用：$name'
                : '工具调用：$name\n参数：\n$argsJson',
          ];
          if (resultContent?.trim().isNotEmpty == true) {
            lines.add(
              resultIsError
                  ? '执行结果（失败）：\n${resultContent!.trim()}'
                  : '执行结果：\n${resultContent!.trim()}',
            );
          }
          parts.add(lines.join('\n\n'));
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

class RuntimeDisplayImageBlock extends RuntimeDisplayBlock {
  const RuntimeDisplayImageBlock({
    this.dataUrl,
    this.imageUrl,
    this.path,
    this.mimeType,
    this.label,
  });

  final String? dataUrl;
  final String? imageUrl;
  final String? path;
  final String? mimeType;
  final String? label;

  factory RuntimeDisplayImageBlock.fromAttachment({
    required String dataUrl,
    required String mimeType,
    required String label,
    String? path,
  }) => RuntimeDisplayImageBlock(
    dataUrl: dataUrl,
    mimeType: mimeType,
    label: label,
    path: path,
  );

  static RuntimeDisplayImageBlock? fromRuntime(RuntimeImageBlock block) {
    if (block.dataUrl?.trim().isNotEmpty != true &&
        block.imageUrl?.trim().isNotEmpty != true &&
        block.path?.trim().isNotEmpty != true) {
      return null;
    }
    return RuntimeDisplayImageBlock(
      dataUrl: block.dataUrl,
      imageUrl: block.imageUrl,
      path: block.path,
      mimeType: block.mimeType,
      label: block.label,
    );
  }
}

class RuntimeDisplayFileBlock extends RuntimeDisplayBlock {
  const RuntimeDisplayFileBlock({
    required this.path,
    required this.label,
    this.mimeType,
    this.sizeBytes,
    this.exists = true,
  });

  final String path;
  final String label;
  final String? mimeType;
  final int? sizeBytes;
  final bool exists;
}

class RuntimeDisplayLinkBlock extends RuntimeDisplayBlock {
  const RuntimeDisplayLinkBlock({required this.url, required this.label});

  final String url;
  final String label;
}

class RuntimeDisplayThinkingBlock extends RuntimeDisplayBlock {
  const RuntimeDisplayThinkingBlock(this.text);
  final String text;
}

List<RuntimeDisplayBlock> displayBlocksFromMarkdownLinks(String text) {
  if (text.trim().isEmpty) return const [];
  final matches = _markdownLinks(text).toList(growable: false);
  if (matches.isEmpty) return [RuntimeDisplayTextBlock(text)];

  final out = <RuntimeDisplayBlock>[];
  var cursor = 0;
  var converted = false;
  for (final match in matches) {
    final card = _displayBlockFromMarkdownLink(match.label, match.target);
    if (card == null) continue;
    _appendTextSegment(out, text.substring(cursor, match.start));
    out.add(card);
    cursor = match.end;
    converted = true;
  }
  if (!converted) return [RuntimeDisplayTextBlock(text)];
  _appendTextSegment(out, text.substring(cursor));
  return out;
}

void _appendAssistantDisplayBlocks(
  List<RuntimeDisplayBlock> out,
  List<RuntimeDisplayBlock> blocks, {
  required int messageStartIndex,
}) {
  for (final block in blocks) {
    if (block is RuntimeDisplayTextBlock &&
        _mergeBufferedToolTextTail(out, block, messageStartIndex)) {
      continue;
    }
    out.add(block);
  }
}

bool _mergeBufferedToolTextTail(
  List<RuntimeDisplayBlock> out,
  RuntimeDisplayTextBlock block,
  int messageStartIndex,
) {
  if (out.length < messageStartIndex + 2) return false;
  final previous = out[out.length - 2];
  final divider = out.last;
  if (previous is! RuntimeDisplayTextBlock ||
      divider is! RuntimeDisplayToolCallBlock) {
    return false;
  }
  final tail = block.text.trimRight();
  if (tail.isEmpty || tail.length > 11) return false;
  final before = previous.text.trimRight();
  if (before.isEmpty || RegExp(r'[\n。！？!?；;：:]$').hasMatch(before)) {
    return false;
  }
  out[out.length - 2] = RuntimeDisplayTextBlock(
    '${previous.text}${block.text}',
  );
  return true;
}

Iterable<_MarkdownLinkMatch> _markdownLinks(String text) sync* {
  final pattern = RegExp(r'\[([^\]\n]+)\]\((<[^>\n]+>|[^)\n]+)\)');
  for (final match in pattern.allMatches(text)) {
    if (match.start > 0 && text[match.start - 1] == '!') continue;
    final label = match.group(1)?.trim();
    final target = match.group(2)?.trim();
    if (label == null ||
        label.isEmpty ||
        target == null ||
        target.isEmpty ||
        label.startsWith('!')) {
      continue;
    }
    yield _MarkdownLinkMatch(
      start: match.start,
      end: match.end,
      label: label,
      target: _normalizeMarkdownTarget(target),
    );
  }
}

String _normalizeMarkdownTarget(String target) {
  final trimmed = target.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('<') && trimmed.endsWith('>')) {
    return trimmed.substring(1, trimmed.length - 1).trim();
  }
  return trimmed;
}

RuntimeDisplayBlock? _displayBlockFromMarkdownLink(
  String label,
  String target,
) {
  final filePath = _localFilePathFromLinkTarget(target);
  if (filePath != null) {
    return _fileBlockFromPath(filePath, label: label);
  }
  final uri = Uri.tryParse(target);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  if (uri.host.trim().isEmpty) return null;
  return RuntimeDisplayLinkBlock(url: uri.toString(), label: label);
}

String? _localFilePathFromLinkTarget(String target) {
  final value = target.trim();
  if (value.isEmpty) return null;
  if (p.isAbsolute(value)) return p.normalize(value);
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'file') return null;
  try {
    return p.normalize(uri.toFilePath(windows: Platform.isWindows));
  } catch (_) {
    return null;
  }
}

void _appendTextSegment(List<RuntimeDisplayBlock> out, String text) {
  final cleaned = _cleanMarkdownLinkTextSegment(text);
  if (cleaned.isNotEmpty) {
    out.add(RuntimeDisplayTextBlock(cleaned));
  }
}

String _cleanMarkdownLinkTextSegment(String text) {
  var value = text.trimRight();
  value = value.replaceFirstMapped(
    RegExp(r'(^|\n)\s*[-*+]\s*$'),
    (match) => match.group(1) ?? '',
  );
  value = value.replaceFirstMapped(
    RegExp(r'(^|\n)\s*\d+[.)]\s*$'),
    (match) => match.group(1) ?? '',
  );
  return value.trim();
}

class _MarkdownLinkMatch {
  const _MarkdownLinkMatch({
    required this.start,
    required this.end,
    required this.label,
    required this.target,
  });

  final int start;
  final int end;
  final String label;
  final String target;
}

class RuntimeDisplayToolCallBlock extends RuntimeDisplayBlock {
  const RuntimeDisplayToolCallBlock({
    required this.id,
    required this.name,
    required this.argsJson,
    this.resultContent,
    this.resultIsError = false,
    this.resultDetails,
  });

  final String id;
  final String name;
  final String argsJson;
  final String? resultContent;
  final bool resultIsError;
  final Map<String, dynamic>? resultDetails;

  /// 模型调工具时通过 `_purpose` 字段填入的"一句话中文用途"，UI 上用它代替
  /// 罗列裸 args。argsJson 还在 streaming 累加、JSON 没拼完整时返回 null；
  /// 模型漏填或值为空时也返回 null——上层应当回退到工具中文名 + 参数摘要。
  String? get purpose {
    final raw = argsJson.trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final value = decoded['_purpose'];
        if (value is String) {
          final trimmed = value.trim();
          if (trimmed.isNotEmpty) return trimmed;
        }
      }
    } catch (_) {
      // JSON 尚未拼完整或损坏——交给调用方做兜底。
    }
    return null;
  }

  RuntimeDisplayToolCallBlock copyWith({
    String? name,
    String? argsJson,
    String? resultContent,
    bool? resultIsError,
    Map<String, dynamic>? resultDetails,
  }) => RuntimeDisplayToolCallBlock(
    id: id,
    name: name ?? this.name,
    argsJson: argsJson ?? this.argsJson,
    resultContent: resultContent ?? this.resultContent,
    resultIsError: resultIsError ?? this.resultIsError,
    resultDetails: resultDetails ?? this.resultDetails,
  );
}

Map<String, dynamic>? _detailsFromMessage(RuntimeMessage message) {
  for (final block in message.content) {
    if (block is RuntimeDetailsBlock) return block.details;
  }
  return null;
}

RuntimeDisplayFileBlock? _fileBlockFromPath(
  String rawPath, {
  String? label,
  String? mimeType,
  int? sizeBytes,
}) {
  final path = rawPath.trim();
  if (path.isEmpty || !p.isAbsolute(path)) return null;
  final type = FileSystemEntity.typeSync(path);
  final exists = type != FileSystemEntityType.notFound;
  final statSize = type == FileSystemEntityType.file
      ? File(path).lengthSync()
      : null;
  return RuntimeDisplayFileBlock(
    path: p.normalize(path),
    label: label?.trim().isNotEmpty == true ? label!.trim() : p.basename(path),
    mimeType: mimeType,
    sizeBytes: sizeBytes ?? statSize,
    exists: exists,
  );
}

List<RuntimeDisplayBlock> _displayBlocksFromContent(
  List<RuntimeContentBlock> content,
) {
  final blocks = <RuntimeDisplayBlock>[];
  for (final block in content) {
    switch (block) {
      case RuntimeTextBlock(:final text):
        if (text.trim().isNotEmpty) blocks.add(RuntimeDisplayTextBlock(text));
      case RuntimeImageBlock():
        final display = RuntimeDisplayImageBlock.fromRuntime(block);
        if (display != null) blocks.add(display);
      case RuntimeThinkingBlock(:final thinking):
        if (thinking.trim().isNotEmpty) {
          blocks.add(RuntimeDisplayThinkingBlock(thinking));
        }
      case RuntimeToolCallBlock():
      case RuntimeDetailsBlock():
        break;
    }
  }
  return blocks;
}
