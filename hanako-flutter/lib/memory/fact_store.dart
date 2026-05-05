import 'dart:convert';

import 'package:drift/drift.dart';

import 'database.dart';

/// FactStore 业务接口，与 legacy fact-store.js 一一对应。
class FactStore {
  FactStore(this.db);

  final HanaDatabase db;

  /// 新增一条事实，返回 id。
  Future<int> add({
    required String fact,
    List<String> tags = const [],
    String? time,
    String? sessionId,
  }) async {
    final cleaned = _scrubPii(fact);
    final createdAt = DateTime.now().toUtc().toIso8601String();
    return await db.into(db.facts).insert(FactsCompanion.insert(
          fact: cleaned,
          tags: Value(jsonEncode(tags)),
          time: Value(time),
          sessionId: Value(sessionId),
          createdAt: createdAt,
        ));
  }

  /// 批量新增（事务）。
  Future<int> addBatch(List<FactInput> entries) async {
    return await db.transaction(() async {
      var count = 0;
      for (final e in entries) {
        await add(
          fact: e.fact,
          tags: e.tags,
          time: e.time,
          sessionId: e.sessionId,
        );
        count++;
      }
      return count;
    });
  }

  /// 全部事实，按 time DESC。
  Future<List<FactView>> getAll() async {
    final rows = await (db.select(db.facts)
          ..orderBy([(t) => OrderingTerm.desc(t.time)]))
        .get();
    return rows.map(_fromRow).toList();
  }

  Future<List<FactView>> getBySession(String sessionId) async {
    final rows = await (db.select(db.facts)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([(t) => OrderingTerm.desc(t.time)]))
        .get();
    return rows.map(_fromRow).toList();
  }

  Future<FactView?> getById(int id) async {
    final row = await (db.select(db.facts)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  Future<int> count() async {
    final row = await db
        .customSelect('SELECT COUNT(*) as cnt FROM facts')
        .getSingle();
    return row.read<int>('cnt');
  }

  Future<bool> delete(int id) async {
    final n = await (db.delete(db.facts)..where((t) => t.id.equals(id))).go();
    return n > 0;
  }

  Future<void> clearAll() async {
    await db.transaction(() async {
      await db.delete(db.facts).go();
      await db.customStatement(
          "INSERT INTO facts_fts(facts_fts) VALUES ('rebuild')");
    });
  }

  /// 按 tags 精确匹配（OR 逻辑），按 matchCount DESC, time DESC。
  Future<List<FactView>> searchByTags(
    List<String> queryTags, {
    String? from,
    String? to,
    int limit = 20,
  }) async {
    if (queryTags.isEmpty) return const [];
    final placeholders =
        List.generate(queryTags.length, (_) => '?').join(', ');
    final dateClauses = <String>[];
    final args = <Variable>[];
    for (final t in queryTags) {
      args.add(Variable.withString(t));
    }
    if (from != null) {
      dateClauses.add('AND f.time >= ?');
      args.add(Variable.withString(from));
    }
    if (to != null) {
      dateClauses.add('AND f.time <= ?');
      args.add(Variable.withString(to));
    }
    args.add(Variable.withInt(limit));
    final sql = '''
      SELECT f.*, COUNT(DISTINCT je.value) AS matchCount
      FROM facts f, json_each(f.tags) je
      WHERE je.value IN ($placeholders) ${dateClauses.join(' ')}
      GROUP BY f.id
      ORDER BY matchCount DESC, f.time DESC
      LIMIT ?
    ''';
    final rows = await db.customSelect(sql, variables: args).get();
    return rows.map((r) => _viewFromRaw(r.data)).toList();
  }

  /// FTS5 全文搜索；失败降级 LIKE。
  Future<List<FactView>> searchFullText(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final ftsQuery = q
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .map((w) => '"${w.replaceAll('"', '""')}"')
          .join(' OR ');
      final rows = await db.customSelect(
        '''
        SELECT f.*, rank
        FROM facts_fts fts JOIN facts f ON f.id = fts.rowid
        WHERE facts_fts MATCH ? ORDER BY rank LIMIT ?
        ''',
        variables: [
          Variable.withString(ftsQuery),
          Variable.withInt(limit),
        ],
      ).get();
      return rows.map((r) => _viewFromRaw(r.data)).toList();
    } catch (_) {
      return _likeFallback(q, limit);
    }
  }

  Future<List<FactView>> _likeFallback(String q, int limit) async {
    final rows = await db.customSelect(
      "SELECT * FROM facts WHERE fact LIKE '%' || ? || '%' "
      "ORDER BY time DESC LIMIT ?",
      variables: [
        Variable.withString(q),
        Variable.withInt(limit),
      ],
    ).get();
    return rows.map((r) => _viewFromRaw(r.data)).toList();
  }

  // -- internals --

  /// 与 legacy lib/pii-guard.js 思路对齐：扫描 4 类常见 PII，redact 替换。
  /// Phase 1 仅实现最常见 4 类（信用卡 / 身份证 / 手机 / 邮箱），
  /// Phase 2 再扩展（IP / 银行卡变体 / token 关键字）。
  static String _scrubPii(String text) {
    var out = text;
    out = out.replaceAll(
        RegExp(r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'), '[REDACTED:CARD]');
    out = out.replaceAll(RegExp(r'\b\d{17}[\dXx]\b'), '[REDACTED:ID]');
    out = out.replaceAll(RegExp(r'\b1[3-9]\d{9}\b'), '[REDACTED:PHONE]');
    out = out.replaceAll(
        RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b'), '[REDACTED:EMAIL]');
    return out;
  }

  FactView _fromRow(Fact row) => FactView(
        id: row.id,
        fact: row.fact,
        tags: _parseTags(row.tags),
        time: row.time,
        sessionId: row.sessionId,
        createdAt: row.createdAt,
      );

  FactView _viewFromRaw(Map<String, Object?> r) => FactView(
        id: r['id'] as int,
        fact: r['fact'] as String,
        tags: _parseTags(r['tags'] as String? ?? '[]'),
        time: r['time'] as String?,
        sessionId: r['session_id'] as String?,
        createdAt: r['created_at'] as String,
        matchCount: r['matchCount'] is int ? r['matchCount'] as int : null,
      );

  List<String> _parseTags(String s) {
    try {
      final j = jsonDecode(s);
      if (j is List) return j.cast<String>();
    } catch (_) {}
    return const [];
  }
}

class FactInput {
  final String fact;
  final List<String> tags;
  final String? time;
  final String? sessionId;
  const FactInput({
    required this.fact,
    this.tags = const [],
    this.time,
    this.sessionId,
  });
}

class FactView {
  final int id;
  final String fact;
  final List<String> tags;
  final String? time;
  final String? sessionId;
  final String createdAt;
  final int? matchCount;
  const FactView({
    required this.id,
    required this.fact,
    required this.tags,
    this.time,
    this.sessionId,
    required this.createdAt,
    this.matchCount,
  });
}
