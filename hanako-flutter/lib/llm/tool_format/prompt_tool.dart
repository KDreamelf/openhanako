import 'dart:convert';

/// `prompt-tool` 格式：在系统 prompt 中说明工具调用语法，
/// 模型用 `<tool_call>{json}</tool_call>` 标签调用工具。
/// thinking 用 `<think>...</think>` 标签包裹。
///
/// 对应 legacy-electron/lib/llm/prompt-tool-provider.js。
class PromptToolFormat {
  PromptToolFormat._();

  static const String toolCallOpen = '<tool_call>';
  static const String toolCallClose = '</tool_call>';
  static const String thinkOpen = '<think>';
  static const String thinkClose = '</think>';

  /// 给模型的工具说明 prompt 段（拼到 system 末尾）。
  static String buildToolInstructions(List<ToolSchema> tools) {
    if (tools.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('You can call the following tools by emitting a tag:')
      ..writeln('$toolCallOpen{"name": "tool_name", "arguments": {...}}$toolCallClose')
      ..writeln('Each call must be on its own and well-formed JSON.')
      ..writeln('')
      ..writeln('Available tools:');
    for (final t in tools) {
      buf
        ..writeln('- ${t.name}: ${t.description}')
        ..writeln('  parameters: ${jsonEncode(t.parameters)}');
    }
    return buf.toString();
  }

  /// 解析模型流式输出，按出现顺序产出 [PromptToolBlock]。
  /// 增量调用：把流式文本一段段 push，类内部累积 buffer 并尽量 emit 完整块。
  ///
  /// 边界情况：tag 跨 chunk 切断时，未完成的 tag 内容保留在 buffer 中等待续接。
  /// 该 parser 是 stateful 的，每个对话消息一份。
}

class PromptToolStreamParser {
  final StringBuffer _buf = StringBuffer();

  /// 当前是否在 `<think>` 块内部。
  bool _inThink = false;

  /// 当前是否在 `<tool_call>` 块内部。
  bool _inToolCall = false;

  /// 推入一段文本，返回**这一次新解析出的事件**列表。
  List<PromptToolEvent> push(String chunk) {
    _buf.write(chunk);
    final out = <PromptToolEvent>[];

    while (true) {
      final s = _buf.toString();
      if (s.isEmpty) break;

      if (_inThink) {
        final close = s.indexOf(PromptToolFormat.thinkClose);
        if (close < 0) {
          // 闭合 tag 还没到，全部 emit 为 think delta
          if (s.isNotEmpty) {
            out.add(PromptToolThinkDelta(s));
            _buf.clear();
          }
          break;
        } else {
          if (close > 0) out.add(PromptToolThinkDelta(s.substring(0, close)));
          _buf
            ..clear()
            ..write(s.substring(close + PromptToolFormat.thinkClose.length));
          _inThink = false;
        }
      } else if (_inToolCall) {
        final close = s.indexOf(PromptToolFormat.toolCallClose);
        if (close < 0) {
          // 还在累积 tool_call body
          break;
        }
        final body = s.substring(0, close);
        _buf
          ..clear()
          ..write(s.substring(close + PromptToolFormat.toolCallClose.length));
        _inToolCall = false;
        try {
          final j = jsonDecode(body) as Map<String, dynamic>;
          out.add(PromptToolCallParsed(
            name: (j['name'] as String?) ?? '',
            argumentsJson: jsonEncode(j['arguments'] ?? <String, dynamic>{}),
          ));
        } catch (_) {
          // JSON 解析失败 → 当作普通文本
          out.add(PromptToolTextDelta(
              '${PromptToolFormat.toolCallOpen}$body${PromptToolFormat.toolCallClose}'));
        }
      } else {
        // 找下一个 tag 起点
        final thinkAt = s.indexOf(PromptToolFormat.thinkOpen);
        final toolAt = s.indexOf(PromptToolFormat.toolCallOpen);

        // 没有 tag → 全部 emit 为 text delta
        if (thinkAt < 0 && toolAt < 0) {
          // 但要警惕半个 tag（"<thi"）卡在末尾的情况
          final keep = _possiblyPartialTagSuffixLength(s);
          if (keep == 0) {
            out.add(PromptToolTextDelta(s));
            _buf.clear();
          } else {
            final emit = s.substring(0, s.length - keep);
            if (emit.isNotEmpty) out.add(PromptToolTextDelta(emit));
            _buf
              ..clear()
              ..write(s.substring(s.length - keep));
          }
          break;
        }

        final nextAt = (thinkAt >= 0 && (toolAt < 0 || thinkAt < toolAt))
            ? thinkAt
            : toolAt;
        if (nextAt > 0) {
          out.add(PromptToolTextDelta(s.substring(0, nextAt)));
        }
        if (nextAt == thinkAt) {
          _buf
            ..clear()
            ..write(s.substring(thinkAt + PromptToolFormat.thinkOpen.length));
          _inThink = true;
        } else {
          _buf
            ..clear()
            ..write(s.substring(toolAt + PromptToolFormat.toolCallOpen.length));
          _inToolCall = true;
        }
      }
    }

    return out;
  }

  /// 处理流式文本结束时残留的 buffer（只输出剩余 text）。
  List<PromptToolEvent> flush() {
    final s = _buf.toString();
    _buf.clear();
    if (s.isEmpty) return const [];
    return [PromptToolTextDelta(s)];
  }

  /// 检测末尾是否可能是不完整的 tag 起始（如 "<th" 等），返回该后缀长度。
  /// 只检查 `<think>` 和 `<tool_call>` 的前缀。
  int _possiblyPartialTagSuffixLength(String s) {
    const candidates = [
      PromptToolFormat.thinkOpen,
      PromptToolFormat.toolCallOpen,
    ];
    for (final c in candidates) {
      for (var len = c.length - 1; len > 0; len--) {
        if (s.endsWith(c.substring(0, len))) return len;
      }
    }
    return 0;
  }
}

sealed class PromptToolEvent {
  const PromptToolEvent();
}

class PromptToolTextDelta extends PromptToolEvent {
  final String text;
  const PromptToolTextDelta(this.text);
}

class PromptToolThinkDelta extends PromptToolEvent {
  final String text;
  const PromptToolThinkDelta(this.text);
}

class PromptToolCallParsed extends PromptToolEvent {
  final String name;
  final String argumentsJson;
  const PromptToolCallParsed({required this.name, required this.argumentsJson});
}

/// 工具 schema（Phase 1 的最小结构；与 OpenAI / Anthropic 通用 JSON Schema 对齐）。
class ToolSchema {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  const ToolSchema({
    required this.name,
    required this.description,
    required this.parameters,
  });
}

/// 块（用于 PromptTool 解析的一次性返回，跟 legacy parsePromptToolResponseText 对齐）。
sealed class PromptToolBlock {
  const PromptToolBlock();
}

class PromptToolTextBlock extends PromptToolBlock {
  final String text;
  const PromptToolTextBlock(this.text);
}

class PromptToolCallBlock extends PromptToolBlock {
  final String id;
  final String name;
  final String argumentsJson;
  const PromptToolCallBlock({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });
}
