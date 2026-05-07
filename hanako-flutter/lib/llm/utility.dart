import 'dart:async';

import 'package:dio/dio.dart';

import 'provider.dart';

/// 简化的 utility-style LLM 调用：拼 system + user message，等流结束返完整 text。
/// 用于 memory compile / session summary / channel triage / deep memory 等"非交互"
/// 场景，规避手动管理 Stream<LlmEvent>。
///
/// 与 legacy lib/llm/provider-client.js 的 `callProviderText` 对齐。
Future<String> callProviderText({
  required LlmProvider provider,
  required String model,
  required String userContent,
  String? systemPrompt,
  double? temperature,
  int? maxTokens,
  Duration timeout = const Duration(seconds: 60),
  CancelToken? cancelToken,
}) async {
  final messages = <Message>[
    if (systemPrompt != null && systemPrompt.isNotEmpty)
      Message(role: 'system', content: systemPrompt),
    Message(role: 'user', content: userContent),
  ];

  final buf = StringBuffer();
  String? errorMsg;
  final completer = Completer<void>();
  final sub = provider
      .chat(messages: messages, model: model, cancelToken: cancelToken)
      .listen(
        (ev) {
          switch (ev) {
            case TextDelta(:final text):
              buf.write(text);
            case LlmError(:final message):
              errorMsg = message;
              if (!completer.isCompleted) completer.complete();
            case MessageDone():
              if (!completer.isCompleted) completer.complete();
            case ThinkingDelta() ||
                ToolCallStart() ||
                ToolCallArgsDelta() ||
                ToolCallEnd() ||
                ToolCallResult():
              // utility 调用忽略
              break;
          }
        },
        onError: (Object e) {
          errorMsg = '$e';
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

  try {
    await completer.future.timeout(
      timeout,
      onTimeout: () {
        errorMsg = 'timeout after ${timeout.inSeconds}s';
      },
    );
  } finally {
    await sub.cancel();
  }

  if (errorMsg != null) throw LlmCallException(errorMsg!);
  return buf.toString();
}

class LlmCallException implements Exception {
  final String message;
  const LlmCallException(this.message);
  @override
  String toString() => 'LlmCallException: $message';
}
