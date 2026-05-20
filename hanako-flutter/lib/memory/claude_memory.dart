import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class ClaudeMemoryHeader {
  const ClaudeMemoryHeader({
    required this.filename,
    required this.filePath,
    required this.mtimeMs,
    required this.description,
    required this.type,
  });

  final String filename;
  final String filePath;
  final int mtimeMs;
  final String? description;
  final String? type;
}

class ClaudeMemorySearchResult {
  const ClaudeMemorySearchResult({
    required this.filename,
    required this.filePath,
    required this.line,
    required this.snippet,
    required this.mtimeMs,
    this.description,
    this.type,
  });

  final String filename;
  final String filePath;
  final int line;
  final String snippet;
  final int mtimeMs;
  final String? description;
  final String? type;

  Map<String, dynamic> toJson() => {
    'filename': filename,
    'path': filePath,
    'line': line,
    'snippet': snippet,
    'mtime_ms': mtimeMs,
    if (description != null && description!.isNotEmpty)
      'description': description,
    if (type != null && type!.isNotEmpty) 'type': type,
  };
}

Directory getClaudeMemoryRoot(Directory agentDir) {
  return Directory(p.join(agentDir.path, 'memory'));
}

Directory getClaudeTeamMemoryRoot(Directory agentDir) {
  return Directory(p.join(getClaudeMemoryRoot(agentDir).path, 'team'));
}

File getClaudeMemoryEntrypoint(Directory memoryRoot) {
  return File(p.join(memoryRoot.path, 'MEMORY.md'));
}

Future<void> ensureMemoryDirExists(Directory memoryRoot) async {
  await memoryRoot.create(recursive: true);
}

Future<List<ClaudeMemoryHeader>> scanMemoryFiles(
  Directory memoryRoot, {
  int maxFiles = 200,
}) async {
  final rootPath = memoryRoot.path;
  if (!await memoryRoot.exists()) return const [];
  final headers = <ClaudeMemoryHeader>[];
  await for (final entity in memoryRoot.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File || !entity.path.toLowerCase().endsWith('.md')) {
      continue;
    }
    final filename = p.relative(entity.path, from: rootPath);
    if (p.basename(entity.path).toUpperCase() == 'MEMORY.MD') {
      continue;
    }
    final content = await entity.readAsString();
    final lines = content.split('\n');
    final frontmatter = _parseFrontmatter(lines.take(30).join('\n'));
    final stat = await entity.stat();
    headers.add(
      ClaudeMemoryHeader(
        filename: filename,
        filePath: entity.path,
        mtimeMs: stat.modified.millisecondsSinceEpoch,
        description: frontmatter['description']?.toString().trim(),
        type: frontmatter['type']?.toString().trim(),
      ),
    );
  }
  headers.sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
  if (headers.length > maxFiles) {
    return headers.sublist(0, maxFiles);
  }
  return headers;
}

Future<List<ClaudeMemorySearchResult>> searchMemoryFiles(
  Directory memoryRoot,
  String query, {
  int maxResults = 20,
}) async {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  if (!await memoryRoot.exists()) return const [];

  final results = <ClaudeMemorySearchResult>[];
  await for (final entity in memoryRoot.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File || !entity.path.toLowerCase().endsWith('.md')) {
      continue;
    }
    if (p.basename(entity.path).toUpperCase() == 'MEMORY.MD') {
      continue;
    }

    final content = await entity.readAsString();
    final lines = content.split('\n');
    final frontmatter = _parseFrontmatter(lines.take(30).join('\n'));
    final stat = await entity.stat();
    final relative = p.relative(entity.path, from: memoryRoot.path);

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.toLowerCase().contains(needle)) continue;
      results.add(
        ClaudeMemorySearchResult(
          filename: relative,
          filePath: entity.path,
          line: i + 1,
          snippet: _snippet(line, needle),
          mtimeMs: stat.modified.millisecondsSinceEpoch,
          description: frontmatter['description']?.toString().trim(),
          type: frontmatter['type']?.toString().trim(),
        ),
      );
      break;
    }
  }

  results.sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
  if (results.length > maxResults) {
    return results.sublist(0, maxResults);
  }
  return results;
}

String formatMemoryManifest(List<ClaudeMemoryHeader> memories) {
  return memories
      .map((m) {
        final tag = m.type == null || m.type!.isEmpty ? '' : '[${m.type}] ';
        final ts = DateTime.fromMillisecondsSinceEpoch(
          m.mtimeMs,
        ).toUtc().toIso8601String();
        return m.description == null || m.description!.isEmpty
            ? '- $tag${m.filename} ($ts)'
            : '- $tag${m.filename} ($ts): ${m.description}';
      })
      .join('\n');
}

String memoryAgeLabel(int mtimeMs) {
  final days = memoryAgeDays(mtimeMs);
  if (days == 0) return '今天';
  if (days == 1) return '昨天';
  return '$days 天前';
}

int memoryAgeDays(int mtimeMs) {
  final diff = DateTime.now().millisecondsSinceEpoch - mtimeMs;
  if (diff <= 0) return 0;
  return diff ~/ 86400000;
}

String memoryFreshnessText(int mtimeMs) {
  final days = memoryAgeDays(mtimeMs);
  if (days <= 1) return '';
  return '这条记忆已有 $days 天。把它当作快照看，使用前先结合当前代码核对。';
}

String memoryFreshnessNote(int mtimeMs) {
  final text = memoryFreshnessText(mtimeMs);
  if (text.isEmpty) return '';
  return '<system-reminder>$text</system-reminder>\n';
}

String truncateEntrypointContent(
  String raw, {
  int maxLines = 200,
  int maxBytes = 25000,
}) {
  final trimmed = raw.trim();
  final lines = trimmed.split('\n');
  final lineCount = lines.length;
  final byteCount = trimmed.length;
  final lineTruncated = lineCount > maxLines;
  final byteTruncated = byteCount > maxBytes;
  if (!lineTruncated && !byteTruncated) {
    return trimmed;
  }
  var output = lineTruncated ? lines.take(maxLines).join('\n') : trimmed;
  if (output.length > maxBytes) {
    final cutAt = output.lastIndexOf('\n', maxBytes);
    output = output.substring(0, cutAt > 0 ? cutAt : maxBytes);
  }
  final reason = byteTruncated && !lineTruncated
      ? '$byteCount bytes (limit: $maxBytes)'
      : lineTruncated && !byteTruncated
      ? '$lineCount lines (limit: $maxLines)'
      : '$lineCount lines and $byteCount bytes';
  return '$output\n\n> WARNING: MEMORY.md is $reason. Only part of it was loaded.';
}

Future<String> buildMemoryPrompt({
  required Directory memoryRoot,
  String displayName = 'auto memory',
  List<String> extraGuidelines = const [],
  bool teamMode = false,
  Directory? teamMemoryRoot,
}) async {
  await ensureMemoryDirExists(memoryRoot);
  if (teamMode && teamMemoryRoot != null) {
    await ensureMemoryDirExists(teamMemoryRoot);
  }
  final entrypoint = getClaudeMemoryEntrypoint(memoryRoot);
  final entrypointContent = entrypoint.existsSync()
      ? entrypoint.readAsStringSync()
      : '';
  final entrypointBlock = entrypointContent.trim().isEmpty
      ? '你的 MEMORY.md 当前为空。新的记忆会写在这里。'
      : truncateEntrypointContent(entrypointContent);
  final lines = <String>[
    '# $displayName',
    '',
    '你有一个持久化的文件式记忆系统，目录是 `${memoryRoot.path}`。目录已经存在，直接用 apply_patch 写入，不要先 mkdir 或检查存在性。',
    '',
    '你应该随着时间建立这个记忆系统，以便未来对话可以了解用户是谁、他们希望如何与你协作、要避免或重复什么行为，以及用户给你的工作背后的上下文。',
    '',
    '当用户明确要求记住时，要立刻保存为最合适的类型；当用户要求忘记时，找到并删除对应项。',
    '',
    '## 记忆类型',
    '',
    '记忆固定为四种类型，每种记录的是**无法从当前项目状态推导**的上下文。代码模式、架构、git 历史、文件结构都可以推导（grep / git / 项目说明文档），**不要**写入记忆。',
    '',
    '<types>',
    '<type>',
    '    <name>user</name>',
    '    <description>关于用户的角色、目标、责任、知识背景。好的 user 记忆让你未来能依据用户视角调整行为——和资深工程师协作的方式跟刚开始学编程的学生不一样。目的是让你更能帮上用户，**不要**写负面评价或与协作无关的内容。</description>',
    '    <when_to_save>学到任何关于用户角色、偏好、责任、知识的细节时</when_to_save>',
    '    <how_to_use>工作需要参考用户画像或视角时。例如用户让你解释代码，要按用户已有的领域知识背景去解释。</how_to_use>',
    '    <examples>',
    '    user: 我是数据科学家，目前在排查日志接入',
    '    assistant: [保存 user 记忆：用户是数据科学家，当前关注 observability/logging]',
    '',
    '    user: 我 Go 写了十年，但这是我第一次碰这个仓库的 React 部分',
    "    assistant: [保存 user 记忆：Go 资深，本仓库前端新手——前端讲解时类比后端概念]",
    '    </examples>',
    '</type>',
    '<type>',
    '    <name>feedback</name>',
    '    <description>用户对你工作方式给的指导——要避免什么、要继续做什么。这一类至关重要，能让你在同一项目中保持一致的工作方式。**纠正和确认都要记**：只记纠正会偏向"过度回避"，把用户已经验证过的做法慢慢丢掉。</description>',
    '    <when_to_save>用户纠正你（"别这样"、"停止做 X"）**或**确认你的非显然选择有效（"对，就这样"、"完美，继续这样"、不带 pushback 接受不寻常选择）。纠正容易注意到，确认更安静——多留心。两种情况都要把对未来对话有用的部分记下来，特别是出乎意料或代码里看不出来的。**带上原因**，方便未来判断边界情况。</when_to_save>',
    '    <how_to_use>用这些记忆引导你的行为，让用户不必重复给同一条指导。</how_to_use>',
    '    <body_structure>第一行写规则本身，然后一行 **Why:**（用户给的原因——通常是过往事故或强偏好）和一行 **How to apply:**（什么时候/哪里用这条规则）。知道 *为什么* 才能判断边界，而不是盲目套规则。</body_structure>',
    '    <examples>',
    "    user: 这些测试不要 mock 数据库——上个季度 mock 测过了，生产迁移时炸了",
    '    assistant: [保存 feedback 记忆：集成测试必须打真数据库，不准 mock。原因：先前 mock/prod 分歧掩盖了破坏性迁移]',
    '',
    "    user: 别每次回答末尾都总结一遍你干了啥，我能看 diff",
    '    assistant: [保存 feedback 记忆：此用户要简洁回复，回答末尾不要拖总结]',
    '',
    "    user: 是的，这次合成一个 PR 是对的，拆开反而是 churn",
    '    assistant: [保存 feedback 记忆：这块的重构，用户偏好合一个 PR 而非多个小 PR。我自己选这条路被确认过——是经验，不是纠正]',
    '    </examples>',
    '</type>',
    '<type>',
    '    <name>project</name>',
    '    <description>关于正在进行的工作、目标、计划、bug、事件的背景——这些**不能**从代码或 git 历史推导。project 记忆帮你理解用户请求背后的动机与约束。</description>',
    '    <when_to_save>学到谁在做什么、为什么、何时之前要做完。状态变化快，尽量保持最新。**用户消息里的相对日期要转成绝对日期**（"周四" → "2026-03-05"），这样记忆在时间过去后仍可解读。</when_to_save>',
    '    <how_to_use>用这些记忆理解用户请求的背景细节，给出更靠谱的建议。</how_to_use>',
    '    <body_structure>第一行写事实/决定，然后 **Why:**（动机——通常是约束、deadline、利益方要求）和 **How to apply:**（这应该如何影响你的建议）。project 记忆衰减快，**Why** 帮未来判断这条还成不成立。</body_structure>',
    '    <examples>',
    "    user: 周四之后非关键合并都冻结——移动团队要拉发布分支",
    '    assistant: [保存 project 记忆：2026-03-05 起合并冻结，移动端切发布。安排该日期之后的非关键 PR 要先提醒]',
    '',
    "    user: 我们拆掉旧 auth middleware 是因为法务说会话 token 存的方式不符合新合规要求",
    '    assistant: [保存 project 记忆：auth middleware 重写驱动力是法务/合规对会话 token 存储的要求，不是技术债清理——范围决策要让位给合规而非工效]',
    '    </examples>',
    '</type>',
    '<type>',
    '    <name>reference</name>',
    '    <description>指向外部系统里信息所在位置的指针。让你记得到项目目录外面去哪查最新信息。</description>',
    '    <when_to_save>学到外部系统的资源和它们的用途。例如 bug 在 Linear 某 project 跟踪，或反馈在某沟通频道。</when_to_save>',
    '    <how_to_use>用户提到外部系统、或所需信息可能在外部系统时使用。</how_to_use>',
    '    <examples>',
    '    user: 这些 ticket 的背景看 Linear 的 "INGEST" project，pipeline 的 bug 都在那儿',
    '    assistant: [保存 reference 记忆：pipeline bugs 跟踪在 Linear project "INGEST"]',
    '',
    "    user: oncall 看的是 grafana.internal/d/api-latency——改请求路径的代码会触发那条 page",
    '    assistant: [保存 reference 记忆：grafana.internal/d/api-latency 是 oncall 延迟看板——改请求路径代码时先看它]',
    '    </examples>',
    '</type>',
    '</types>',
    '',
    '## 不该写入记忆的内容',
    '',
    '- 代码模式、约定、架构、文件路径、项目结构——这些可以通过读当前项目状态推导。',
    '- Git 历史、最近改动、谁改的什么——`git log` / `git blame` 是权威。',
    '- 调试解法或修复套路——修复就在代码里，commit message 里有背景。',
    '- 任何已经写在项目说明文档（如 CLAUDE.md）里的内容。',
    '- 临时任务细节：进行中的工作、临时状态、当前对话上下文。',
    '',
    '这些排除项即使用户**明确要求**保存也适用。如果用户让你保存一份 PR 列表或活动总结，反问哪些是**意外**或**非显然**的——那才值得记。',
    '',
    '## 如何保存记忆',
    '',
    '保存一条记忆是两步：',
    '',
    '**Step 1** — 用 apply_patch 把这条记忆写成单独的 .md 文件（例如 `user_role.md`、`feedback_testing.md`），使用以下 frontmatter 格式：',
    '',
    '```markdown',
    '---',
    'name: {{记忆名}}',
    'description: {{一行描述——决定未来对话中是否被选中，要具体}}',
    'type: {{user, feedback, project, reference}}',
    '---',
    '',
    '{{记忆正文——feedback/project 类型按照"规则/事实 + Why: + How to apply:"的结构}}',
    '```',
    '',
    '**Step 2** — 在 `MEMORY.md` 加一条指向该文件的索引行。`MEMORY.md` 是索引、不是记忆——每条不超过 ~150 字符：`- [标题](file.md) — 一行钩子`。`MEMORY.md` 不带 frontmatter。**不要**把记忆正文直接写进 `MEMORY.md`。',
    '',
    '- `MEMORY.md` 始终自动加载到你的对话上下文（即下文 `## MEMORY.md` 段落）——超过 200 行会被截断，索引要保持简洁。',
    '- 保持记忆文件里 name / description / type 与正文一致。',
    '- 按主题语义组织记忆，**不**按时间堆叠。',
    '- 写新记忆前先检查能不能更新已有记忆，避免重复。',
    '- 发现错误或过时记忆要更新或删除。',
    '',
    '## 何时访问记忆',
    '',
    '- 记忆可能相关时、用户引用先前对话的工作时、用户明确要求检查 / 回忆 / 记住时，必须访问记忆。',
    '- 用户要求**忽略**或**不使用**记忆时：表现得像 MEMORY.md 为空一样继续，不要应用、引用或比较记忆内容。',
    '- 记忆是某个时间点的快照，不是实时状态。从记忆给出结论前先用当前文件/资源核对。如果记忆与现状冲突，**相信当前观察**，更新或删除过时记忆。',
    '',
    '## 从记忆给建议前',
    '',
    '记忆里提到的具体函数、文件、标志只是"它在记忆写下时存在"。可能已被改名/删除/从未合并。给建议前：',
    '- 记忆涉及文件路径：检查文件存在。',
    '- 记忆涉及函数或标志：search_text grep 一遍。',
    '- 用户要按你的建议**采取行动**（不只是问历史）：先验证。',
    '',
    '"记忆说 X 存在" 不等于 "X 现在存在"。',
    '',
    '## 记忆与其他持久化方式',
    '',
    '记忆是你在协助用户时多个持久化机制之一。区别是：记忆**在未来对话中可被回忆**，不要用记忆保存只在当前对话作用域有意义的信息。',
    '- 即将开始非平凡实现任务、想跟用户对齐做法时，使用 update_plan 而不是记忆。已有 plan 而决策变化时，更新 plan 而非新建记忆。',
    '- 把当前对话工作拆分成离散步骤、跟踪进度时，使用任务而非记忆。',
    '',
    '如果系统启用了团队记忆，私人目录和团队目录都纳入检索。',
    '',
    ...extraGuidelines,
    '',
    '## MEMORY.md',
    '',
    entrypointBlock,
  ];
  if (teamMode && teamMemoryRoot != null) {
    final teamEntry = getClaudeMemoryEntrypoint(teamMemoryRoot);
    final teamContent = teamEntry.existsSync()
        ? teamEntry.readAsStringSync()
        : '';
    lines.addAll([
      '',
      '## team/MEMORY.md',
      '',
      teamContent.trim().isEmpty
          ? '团队 MEMORY.md 当前为空。'
          : truncateEntrypointContent(teamContent),
    ]);
  }
  return lines.join('\n');
}

Map<String, dynamic> _parseFrontmatter(String content) {
  if (!content.startsWith('---')) return const {};
  final end = content.indexOf('\n---', 3);
  if (end < 0) return const {};
  try {
    final yaml = loadYaml(content.substring(3, end));
    if (yaml is YamlMap) {
      final map = yaml.map((key, value) => MapEntry(key.toString(), value));
      // 兼容 CC 嵌套 metadata.type 格式：type 可以在顶层或 metadata 子层。
      if (map['type'] == null && map['metadata'] is Map) {
        final meta = map['metadata'] as Map;
        if (meta['type'] != null) map['type'] = meta['type'];
      }
      return map;
    }
  } catch (_) {}
  return const {};
}

String _snippet(String line, String needle) {
  final lowerLine = line.toLowerCase();
  final index = lowerLine.indexOf(needle);
  if (index < 0) return line.trim();
  final start = index > 48 ? index - 48 : 0;
  final end = index + needle.length + 96 < line.length
      ? index + needle.length + 96
      : line.length;
  final prefix = start > 0 ? '…' : '';
  final suffix = end < line.length ? '…' : '';
  return '$prefix${line.substring(start, end).trim()}$suffix';
}
