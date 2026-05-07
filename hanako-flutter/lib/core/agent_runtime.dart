import 'dart:async';
import 'dart:convert';

import '../llm/provider.dart';

typedef RuntimeChatStream =
    Stream<LlmEvent> Function({
      required List<Map<String, dynamic>> messages,
      required List<Tool> tools,
      Object? toolChoice,
    });

typedef RuntimeToolExecutor =
    Future<RuntimeToolExecutionResult> Function(RuntimeToolCallBlock call);

typedef RuntimeMessageSink =
    FutureOr<void> Function(List<RuntimeMessage> messages);

class AgentRuntimeLoop {
  AgentRuntimeLoop({
    required List<RuntimeMessage> history,
    required this.systemPrompt,
    required this.tools,
    required this.streamChat,
    required this.executeTool,
    required this.onNewMessages,
  }) : _context = [...history];

  final String systemPrompt;
  final List<Tool> tools;
  final RuntimeChatStream streamChat;
  final RuntimeToolExecutor executeTool;
  final RuntimeMessageSink onNewMessages;
  final List<RuntimeMessage> _context;

  Stream<LlmEvent> runUserPrompt(String text) async* {
    final user = RuntimeMessage.userText(text);
    _context.add(user);
    await onNewMessages([user]);
    yield* continueAssistantTurn();
  }

  Stream<LlmEvent> continueAssistantTurn() async* {
    while (true) {
      final blocks = <RuntimeContentBlock>[];
      final toolCallsById = <String, _PendingRuntimeToolCall>{};
      final thinkingParser = ThinkingTagStreamParser();
      LlmError? error;

      void appendText(String value) {
        _appendTextBlock(blocks, value);
      }

      void appendThinking(String value) {
        _appendThinkingBlock(blocks, value);
      }

      try {
        await for (final event in streamChat(
          messages: runtimeMessagesToOpenAi(
            _context,
            systemPrompt: systemPrompt,
          ),
          tools: tools,
          toolChoice: tools.isEmpty ? null : 'auto',
        )) {
          switch (event) {
            case TextDelta(:final text):
              for (final part in thinkingParser.push(text)) {
                switch (part) {
                  case AssistantTextPart(:final text):
                    appendText(text);
                    yield TextDelta(text);
                  case AssistantThinkingPart(:final text):
                    appendThinking(text);
                    yield ThinkingDelta(text);
                }
              }
            case ThinkingDelta(:final text):
              appendThinking(text);
              yield event;
            case ToolCallStart(:final id, :final name, :final thoughtSignature):
              final call = toolCallsById.putIfAbsent(
                id,
                () =>
                    _PendingRuntimeToolCall(id: id, blockIndex: blocks.length),
              );
              call.name = name;
              call.thoughtSignature ??= thoughtSignature;
              _upsertToolCallBlock(blocks, call);
              yield event;
            case ToolCallArgsDelta(:final id, :final argsJson):
              final call = toolCallsById.putIfAbsent(
                id,
                () =>
                    _PendingRuntimeToolCall(id: id, blockIndex: blocks.length),
              );
              call.argsJson.write(argsJson);
              _upsertToolCallBlock(blocks, call);
              yield event;
            case ToolCallEnd(:final id):
              final call = toolCallsById[id];
              if (call != null) {
                call.ended = true;
                _upsertToolCallBlock(blocks, call);
              }
              yield event;
            case MessageDone():
              break;
            case LlmError():
              error = event;
          }
          if (error != null) break;
        }
      } catch (e) {
        error = LlmError(message: '发送对话失败：客户端处理异常', details: e.toString());
      }

      for (final part in thinkingParser.flush()) {
        switch (part) {
          case AssistantTextPart(:final text):
            appendText(text);
            yield TextDelta(text);
          case AssistantThinkingPart(:final text):
            appendThinking(text);
            yield ThinkingDelta(text);
        }
      }

      if (error != null) {
        yield error;
        return;
      }

      for (final call in toolCallsById.values) {
        if (!call.ended) {
          call.ended = true;
          _upsertToolCallBlock(blocks, call);
          yield ToolCallEnd(call.id);
        }
      }

      final assistant = RuntimeMessage.assistant(
        blocks: blocks,
        stopReason: 'stop',
      );
      _context.add(assistant);
      await onNewMessages([assistant]);

      final toolCalls = assistant.toolCalls;
      if (toolCalls.isEmpty) {
        yield const MessageDone();
        return;
      }

      for (final call in toolCalls) {
        final result = await _executeToolSafely(call);
        final resultMessage = RuntimeMessage.toolResult(
          toolCallId: call.id,
          toolName: call.name,
          content: result.content,
          isError: result.isError,
          details: result.details,
        );
        _context.add(resultMessage);
        await onNewMessages([resultMessage]);
      }
    }
  }

  Future<RuntimeToolExecutionResult> _executeToolSafely(
    RuntimeToolCallBlock call,
  ) async {
    try {
      return await executeTool(call);
    } catch (e) {
      return RuntimeToolExecutionResult(
        content: const JsonEncoder.withIndent('  ').convert({
          'ok': false,
          'error': 'tool_failed',
          'tool': call.name,
          'message': e.toString(),
        }),
        isError: true,
      );
    }
  }
}

class RuntimeMessage {
  RuntimeMessage._({
    required this.role,
    required this.content,
    this.toolCallId,
    this.toolName,
    this.isError = false,
    this.stopReason,
    this.errorMessage,
    this.statusCode,
    this.errorDetails,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  factory RuntimeMessage.userText(String text) =>
      RuntimeMessage._(role: 'user', content: [RuntimeTextBlock(text)]);

  factory RuntimeMessage.assistant({
    required List<RuntimeContentBlock> blocks,
    String? stopReason,
    String? errorMessage,
    int? statusCode,
    String? errorDetails,
  }) => RuntimeMessage._(
    role: 'assistant',
    content: List<RuntimeContentBlock>.from(blocks),
    stopReason: stopReason,
    errorMessage: errorMessage,
    statusCode: statusCode,
    errorDetails: errorDetails,
  );

  factory RuntimeMessage.toolResult({
    required String toolCallId,
    required String toolName,
    required String content,
    bool isError = false,
    Map<String, dynamic>? details,
  }) => RuntimeMessage._(
    role: 'toolResult',
    toolCallId: toolCallId,
    toolName: toolName,
    content: [
      RuntimeTextBlock(content),
      if (details != null) RuntimeDetailsBlock(details),
    ],
    isError: isError,
  );

  final String role;
  final List<RuntimeContentBlock> content;
  final String? toolCallId;
  final String? toolName;
  final bool isError;
  final String? stopReason;
  final String? errorMessage;
  final int? statusCode;
  final String? errorDetails;
  final int timestamp;

  List<RuntimeToolCallBlock> get toolCalls => content
      .whereType<RuntimeToolCallBlock>()
      .where((call) => call.name.trim().isNotEmpty)
      .toList(growable: false);

  String get visibleText => content
      .whereType<RuntimeTextBlock>()
      .map((block) => block.text)
      .where((text) => text.isNotEmpty)
      .join();

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content.map((block) => block.toJson()).toList(growable: false),
    'timestamp': timestamp,
    if (toolCallId != null) 'toolCallId': toolCallId,
    if (toolName != null) 'toolName': toolName,
    if (isError) 'isError': true,
    if (stopReason != null) 'stopReason': stopReason,
    if (errorMessage != null) 'errorMessage': errorMessage,
    if (statusCode != null) 'statusCode': statusCode,
    if (errorDetails != null) 'errorDetails': errorDetails,
  };

  static RuntimeMessage? fromJson(Map<String, dynamic> json) {
    final role = json['role'];
    if (role is! String || role.trim().isEmpty) return null;
    final blocks = _contentBlocksFromJson(json['content']);
    if (role == 'toolResult') {
      final toolCallId = json['toolCallId'] ?? json['tool_call_id'];
      final toolName = json['toolName'] ?? json['name'];
      if (toolCallId is! String || toolName is! String) return null;
      return RuntimeMessage._(
        role: 'toolResult',
        toolCallId: toolCallId,
        toolName: toolName,
        content: blocks,
        isError: json['isError'] == true,
        timestamp: _timestampFromJson(json['timestamp']),
      );
    }
    return RuntimeMessage._(
      role: role,
      content: blocks,
      stopReason: json['stopReason'] as String?,
      errorMessage: json['errorMessage'] as String?,
      statusCode: (json['statusCode'] as num?)?.toInt(),
      errorDetails: json['errorDetails'] as String?,
      timestamp: _timestampFromJson(json['timestamp']),
    );
  }

  static RuntimeMessage? fromOpenAiJson(Map<String, dynamic> raw) {
    final role = raw['role'];
    if (role is! String || role.trim().isEmpty) return null;
    final content = _openAiContentText(raw['content']);
    switch (role) {
      case 'system':
        return null;
      case 'user':
        if (content.trim().isEmpty) return null;
        return RuntimeMessage.userText(content);
      case 'assistant':
        final blocks = <RuntimeContentBlock>[
          if (content.isNotEmpty) RuntimeTextBlock(content),
          ..._toolCallsFromOpenAi(raw['tool_calls']),
        ];
        if (blocks.isEmpty) return null;
        return RuntimeMessage.assistant(
          blocks: blocks,
          stopReason: raw['stopReason'] as String?,
          errorMessage: raw['errorMessage'] as String?,
          statusCode: (raw['statusCode'] as num?)?.toInt(),
          errorDetails: raw['errorDetails'] as String?,
        );
      case 'tool':
      case 'function':
        final id = raw['tool_call_id'];
        final name = raw['name'];
        if (id is! String || id.trim().isEmpty) return null;
        return RuntimeMessage.toolResult(
          toolCallId: id,
          toolName: name is String && name.trim().isNotEmpty
              ? name
              : 'unknown_tool',
          content: content,
          isError: _toolContentLooksError(content),
        );
      default:
        return null;
    }
  }
}

abstract class RuntimeContentBlock {
  const RuntimeContentBlock();

  String get type;

  Map<String, dynamic> toJson();

  static RuntimeContentBlock? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    if (type is! String) return null;
    switch (type) {
      case 'text':
        return RuntimeTextBlock(raw['text']?.toString() ?? '');
      case 'thinking':
        return RuntimeThinkingBlock(
          thinking: raw['thinking']?.toString() ?? '',
          thinkingSignature: raw['thinkingSignature']?.toString(),
        );
      case 'toolCall':
        final id = raw['id']?.toString();
        final name = raw['name']?.toString();
        if (id == null || name == null) return null;
        return RuntimeToolCallBlock(
          id: id,
          name: name,
          argumentsJson: raw['argumentsJson']?.toString(),
          thoughtSignature:
              (raw['thoughtSignature'] ?? raw['thought_signature'])?.toString(),
          ended: raw['ended'] == true,
        );
      case 'details':
        final details = raw['details'];
        if (details is Map<String, dynamic>) {
          return RuntimeDetailsBlock(details);
        }
        if (details is Map) {
          return RuntimeDetailsBlock(details.cast<String, dynamic>());
        }
        return null;
      default:
        return null;
    }
  }
}

class RuntimeTextBlock extends RuntimeContentBlock {
  const RuntimeTextBlock(this.text);

  final String text;

  @override
  String get type => 'text';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'text': text};
}

class RuntimeThinkingBlock extends RuntimeContentBlock {
  const RuntimeThinkingBlock({required this.thinking, this.thinkingSignature});

  final String thinking;
  final String? thinkingSignature;

  @override
  String get type => 'thinking';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'thinking': thinking,
    if (thinkingSignature != null) 'thinkingSignature': thinkingSignature,
  };
}

class RuntimeToolCallBlock extends RuntimeContentBlock {
  const RuntimeToolCallBlock({
    required this.id,
    required this.name,
    this.argumentsJson,
    this.thoughtSignature,
    this.ended = false,
  });

  final String id;
  final String name;
  final String? argumentsJson;
  final String? thoughtSignature;
  final bool ended;

  @override
  String get type => 'toolCall';

  Map<String, dynamic> get arguments {
    final raw = argumentsJson?.trim();
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) return parsed;
      if (parsed is Map) return parsed.cast<String, dynamic>();
    } catch (_) {}
    return <String, dynamic>{'raw': raw};
  }

  String get openAiArgumentsJson {
    final raw = argumentsJson?.trim();
    if (raw == null || raw.isEmpty) return '{}';
    try {
      jsonDecode(raw);
      return raw;
    } catch (_) {
      return jsonEncode(arguments);
    }
  }

  RuntimeToolCallBlock copyWith({
    String? name,
    String? argumentsJson,
    String? thoughtSignature,
    bool? ended,
  }) => RuntimeToolCallBlock(
    id: id,
    name: name ?? this.name,
    argumentsJson: argumentsJson ?? this.argumentsJson,
    thoughtSignature: thoughtSignature ?? this.thoughtSignature,
    ended: ended ?? this.ended,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'id': id,
    'name': name,
    'argumentsJson': openAiArgumentsJson,
    if (thoughtSignature != null) 'thoughtSignature': thoughtSignature,
    if (ended) 'ended': true,
  };
}

class RuntimeDetailsBlock extends RuntimeContentBlock {
  const RuntimeDetailsBlock(this.details);

  final Map<String, dynamic> details;

  @override
  String get type => 'details';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'details': details};
}

class RuntimeToolExecutionResult {
  const RuntimeToolExecutionResult({
    required this.content,
    this.isError = false,
    this.details,
  });

  final String content;
  final bool isError;
  final Map<String, dynamic>? details;
}

List<Map<String, dynamic>> runtimeMessagesToOpenAi(
  List<RuntimeMessage> messages, {
  String? systemPrompt,
}) {
  final transformed = _mergeConsecutiveUserMessages(
    _insertSyntheticToolResults(messages),
  );
  final out = <Map<String, dynamic>>[
    if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
      {'role': 'system', 'content': systemPrompt.trim()},
  ];
  for (final message in transformed) {
    final openAi = _runtimeMessageToOpenAi(message);
    if (openAi != null) out.add(openAi);
  }
  return out;
}

List<RuntimeMessage> _mergeConsecutiveUserMessages(
  List<RuntimeMessage> messages,
) {
  final result = <RuntimeMessage>[];
  for (final message in messages) {
    if (message.role == 'user' &&
        result.isNotEmpty &&
        result.last.role == 'user') {
      final previous = result.removeLast();
      final merged = [previous.visibleText, message.visibleText]
          .map((text) => text.trim())
          .where((text) => text.isNotEmpty)
          .join('\n\n');
      result.add(RuntimeMessage.userText(merged));
      continue;
    }
    result.add(message);
  }
  return result;
}

List<RuntimeMessage> _insertSyntheticToolResults(
  List<RuntimeMessage> messages,
) {
  final result = <RuntimeMessage>[];
  var pending = <RuntimeToolCallBlock>[];
  var resultIds = <String>{};

  void flushPending() {
    if (pending.isEmpty) return;
    for (final call in pending) {
      if (resultIds.contains(call.id)) continue;
      result.add(
        RuntimeMessage.toolResult(
          toolCallId: call.id,
          toolName: call.name,
          content: 'No result provided',
          isError: true,
        ),
      );
    }
    pending = <RuntimeToolCallBlock>[];
    resultIds = <String>{};
  }

  for (final message in messages) {
    if (message.role == 'assistant') {
      flushPending();
      if (message.stopReason == 'error' || message.stopReason == 'aborted') {
        continue;
      }
      pending = message.toolCalls;
      resultIds = <String>{};
      result.add(message);
      continue;
    }
    if (message.role == 'toolResult') {
      if (message.toolCallId != null) resultIds.add(message.toolCallId!);
      result.add(message);
      continue;
    }
    if (message.role == 'user') {
      flushPending();
      result.add(message);
      continue;
    }
    result.add(message);
  }
  return result;
}

Map<String, dynamic>? _runtimeMessageToOpenAi(RuntimeMessage message) {
  switch (message.role) {
    case 'user':
      final text = message.visibleText.trim();
      if (text.isEmpty) return null;
      return {'role': 'user', 'content': text};
    case 'assistant':
      final text = message.visibleText;
      final toolCalls = message.toolCalls;
      if (text.trim().isEmpty && toolCalls.isEmpty) return null;
      return {
        'role': 'assistant',
        'content': text,
        if (toolCalls.isNotEmpty)
          'tool_calls': toolCalls
              .map(
                (call) => {
                  'id': call.id,
                  'type': 'function',
                  'function': {
                    'name': call.name,
                    'arguments': call.openAiArgumentsJson,
                    if (call.thoughtSignature?.trim().isNotEmpty == true)
                      'thought_signature': call.thoughtSignature!.trim(),
                  },
                },
              )
              .toList(growable: false),
      };
    case 'toolResult':
      final toolCallId = message.toolCallId;
      if (toolCallId == null || toolCallId.trim().isEmpty) return null;
      return {
        'role': 'tool',
        'tool_call_id': toolCallId,
        if (message.toolName?.trim().isNotEmpty == true)
          'name': message.toolName!.trim(),
        'content': message.visibleText,
      };
    default:
      return null;
  }
}

sealed class AssistantContentPart {
  const AssistantContentPart();
}

class AssistantTextPart extends AssistantContentPart {
  const AssistantTextPart(this.text);
  final String text;
}

class AssistantThinkingPart extends AssistantContentPart {
  const AssistantThinkingPart(this.text);
  final String text;
}

class ThinkingTagStreamParser {
  final StringBuffer _buffer = StringBuffer();
  bool _insideThinking = false;

  static const _openTags = ['<think>', '<thinking>'];
  static const _closeTags = ['</think>', '</thinking>'];
  static const _maxTagLength = 11;

  List<AssistantContentPart> push(String chunk) {
    _buffer.write(chunk);
    return _drain(flush: false);
  }

  List<AssistantContentPart> flush() => _drain(flush: true);

  List<AssistantContentPart> _drain({required bool flush}) {
    final out = <AssistantContentPart>[];
    while (true) {
      final s = _buffer.toString();
      if (s.isEmpty) break;

      if (_insideThinking) {
        final close = _firstTag(s, _closeTags);
        if (close == null) {
          final emitLength = flush ? s.length : _safeEmitLength(s.length);
          if (emitLength <= 0) break;
          out.add(AssistantThinkingPart(s.substring(0, emitLength)));
          _replaceBuffer(s.substring(emitLength));
          continue;
        }
        if (close.index > 0) {
          out.add(AssistantThinkingPart(s.substring(0, close.index)));
        }
        _replaceBuffer(s.substring(close.index + close.tag.length));
        _insideThinking = false;
        continue;
      }

      final open = _firstTag(s, _openTags);
      if (open == null) {
        final emitLength = flush ? s.length : _safeEmitLength(s.length);
        if (emitLength <= 0) break;
        out.add(AssistantTextPart(s.substring(0, emitLength)));
        _replaceBuffer(s.substring(emitLength));
        continue;
      }
      if (open.index > 0) {
        out.add(AssistantTextPart(s.substring(0, open.index)));
      }
      _replaceBuffer(s.substring(open.index + open.tag.length));
      _insideThinking = true;
    }
    return out;
  }

  int _safeEmitLength(int length) {
    if (length <= _maxTagLength) return 0;
    return length - _maxTagLength;
  }

  void _replaceBuffer(String value) {
    _buffer
      ..clear()
      ..write(value);
  }

  _TagMatch? _firstTag(String s, List<String> tags) {
    _TagMatch? best;
    for (final tag in tags) {
      final index = s.indexOf(tag);
      if (index < 0) continue;
      if (best == null || index < best.index) {
        best = _TagMatch(index: index, tag: tag);
      }
    }
    return best;
  }
}

class _PendingRuntimeToolCall {
  _PendingRuntimeToolCall({required this.id, required this.blockIndex});

  final String id;
  final int blockIndex;
  String name = '';
  String? thoughtSignature;
  bool ended = false;
  final StringBuffer argsJson = StringBuffer();

  RuntimeToolCallBlock toBlock() => RuntimeToolCallBlock(
    id: id,
    name: name,
    argumentsJson: argsJson.toString().trim().isEmpty
        ? '{}'
        : argsJson.toString(),
    thoughtSignature: thoughtSignature,
    ended: ended,
  );
}

class _TagMatch {
  const _TagMatch({required this.index, required this.tag});

  final int index;
  final String tag;
}

void _appendTextBlock(List<RuntimeContentBlock> blocks, String text) {
  if (text.isEmpty) return;
  if (blocks.isNotEmpty && blocks.last is RuntimeTextBlock) {
    final last = blocks.removeLast() as RuntimeTextBlock;
    blocks.add(RuntimeTextBlock('${last.text}$text'));
    return;
  }
  blocks.add(RuntimeTextBlock(text));
}

void _appendThinkingBlock(List<RuntimeContentBlock> blocks, String text) {
  if (text.isEmpty) return;
  if (blocks.isNotEmpty && blocks.last is RuntimeThinkingBlock) {
    final last = blocks.removeLast() as RuntimeThinkingBlock;
    blocks.add(
      RuntimeThinkingBlock(
        thinking: '${last.thinking}$text',
        thinkingSignature: last.thinkingSignature,
      ),
    );
    return;
  }
  blocks.add(RuntimeThinkingBlock(thinking: text));
}

void _upsertToolCallBlock(
  List<RuntimeContentBlock> blocks,
  _PendingRuntimeToolCall call,
) {
  final block = call.toBlock();
  if (call.blockIndex < blocks.length &&
      blocks[call.blockIndex] is RuntimeToolCallBlock) {
    blocks[call.blockIndex] = block;
    return;
  }
  blocks.add(block);
}

List<RuntimeContentBlock> _contentBlocksFromJson(Object? raw) {
  if (raw is String) return [RuntimeTextBlock(raw)];
  if (raw is! List) return const [];
  final blocks = <RuntimeContentBlock>[];
  for (final item in raw) {
    final block = RuntimeContentBlock.fromJson(item);
    if (block != null) blocks.add(block);
  }
  return blocks;
}

String _openAiContentText(Object? content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    return content.map((item) {
      if (item is Map) {
        final type = item['type'];
        final text = item['text'];
        if ((type == 'text' || type == null) && text is String) return text;
      }
      return '';
    }).join();
  }
  return content.toString();
}

List<RuntimeToolCallBlock> _toolCallsFromOpenAi(Object? raw) {
  if (raw is! List) return const [];
  final out = <RuntimeToolCallBlock>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map) continue;
    final id = (item['id'] ?? item['call_id'] ?? 'tool_call_$i').toString();
    final function = item['function'];
    String? name;
    String? argsJson;
    String? thoughtSignature;
    if (function is Map) {
      name = function['name']?.toString();
      final args = function['arguments'];
      if (args is String) {
        argsJson = args;
      } else if (args is Map) {
        argsJson = jsonEncode(args);
      }
      thoughtSignature =
          (function['thought_signature'] ?? function['thoughtSignature'])
              ?.toString();
    } else {
      name = item['name']?.toString();
      final args = item['arguments'] ?? item['input'];
      if (args is String) {
        argsJson = args;
      } else if (args is Map) {
        argsJson = jsonEncode(args);
      }
      thoughtSignature = (item['thought_signature'] ?? item['thoughtSignature'])
          ?.toString();
    }
    if (name == null || name.trim().isEmpty) continue;
    out.add(
      RuntimeToolCallBlock(
        id: id,
        name: name,
        argumentsJson: argsJson ?? '{}',
        thoughtSignature: thoughtSignature,
        ended: true,
      ),
    );
  }
  return out;
}

int? _timestampFromJson(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) {
    final parsed = DateTime.tryParse(raw);
    return parsed?.millisecondsSinceEpoch;
  }
  return null;
}

bool _toolContentLooksError(String content) {
  try {
    final parsed = jsonDecode(content);
    return parsed is Map && parsed['ok'] == false;
  } catch (_) {
    return false;
  }
}
