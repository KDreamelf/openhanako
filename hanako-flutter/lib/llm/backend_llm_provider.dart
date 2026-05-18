import 'dart:async';

import 'package:dio/dio.dart';

import '../identity/hanako_backend_client.dart';
import 'provider.dart';

/// 把 [HanakoBackendClient] 包装成 [LlmProvider]，让 `callProviderText`
/// 等 utility 接口可以走主网关。
///
/// 用途：辅助 LLM 调用（findRelevantMemories / extractMemories /
/// 经验脱敏等）需要一个简单的 chat 入口，避免每次手写消息编解码。
/// 主对话流不走这里——它直接用 `backendClient.chatEvents`，因为
/// `AgentRuntimeLoop` 需要的事件粒度（tool_call / thinking / done）
/// 比 LlmProvider 接口暴露的更细。
class BackendLlmProvider implements LlmProvider {
  const BackendLlmProvider(this.backendClient);

  final HanakoBackendClient backendClient;

  @override
  String get name => 'hanako_backend';

  @override
  Stream<LlmEvent> chat({
    required List<Message> messages,
    required String model,
    List<Tool>? tools,
    bool? thinking,
    CancelToken? cancelToken,
  }) {
    return backendClient.chatEvents(
      model: model,
      messages: messages.map((m) => m.toJson()).toList(),
      tools: tools,
      cancelToken: cancelToken,
    );
  }
}
