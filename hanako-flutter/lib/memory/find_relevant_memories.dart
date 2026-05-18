import 'dart:convert';
import 'dart:io';

import '../llm/provider.dart';
import '../llm/utility.dart';
import 'claude_memory.dart';

/// 从 agent/memory/ 里挑出与当前 query 语义相关的 ≤[limit] 条记忆。
///
/// 与 claude-code-main 的 src/memdir/findRelevantMemories.ts 对齐：
/// 用辅助小模型（[provider] / [model]）按 frontmatter description 选；
/// 选中后再读完整 .md 内容拼成 system prompt 末尾的提示段，告诉模型
/// "这些可能相关，但记忆是某时间点快照，使用前先核对"。
///
/// MEMORY.md 自身不参与筛选（它本身已经在 system prompt 顶部加载）。
/// [alreadySurfaced] 是当前会话里**已经**作为 relevant_memories 注入过
/// 的 .md 绝对路径集合——避免同一条记忆在同一会话内反复推。
///
/// 失败、超时、列表为空、模型返回不可解析 JSON 时都返回空列表。
/// 这是辅助路径，不能让它的失败把主对话流拦下来。
class RelevantMemoryFile {
  const RelevantMemoryFile({
    required this.filename,
    required this.filePath,
    required this.content,
    required this.mtimeMs,
    this.description,
    this.type,
  });

  final String filename;
  final String filePath;
  final String content;
  final int mtimeMs;
  final String? description;
  final String? type;
}

const String _selectMemoriesSystemPrompt =
    '你正在为一个本地 Agent 挑选有用的记忆。你会拿到用户的当前请求和一个可用记忆文件列表（含文件名和描述）。\n'
    '\n'
    '从中挑出**确实**对处理当前请求有用的文件名（最多 5 条）。只挑你**确信**根据名字和描述能帮上忙的。\n'
    '- 不确定就不选。宁可空也不要凑数。\n'
    '- 没有合适的就返回空列表。\n'
    '- 如果用户当前请求与近期使用过的工具相关，不要选这些工具的"API 参考"或"用法手册"类记忆（Agent 已经在用了）；但工具相关的**警告、坑、已知问题**类记忆要选——正在用工具时这些最重要。\n'
    '\n'
    '严格返回 JSON，形如：{"selected_memories": ["<filename>", ...]}';

Future<List<RelevantMemoryFile>> findRelevantMemories({
  required Directory memoryRoot,
  required String query,
  required LlmProvider provider,
  required String model,
  List<String> recentTools = const [],
  Set<String> alreadySurfaced = const {},
  int limit = 5,
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (query.trim().isEmpty) return const [];
  if (!memoryRoot.existsSync()) return const [];

  final headers = (await scanMemoryFiles(memoryRoot))
      .where((m) => !alreadySurfaced.contains(m.filePath))
      .toList(growable: false);
  if (headers.isEmpty) return const [];

  final manifest = formatMemoryManifest(headers);
  final toolsSection = recentTools.isEmpty
      ? ''
      : '\n\nRecently used tools: ${recentTools.join(", ")}';
  final userContent =
      'Query: $query\n\nAvailable memories:\n$manifest$toolsSection\n\n'
      '直接返回 JSON：{"selected_memories": ["filename1", "filename2"]}。';

  String response;
  try {
    response = await callProviderText(
      provider: provider,
      model: model,
      systemPrompt: _selectMemoriesSystemPrompt,
      userContent: userContent,
      temperature: 0.0,
      maxTokens: 256,
      timeout: timeout,
    );
  } catch (_) {
    return const [];
  }

  final picked = _parseSelectedFilenames(response, headers, limit: limit);
  if (picked.isEmpty) return const [];

  final byFilename = {for (final h in headers) h.filename: h};
  final out = <RelevantMemoryFile>[];
  for (final name in picked) {
    final h = byFilename[name];
    if (h == null) continue;
    try {
      final content = await File(h.filePath).readAsString();
      out.add(
        RelevantMemoryFile(
          filename: h.filename,
          filePath: h.filePath,
          content: content,
          mtimeMs: h.mtimeMs,
          description: h.description,
          type: h.type,
        ),
      );
    } catch (_) {
      // 单个文件读不出来不影响其它选中项
    }
  }
  return out;
}

List<String> _parseSelectedFilenames(
  String raw,
  List<ClaudeMemoryHeader> headers, {
  required int limit,
}) {
  final valid = headers.map((h) => h.filename).toSet();
  final out = <String>[];
  void addIfValid(String? candidate) {
    if (candidate == null) return;
    final trimmed = candidate.trim();
    if (trimmed.isEmpty) return;
    if (!valid.contains(trimmed)) return;
    if (out.contains(trimmed)) return;
    out.add(trimmed);
  }

  // 优先 JSON 解析。
  final jsonStart = raw.indexOf('{');
  final jsonEnd = raw.lastIndexOf('}');
  if (jsonStart >= 0 && jsonEnd > jsonStart) {
    try {
      final decoded = jsonDecode(raw.substring(jsonStart, jsonEnd + 1));
      if (decoded is Map) {
        final list = decoded['selected_memories'];
        if (list is List) {
          for (final item in list) {
            if (item is String) addIfValid(item);
            if (out.length >= limit) break;
          }
        }
      }
    } catch (_) {
      // JSON 损坏走纯文本兜底。
    }
  }

  if (out.length < limit) {
    // 兜底：直接在响应里扫已知文件名。
    for (final filename in valid) {
      if (out.length >= limit) break;
      if (out.contains(filename)) continue;
      if (raw.contains(filename)) out.add(filename);
    }
  }

  return out;
}

/// 把选中的 memory 拼成可以追加到 system prompt 末尾的提示段。
///
/// 用 `<system-reminder>` 包裹，让模型知道这段不是用户消息而是系统注入的
/// 上下文提示。每条带文件名 + 陈旧度（"今天"/"7 天前"），方便模型判断
/// 是否需要先验证再引用。
String formatRelevantMemoriesBlock(List<RelevantMemoryFile> memories) {
  if (memories.isEmpty) return '';
  final buf = StringBuffer()
    ..writeln('<system-reminder>')
    ..writeln('## 相关记忆')
    ..writeln('')
    ..writeln(
      '系统按当前请求语义为你预选了 ${memories.length} 条可能相关的记忆。'
      '这些是已落盘的 .md 内容片段，**不**是当前对话的最新状态。'
      '使用前如果记忆中提到具体函数 / 文件 / 标志，先用 search_text 验证它仍存在；'
      '如果与当前观察冲突，相信当前观察并更新或删除过时记忆。',
    )
    ..writeln('');
  for (final m in memories) {
    final age = memoryAgeLabel(m.mtimeMs);
    buf
      ..writeln('### ${m.filename} · $age')
      ..writeln('')
      ..writeln(m.content.trim())
      ..writeln('');
  }
  buf.writeln('</system-reminder>');
  return buf.toString();
}
