import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../llm/provider.dart';
import '../llm/utility.dart';
import 'claude_memory.dart';

/// 后台 memory 抽取（简化版）：一次 LLM 调用从近端对话中抽出符合四种类型的
/// 候选 memory，并把它们直接写入 agent/memory/。
///
/// 跟 claude-code-main/src/services/extractMemories/extractMemories.ts 的关键
/// 区别：
/// - CC 用 `runForkedAgent` 起一个完整子 agent，能多轮调 Read/Grep/Edit 工具
///   动态读 memory dir 和对话上下文再决定写哪条；我们这里**单次 LLM 调用**，
///   让模型一次性返回 JSON 列表，Dart 代码负责落盘 + 更新 MEMORY.md。
/// - 失去的：模型不能动态 grep memory dir 检查已存在的同主题 .md；只能
///   靠我们把 manifest 传给它，让它"避免重复"。
/// - 换得的：实现简单 / 失败兜底容易 / 不引入子 agent 抽象。
///
/// 调用方负责节流（每个 session 同时只跑一个；只在 turn 结束 unawaited 调用），
/// 这里不做并发控制。
class ExtractMemoryResult {
  const ExtractMemoryResult({
    required this.written,
    required this.skipped,
    required this.errors,
  });

  /// 新创建或覆盖的 .md 数。
  final int written;

  /// 模型给了候选但被本地校验拒掉（文件名非法、type 不在四种、与现有
  /// MEMORY.md 索引重复等）。
  final int skipped;

  /// 整体级失败（LLM 调用、JSON 解析）描述；为空表示流程跑完。
  final List<String> errors;

  bool get isEmpty => written == 0 && skipped == 0 && errors.isEmpty;
}

class _Candidate {
  const _Candidate({
    required this.filename,
    required this.description,
    required this.type,
    required this.content,
  });

  final String filename;
  final String description;
  final String type;
  final String content;
}

const Set<String> _validTypes = {'user', 'feedback', 'project', 'reference'};

const String _extractSystemPrompt =
    '''你是 PH01 后台 memory 抽取器。你的任务是：读用户与 Agent 最近的对话，把**对未来对话仍然有用**的事实抽出来，按四种 type 落成 memory。

## 四种 type

- user：用户的角色、目标、偏好、知识结构（"我是数据科学家"、"我用 Go 写了十年"）
- feedback：用户对你工作方式的纠正或确认（"别 mock 数据库"、"对，单 PR 是对的"），正文要带一行 **Why:** 和一行 **How to apply:**
- project：当前项目的目标、约束、决策的 *为什么*（"周四后合并冻结"、"auth 重写是合规要求"），正文要带 **Why:** 和 **How to apply:**，相对日期换成绝对日期
- reference：指向外部系统资源的指针（"bugs 在 Linear INGEST"）

## 不要抽

- 代码模式、架构、文件路径、git 历史（可推导，浪费 token）
- 调试解法或修复套路（commit message 有）
- 临时任务状态、计划进度（属于 plan/tasks，不属于 memory）
- 用户没明确说的猜测

## 重复处理

下面会提供 existing memory 的索引；如果某条事实已经被覆盖，**不要重复抽**。

## 输出格式

严格返回 JSON：

```json
{
  "memories": [
    {
      "filename": "user_role.md",
      "description": "一行描述，未来召回判断相关性用，要具体",
      "type": "user|feedback|project|reference",
      "content": "正文。feedback/project 类型含\\n**Why:** ...\\n**How to apply:** ..."
    }
  ]
}
```

- `filename` 必须 `.md` 结尾、不能是 `MEMORY.md`、按主题语义命名（`user_role.md`、`feedback_testing.md`、`project_q2_freeze.md`）
- `description` 一句话，不超 80 字
- `type` 严格四选一
- 没有可抽的就 `{"memories": []}`，不要硬凑
- 抽出的内容必须**真实出现在对话里**，不要编造''';

Future<ExtractMemoryResult> extractMemories({
  required Directory memoryRoot,
  required String transcript,
  required LlmProvider provider,
  required String model,
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (transcript.trim().isEmpty) {
    return const ExtractMemoryResult(written: 0, skipped: 0, errors: []);
  }
  await ensureMemoryDirExists(memoryRoot);

  final headers = await scanMemoryFiles(memoryRoot);
  final manifest = formatMemoryManifest(headers);
  final manifestBlock = manifest.isEmpty
      ? ''
      : '\n\n## Existing memories（不要重复抽）\n\n$manifest';

  final userContent = '## 近端对话\n\n$transcript$manifestBlock';

  String response;
  try {
    response = await callProviderText(
      provider: provider,
      model: model,
      systemPrompt: _extractSystemPrompt,
      userContent: userContent,
      temperature: 0.1,
      maxTokens: 2048,
      timeout: timeout,
    );
  } catch (e) {
    return ExtractMemoryResult(
      written: 0,
      skipped: 0,
      errors: ['LLM 调用失败：$e'],
    );
  }

  final List<_Candidate> candidates;
  try {
    candidates = _parseExtracted(response);
  } catch (e) {
    return ExtractMemoryResult(
      written: 0,
      skipped: 0,
      errors: ['JSON 解析失败：$e'],
    );
  }

  if (candidates.isEmpty) {
    return const ExtractMemoryResult(written: 0, skipped: 0, errors: []);
  }

  // 现有 .md 文件名集合，用来避免覆盖已有同名文件（更新策略保守：跳过，
  // 让用户/模型显式编辑老文件）。
  final existing = headers.map((h) => h.filename).toSet();
  final entrypoint = getClaudeMemoryEntrypoint(memoryRoot);
  final indexBefore = entrypoint.existsSync()
      ? entrypoint.readAsStringSync()
      : '';

  var written = 0;
  var skipped = 0;
  final newIndexEntries = <String>[];
  for (final c in candidates) {
    if (!_isValidCandidate(c)) {
      skipped++;
      continue;
    }
    if (existing.contains(c.filename)) {
      skipped++;
      continue;
    }
    if (indexBefore.contains('](${c.filename})')) {
      skipped++;
      continue;
    }
    try {
      final file = File(p.join(memoryRoot.path, c.filename));
      final body = _buildFileBody(c);
      file.writeAsStringSync(body, flush: true);
      newIndexEntries.add('- [${c.description}](${c.filename}) — ${c.type}');
      written++;
    } catch (_) {
      skipped++;
    }
  }

  if (newIndexEntries.isNotEmpty) {
    final trimmedIndex = indexBefore.trimRight();
    final nextIndex = trimmedIndex.isEmpty
        ? newIndexEntries.join('\n')
        : '$trimmedIndex\n${newIndexEntries.join('\n')}';
    try {
      entrypoint.writeAsStringSync('$nextIndex\n', flush: true);
    } catch (_) {
      // 索引写不进去：单条 .md 已落盘，模型下次会通过 grep 找到；
      // 不视作整体失败。
    }
  }

  return ExtractMemoryResult(
    written: written,
    skipped: skipped,
    errors: const [],
  );
}

bool _isValidCandidate(_Candidate c) {
  if (c.filename.isEmpty || !c.filename.toLowerCase().endsWith('.md')) {
    return false;
  }
  if (c.filename.toUpperCase() == 'MEMORY.MD') return false;
  if (c.filename.contains('/') || c.filename.contains('\\')) return false;
  if (c.filename.contains('..')) return false;
  if (!_validTypes.contains(c.type)) return false;
  if (c.description.trim().isEmpty) return false;
  if (c.content.trim().isEmpty) return false;
  return true;
}

String _buildFileBody(_Candidate c) {
  final name = c.filename.endsWith('.md')
      ? c.filename.substring(0, c.filename.length - 3)
      : c.filename;
  final buf = StringBuffer()
    ..writeln('---')
    ..writeln('name: $name')
    ..writeln('description: ${c.description}')
    ..writeln('type: ${c.type}')
    ..writeln('---')
    ..writeln()
    ..writeln(c.content.trimRight());
  return buf.toString();
}

List<_Candidate> _parseExtracted(String raw) {
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return const [];
  final jsonText = raw.substring(start, end + 1);
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map) return const [];
  final list = decoded['memories'];
  if (list is! List) return const [];
  final out = <_Candidate>[];
  for (final item in list) {
    if (item is! Map) continue;
    final filename = item['filename']?.toString().trim() ?? '';
    final description = item['description']?.toString().trim() ?? '';
    final type = item['type']?.toString().trim() ?? '';
    final content = item['content']?.toString() ?? '';
    if (filename.isEmpty || description.isEmpty || type.isEmpty) continue;
    out.add(
      _Candidate(
        filename: filename,
        description: description,
        type: type,
        content: content,
      ),
    );
  }
  return out;
}
