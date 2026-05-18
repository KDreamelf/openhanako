import 'package:dio/dio.dart';

/// LLM 抽象层。
///
/// **协议契约**：本接口与 [LlmEvent] / [Message] / [Tool] 是协议契约，
/// 终态的 HanakoGatewayProvider（私有 AI 网关 client）也将实现这套接口，
/// 上层调用方代码不变。详见 [lib/llm/README.md]。
///
/// 当前 6 个具体实现（openai/anthropic/dashscope/volcengine/minimax/codex_oauth）
/// 是过渡期产物，等用户后端 + 私有 AI 网关上线后会被一并替换。
abstract class LlmProvider {
  String get name;
  Stream<LlmEvent> chat({
    required List<Message> messages,
    required String model,
    List<Tool>? tools,
    bool? thinking,
    CancelToken? cancelToken,
  });
}

class Message {
  final String role;
  final String content;
  const Message({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

class Tool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  const Tool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  Map<String, dynamic> toOpenAI() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// 流式事件（sealed 强制 exhaustive switch）。
sealed class LlmEvent {
  const LlmEvent();
}

class TextDelta extends LlmEvent {
  final String text;
  const TextDelta(this.text);
}

class ThinkingDelta extends LlmEvent {
  final String text;
  const ThinkingDelta(this.text);
}

class ToolCallStart extends LlmEvent {
  final String id;
  final String name;
  final String? thoughtSignature;
  const ToolCallStart({
    required this.id,
    required this.name,
    this.thoughtSignature,
  });
}

class ToolCallArgsDelta extends LlmEvent {
  final String id;
  final String argsJson;
  const ToolCallArgsDelta({required this.id, required this.argsJson});
}

class ToolCallEnd extends LlmEvent {
  final String id;
  const ToolCallEnd(this.id);
}

class ToolCallResult extends LlmEvent {
  final String id;
  final String name;
  final String content;
  final bool isError;
  final Map<String, dynamic>? details;
  const ToolCallResult({
    required this.id,
    required this.name,
    required this.content,
    this.isError = false,
    this.details,
  });
}

class MessageDone extends LlmEvent {
  final String? finishReason;
  const MessageDone({this.finishReason});
}

/// 流式响应中附带的 token 用量（通常在最后一个 chunk 里出现一次）。
/// 对应 OpenAI 标准的 `usage` 字段。
class TokenUsage extends LlmEvent {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int? cachedTokens;
  const TokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    this.cachedTokens,
  });
}

class LlmError extends LlmEvent {
  final String message;
  final int? statusCode;
  final String? details;
  const LlmError({required this.message, this.statusCode, this.details});
}
