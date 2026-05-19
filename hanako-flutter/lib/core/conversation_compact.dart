import '../llm/provider.dart';
import '../llm/utility.dart';
import 'agent_runtime.dart';

class CompactResult {
  const CompactResult({required this.summary, this.reinject});

  final String summary;
  final Map<String, dynamic>? reinject;
}

Future<CompactResult> compactConversation({
  required List<RuntimeMessage> messages,
  required LlmProvider provider,
  required String model,
  Duration timeout = const Duration(seconds: 120),
}) async {
  if (messages.isEmpty) {
    return const CompactResult(summary: '');
  }

  final prompt = _buildCompactPrompt(messages);
  final raw = await callProviderText(
    provider: provider,
    model: model,
    userContent: prompt,
    temperature: 0.3,
    timeout: timeout,
  );

  final summary = _extractSummary(raw);
  final reinject = _collectReinjectData(messages);
  return CompactResult(summary: summary, reinject: reinject);
}

String _buildCompactPrompt(List<RuntimeMessage> messages) {
  final transcript = StringBuffer();
  for (final msg in messages) {
    switch (msg.role) {
      case 'user':
        transcript.writeln('[User]');
        transcript.writeln(msg.visibleText);
      case 'assistant':
        transcript.writeln('[Assistant]');
        transcript.writeln(msg.visibleText);
        for (final call in msg.toolCalls) {
          transcript.writeln('  [Tool Call: ${call.name}]');
          final argsPreview = call.openAiArgumentsJson;
          if (argsPreview.length > 500) {
            transcript.writeln(
              '  ${argsPreview.substring(0, 500)}...(truncated)',
            );
          } else {
            transcript.writeln('  $argsPreview');
          }
        }
      case 'toolResult':
        final content = msg.visibleText;
        transcript.writeln('[Tool Result: ${msg.toolName ?? "unknown"}]');
        if (content.length > 2000) {
          transcript.writeln('${content.substring(0, 2000)}...(truncated)');
        } else {
          transcript.writeln(content);
        }
      case 'compactBoundary':
        continue;
      default:
        transcript.writeln('[${msg.role}]');
        transcript.writeln(msg.visibleText);
    }
    transcript.writeln();
  }

  return '''
<instructions>
你的任务是生成一份对话总结。这份总结将替代原始对话历史，用于后续交互的上下文。请确保总结是全面且详细的，精确保留所有关键技术细节、代码改动、决策和错误信息。

绝对禁止调用任何工具。只返回总结文本。

按以下格式生成总结（每个节必须存在，即使内容为空也要写"无"）：

1. **主要请求和意图**
   用户想要完成什么？包括用户优先级的任何更新或变化。逐字引用用户最近一次消息的关键部分。

2. **关键技术概念**
   涉及的技术、框架、API、协议、数据结构。包含足够的细节让后续对话无需重新查阅。

3. **文件和代码段**
   哪些文件被阅读、创建或修改？包含关键代码片段（不要截断有意义的代码）、它们的完整文件路径和改动原因。

4. **错误和修复**
   出现过什么错误？如何排查的？包含用户的反馈和纠正。

5. **问题解决**
   描述解决问题的思路和方法，包括尝试过但失败的路径。

6. **所有用户消息**
   完整列出每条用户消息的要点（不能遗漏任何一条）。这确保我们不会忘记用户说过的任何内容。

7. **待办事项**
   列出所有尚未完成的任务、承诺或计划中的下一步。

8. **当前工作**
   最近正在做什么？精确到具体文件、函数、行号。包括最后一步的状态。

9. **可选的下一步**
   根据对话的走向，最可能的下一步是什么？
</instructions>

<conversation>
$transcript
</conversation>

请在 <summary> 标签内输出总结。先在 <analysis> 标签内写一份简要分析草稿（用于帮助你组织思路，该部分不会进入后续上下文）。''';
}

String _extractSummary(String raw) {
  final summaryStart = raw.indexOf('<summary>');
  final summaryEnd = raw.indexOf('</summary>');
  if (summaryStart >= 0 && summaryEnd > summaryStart) {
    return raw.substring(summaryStart + '<summary>'.length, summaryEnd).trim();
  }
  final analysisEnd = raw.indexOf('</analysis>');
  if (analysisEnd >= 0) {
    return raw.substring(analysisEnd + '</analysis>'.length).trim();
  }
  return raw.trim();
}

Map<String, dynamic>? _collectReinjectData(List<RuntimeMessage> messages) {
  final recentFiles = <String>[];
  String? lastPlan;

  for (final msg in messages) {
    if (msg.role != 'assistant') continue;
    for (final call in msg.toolCalls) {
      switch (call.name) {
        case 'read_file':
          final args = call.arguments;
          final path = args['file_path'] ?? args['path'];
          if (path is String && path.trim().isNotEmpty) {
            recentFiles.remove(path.trim());
            recentFiles.add(path.trim());
          }
        case 'update_plan':
          final args = call.arguments;
          final plan = args['plan'];
          if (plan is String && plan.trim().isNotEmpty) {
            lastPlan = plan.trim();
          }
      }
    }
  }

  final lastFiles =
      recentFiles.length > 5 ? recentFiles.sublist(recentFiles.length - 5) : recentFiles;

  if (lastFiles.isEmpty && lastPlan == null) return null;
  return {
    if (lastFiles.isNotEmpty) 'recentFiles': lastFiles,
    if (lastPlan != null) 'lastPlan': lastPlan,
  };
}

String buildCompactPreamble(String summary, Map<String, dynamic>? reinject) {
  final buf = StringBuffer();
  buf.writeln('以下是本会话之前部分的压缩总结。总结之前的完整对话已被折叠，当前上下文只包含总结和后续消息。');
  buf.writeln();
  buf.writeln(summary);

  if (reinject != null) {
    final files = reinject['recentFiles'];
    if (files is List && files.isNotEmpty) {
      buf.writeln();
      buf.writeln('压缩前最近读取的文件（如需详细内容请重新读取）：');
      for (final f in files) {
        buf.writeln('- $f');
      }
    }
    final plan = reinject['lastPlan'];
    if (plan is String && plan.trim().isNotEmpty) {
      buf.writeln();
      buf.writeln('压缩前的工作计划：');
      buf.writeln(plan);
    }

    // 截留的原文文件引用：模型可以用 read_file 读取完整原文。
    final allTranscripts = <String>[];
    final prior = reinject['priorTranscripts'];
    if (prior is List) {
      for (final item in prior) {
        if (item is String && item.trim().isNotEmpty) {
          allTranscripts.add(item.trim());
        }
      }
    }
    final current = reinject['transcriptFile'];
    if (current is String && current.trim().isNotEmpty) {
      allTranscripts.add(current.trim());
    }
    if (allTranscripts.isNotEmpty) {
      buf.writeln();
      buf.writeln('压缩前的对话原文已截留存档，如需查看具体细节可用 read_file 读取：');
      for (final t in allTranscripts) {
        buf.writeln('- $t');
      }
    }
  }

  return buf.toString();
}
