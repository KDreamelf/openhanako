import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../llm/provider.dart';
import '../llm/utility.dart';
import 'session_summary.dart';

/// 与 legacy lib/memory/compile.js 对齐：v3 四块独立编译 + assemble。
///
/// 四个 .md 文件各自有指纹缓存（MD5），内容变化时才重新编译，节约 LLM 调用：
///   - today.md       ：从 24h 内 session 摘要编译
///   - week.md        ：从 7d 内 session 摘要编译
///   - longterm.md    ：从 week.md + 旧 longterm.md 编译
///   - facts.md       ：从摘要中"## 重要事实"段（30d）抽取
///
/// 最终 assemble() 把四个文件合并为 memory.md（送进 system prompt）。
class MemoryCompiler {
  MemoryCompiler({
    required this.memoryDir,
    required this.summaries,
    required this.compilerProvider,
    required this.compilerModel,
  });

  final Directory memoryDir;
  final SessionSummaryStore summaries;
  final LlmProvider compilerProvider;
  final String compilerModel;

  static const _todayBudget = 750;
  static const _weekBudget = 750;
  static const _longtermBudget = 450;
  static const _factsBudget = 300;

  File _file(String name) => File(p.join(memoryDir.path, name));

  Future<CompileStatus> compileToday({
    DateTime? now,
    bool daily = false,
  }) async {
    final base = now ?? DateTime.now();
    final cutoff = base.subtract(const Duration(hours: 24));
    final input = _gatherSummaries(after: cutoff);
    if (input.isEmpty) {
      _atomicWrite(_file('today.md'), '');
      return CompileStatus.empty;
    }
    return _compile(
      output: _file('today.md'),
      input: input,
      cacheKey: 'today',
      systemPrompt:
          '将以下今天的对话摘要整合成一段概要（500字以内）。重点突出，抓关键事件和决策，保留时间标注（HH:MM）。直接输出概要文本。',
      maxTokens: _todayBudget,
    );
  }

  Future<CompileStatus> compileWeek({DateTime? now}) async {
    final base = now ?? DateTime.now();
    final cutoff = base.subtract(const Duration(days: 7));
    final input = _gatherSummaries(after: cutoff);
    if (input.isEmpty) {
      _atomicWrite(_file('week.md'), '');
      return CompileStatus.empty;
    }
    return _compile(
      output: _file('week.md'),
      input: input,
      cacheKey: 'week',
      systemPrompt: '将本周的对话摘要整合成一段概要（500字以内）。突出趋势和持续主题，保留具体决策点。直接输出概要文本。',
      maxTokens: _weekBudget,
    );
  }

  Future<CompileStatus> compileLongterm() async {
    final week = _file('week.md').existsSync()
        ? _file('week.md').readAsStringSync()
        : '';
    final oldLong = _file('longterm.md').existsSync()
        ? _file('longterm.md').readAsStringSync()
        : '';
    if (week.trim().isEmpty) {
      if (oldLong.trim().isNotEmpty) return CompileStatus.cached;
      _atomicWrite(_file('longterm.md'), '');
      return CompileStatus.empty;
    }
    final fingerprint = _md5(week.trim());
    if (_cacheMatches('longterm', fingerprint)) return CompileStatus.cached;
    return _compile(
      output: _file('longterm.md'),
      input: '## 旧长期记忆\n$oldLong\n\n## 本周\n$week',
      cacheKey: 'longterm',
      cacheFingerprint: fingerprint,
      systemPrompt: '将"旧长期记忆"与"本周"整合更新为新的长期记忆（300字以内）。保留稳定的人物特征、关系、关键事件。直接输出。',
      maxTokens: _longtermBudget,
    );
  }

  /// facts 编译：从摘要"## 重要事实"段抽取（30d 内）。
  /// 短输入直接写入，不调 LLM。
  Future<CompileStatus> compileFacts({DateTime? now}) async {
    final base = now ?? DateTime.now();
    final cutoff = base.subtract(const Duration(days: 30));
    final all = _gatherSummaries(after: cutoff);
    final prevFacts = _file('facts.md').existsSync()
        ? _file('facts.md').readAsStringSync().trim()
        : '';
    if (all.isEmpty) {
      if (prevFacts.isEmpty) _atomicWrite(_file('facts.md'), '');
      return CompileStatus.empty;
    }
    final factsBlocks = <String>[];
    final factsRe = RegExp(r'## 重要事实\s*\n([\s\S]*?)(?=\n## |\Z)');
    for (final m in factsRe.allMatches(all)) {
      final block = m.group(1)?.trim();
      if (block != null && block.isNotEmpty && block != '无') {
        factsBlocks.add(block);
      }
    }
    if (factsBlocks.isEmpty) {
      if (prevFacts.isEmpty) _atomicWrite(_file('facts.md'), '');
      return CompileStatus.empty;
    }
    final newFacts = factsBlocks.join('\n').trim();
    final combined = prevFacts.isEmpty ? newFacts : '$prevFacts\n$newFacts';

    final fingerprint = _md5(combined);
    if (_cacheMatches('facts', fingerprint)) return CompileStatus.cached;

    if (combined.length < 500) {
      _atomicWrite(_file('facts.md'), combined);
      _writeCache('facts', fingerprint);
      return CompileStatus.compiled;
    }

    return _compile(
      output: _file('facts.md'),
      input: combined,
      cacheKey: 'facts',
      cacheFingerprint: fingerprint,
      systemPrompt: '将以下"重要事实"片段去重整合为简洁清单（300字以内），保留每条事实独立。直接输出。',
      maxTokens: _factsBudget,
    );
  }

  Future<void> assemble() async {
    String read(String name) {
      final f = _file(name);
      if (!f.existsSync()) return '（暂无）';
      final s = f.readAsStringSync().trim();
      return s.isEmpty ? '（暂无）' : s;
    }

    final out =
        '''
## 重要事实
${read('facts.md')}

## 今天
${read('today.md')}

## 最近一周
${read('week.md')}

## 长期情况
${read('longterm.md')}
''';
    _atomicWrite(_file('memory.md'), out);
  }

  // -- internals --

  String _gatherSummaries({required DateTime after}) {
    if (!summaries.summariesDir.existsSync()) return '';
    final pieces = <String>[];
    for (final f in summaries.summariesDir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final updatedRaw = j['updated_at'] as String?;
        if (updatedRaw == null) continue;
        final updated = DateTime.tryParse(updatedRaw);
        if (updated == null || updated.isBefore(after)) continue;
        final summary = j['summary'] as String? ?? '';
        if (summary.isNotEmpty) pieces.add(summary);
      } catch (_) {}
    }
    return pieces.join('\n\n---\n\n');
  }

  Future<CompileStatus> _compile({
    required File output,
    required String input,
    required String cacheKey,
    String? cacheFingerprint,
    required String systemPrompt,
    required int maxTokens,
  }) async {
    final fp = cacheFingerprint ?? _md5(input);
    if (_cacheMatches(cacheKey, fp)) return CompileStatus.cached;
    String text;
    try {
      text = await callProviderText(
        provider: compilerProvider,
        model: compilerModel,
        userContent: input,
        systemPrompt: systemPrompt,
        temperature: 0.3,
        maxTokens: maxTokens,
      );
    } catch (e) {
      // 失败保留旧文件，记录但不抛
      _atomicAppendErr(output, '[compile failed: $e at ${DateTime.now()}]');
      return CompileStatus.failed;
    }
    _atomicWrite(output, text);
    _writeCache(cacheKey, fp);
    return CompileStatus.compiled;
  }

  void _atomicWrite(File f, String content) {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(content, flush: true);
    if (f.existsSync()) f.deleteSync();
    tmp.renameSync(f.path);
  }

  void _atomicAppendErr(File f, String line) {
    final errFile = File('${f.path}.err');
    errFile.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  String _md5(String s) => crypto.md5.convert(utf8.encode(s)).toString();

  File _cacheFile() => _file('.compile-cache.json');

  Map<String, String> _readCache() {
    final f = _cacheFile();
    if (!f.existsSync()) return {};
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return j.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  bool _cacheMatches(String key, String fingerprint) {
    return _readCache()[key] == fingerprint;
  }

  void _writeCache(String key, String fingerprint) {
    final cache = _readCache();
    cache[key] = fingerprint;
    _atomicWrite(_cacheFile(), jsonEncode(cache));
  }
}

enum CompileStatus { compiled, cached, empty, failed }
