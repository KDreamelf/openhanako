import 'dart:async';
import 'dart:convert';

import '../llm/provider.dart';
import '../llm/utility.dart';
import '../memory/fact_store.dart';
import 'session_summary.dart';

/// 与 legacy lib/memory/deep-memory.js 对齐：把脏 session summary 拆分为元事实，
/// LLM 输出 JSON 数组，每条事实带 tags + time，写入 FactStore。
class DeepMemory {
  DeepMemory({
    required this.factStore,
    required this.summaries,
    required this.compilerProvider,
    required this.compilerModel,
  });

  final FactStore factStore;
  final SessionSummaryStore summaries;
  final LlmProvider compilerProvider;
  final String compilerModel;

  static const _maxConcurrent = 3;
  static const _maxRetries = 3;

  Future<DeepMemoryReport> processDirty() async {
    final dirty = summaries.getDirty();
    final report = DeepMemoryReport(total: dirty.length);
    if (dirty.isEmpty) return report;

    // 简单批量并发：每批 _maxConcurrent 条同时处理，等批结束再下一批
    for (var i = 0; i < dirty.length; i += _maxConcurrent) {
      final end = (i + _maxConcurrent).clamp(0, dirty.length);
      final batch = dirty.sublist(i, end);
      await Future.wait(batch.map((s) => _processOne(s, report)));
    }
    return report;
  }

  Future<void> _processOne(
      SessionSummary s, DeepMemoryReport report) async {
    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        final facts = await _extractFacts(s);
        if (facts.isNotEmpty) {
          await factStore.addBatch(facts
              .map((f) => FactInput(
                    fact: f.fact,
                    tags: f.tags,
                    time: f.time,
                    sessionId: s.sessionId,
                  ))
              .toList());
          report.factsAdded += facts.length;
        }
        summaries.markProcessed(s.sessionId);
        report.processed += 1;
        return;
      } catch (e) {
        report.lastError = '$e';
        if (attempt == _maxRetries - 1) {
          report.failed += 1;
          return;
        }
        await Future<void>.delayed(Duration(seconds: (attempt + 1) * 2));
      }
    }
  }

  Future<List<_ExtractedFact>> _extractFacts(SessionSummary s) async {
    final hasPrev = s.snapshot.isNotEmpty;
    final userContent = hasPrev
        ? '## 上次快照\n\n${s.snapshot}\n\n## 当前摘要\n\n${s.summary}'
        : '## 摘要内容\n\n${s.summary}';

    final systemPrompt = '''
请从以下会话摘要中提取**元事实**（atomic facts），输出 JSON 数组。每条 fact 必须满足：
- 原子性：一条 fact 只记一件事
- 标签 2-5 个：选择有辨识度的关键词（人名、项目、技术、主题）
- time：从摘要中时间标注提取（YYYY-MM-DDTHH:MM 或 YYYY-MM-DD），无法确定填 null
- 不提取助手的内心活动、情绪修饰，只记客观事实

输出严格 JSON 数组（不带 ```json 围栏，不带前后文本）：
[
  {"fact": "...", "tags": ["t1","t2"], "time": "2026-04-01T14:30"},
  ...
]
若无可提取事实，输出 []。''';

    final raw = await callProviderText(
      provider: compilerProvider,
      model: compilerModel,
      userContent: userContent,
      systemPrompt: systemPrompt,
      temperature: 0.2,
      maxTokens: 1024,
    );

    return _parseFacts(raw);
  }

  List<_ExtractedFact> _parseFacts(String raw) {
    var s = raw.trim();
    // 容忍 ```json ... ``` 围栏
    if (s.startsWith('```')) {
      final end = s.lastIndexOf('```');
      if (end > 3) {
        s = s.substring(s.indexOf('\n') + 1, end).trim();
      }
    }
    Object? j;
    try {
      j = jsonDecode(s);
    } catch (_) {
      return const [];
    }
    if (j is! List) return const [];
    final out = <_ExtractedFact>[];
    for (final item in j) {
      if (item is! Map) continue;
      final fact = item['fact'] as String?;
      if (fact == null || fact.trim().isEmpty) continue;
      final tagsRaw = item['tags'];
      final tags = <String>[];
      if (tagsRaw is List) {
        for (final t in tagsRaw) {
          if (t is String && t.trim().isNotEmpty) tags.add(t.trim());
        }
      }
      out.add(_ExtractedFact(
        fact: fact.trim(),
        tags: tags,
        time: item['time'] as String?,
      ));
    }
    return out;
  }
}

class _ExtractedFact {
  final String fact;
  final List<String> tags;
  final String? time;
  const _ExtractedFact(
      {required this.fact, required this.tags, required this.time});
}

class DeepMemoryReport {
  DeepMemoryReport({required this.total});
  final int total;
  int processed = 0;
  int factsAdded = 0;
  int failed = 0;
  String? lastError;

  @override
  String toString() =>
      'DeepMemoryReport(total=$total, processed=$processed, +facts=$factsAdded, failed=$failed${lastError != null ? ", err=$lastError" : ""})';
}
