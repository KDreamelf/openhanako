import 'fact_store.dart';

/// 与 legacy lib/memory/memory-search.js 对齐：标签优先 + FTS 补充的混合搜索。
class MemorySearch {
  MemorySearch(this.store);
  final FactStore store;

  /// 工具调用入口（供 chat session 注入工具）。
  /// 策略：
  ///   1. tags 非空 → 先按 tags 精确匹配（OR 逻辑），日期过滤
  ///   2. 结果 < 3 条 → FTS5 全文搜索补充
  ///   3. 合并 + 去重 + 限制 limit
  Future<List<FactView>> search({
    String? query,
    List<String> tags = const [],
    String? from,
    String? to,
    int limit = 15,
  }) async {
    final out = <FactView>[];
    final seen = <int>{};

    if (tags.isNotEmpty) {
      final tagHits = await store.searchByTags(
        tags,
        from: from,
        to: to,
        limit: limit,
      );
      for (final f in tagHits) {
        if (seen.add(f.id)) out.add(f);
      }
    }

    if (out.length < 3 && query != null && query.trim().isNotEmpty) {
      final ftsHits = await store.searchFullText(query, limit: 10);
      for (final f in ftsHits) {
        if (seen.add(f.id)) out.add(f);
        if (out.length >= limit) break;
      }
    }

    return out;
  }

  /// 把 fact 列表格式化成给 LLM 看的 markdown 列表。
  static String formatForPrompt(List<FactView> facts) {
    if (facts.isEmpty) return '（未找到相关事实）';
    final buf = StringBuffer();
    for (var i = 0; i < facts.length; i++) {
      final f = facts[i];
      final tagsStr = f.tags.isNotEmpty ? ' (${f.tags.join(", ")})' : '';
      final timeStr = f.time != null ? ' — ${f.time}' : '';
      buf.writeln('${i + 1}. ${f.fact}$tagsStr$timeStr');
    }
    return buf.toString();
  }
}
