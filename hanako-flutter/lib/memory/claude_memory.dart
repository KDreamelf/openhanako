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
    '你有一个持久化的文件式记忆系统，目录是 `${memoryRoot.path}`。目录已经存在，直接写入，不要先 mkdir。',
    '',
    '你应该随着时间建立这个记忆系统，以便未来对话可以了解用户是谁、他们希望如何与你协作、要避免或重复什么行为，以及用户给你的工作背后的上下文。',
    '',
    '记忆类型固定为四种：user / feedback / project / reference。',
    '',
    '保存记忆时，先把内容写成单独的 .md 文件，再把入口加到 MEMORY.md；MEMORY.md 只是索引，不要把正文直接写进去。MEMORY.md 的每个条目应是一行短链接，保持简洁，便于未来判断相关性。',
    '',
    '记忆文件必须使用 frontmatter：name、description、type。description 是未来判断相关性的具体一行描述；type 只能是 user、feedback、project、reference。feedback/project 类型正文应包含规则或事实，并补充 Why 与 How to apply。',
    '',
    '当用户明确要求记住时，要立刻保存；当用户要求忘记时，要找到并删除对应项。',
    '',
    '保持记忆文件里的 name、description 和 type 与内容一致；按主题语义组织记忆，不按时间流水堆叠；写入新记忆前先检查是否能更新已有记忆；更新或删除被证明错误或过时的记忆。',
    '',
    '不要保存：代码模式、git 历史、当前任务临时状态、已经写进项目指令里的内容、内部思维链、一次性推测或冗长日志。',
    '',
    '访问记忆时要先确认它是否仍然有效；记忆只是某个时间点的快照，不是实时状态。',
    '',
    '当记忆似乎相关、用户引用先前对话的工作，或用户明确要求检查、回忆、记住时，必须访问记忆。如果用户要求忽略或不使用记忆，就像 MEMORY.md 为空一样继续，不要应用、引用或比较记忆内容。',
    '',
    '从记忆给出建议前必须验证：记忆命名文件路径时检查文件是否存在；记忆命名函数、标志或代码符号时用 search_text 检查当前代码；如果当前观察与记忆冲突，信任当前观察并更新或删除过时记忆。',
    '',
    '记忆不是当前任务计划。非平凡实现任务的步骤和进度使用 update_plan；只有未来对话仍然有用的信息才写入记忆。',
    '',
    '如果系统里同时启用了团队记忆，私人目录和团队目录都要纳入检索。',
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
      return yaml.map((key, value) => MapEntry(key.toString(), value));
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
