// Drift schema 兼容验证测试。
//
// 验证 Phase 1 的 [HanaDatabase] 能正确打开 legacy `better-sqlite3` 创建的 facts.db：
//   1. 用 raw sqlite3 包按 fact-store.js 的精确 schema 创建一个旧 db；
//   2. 写入若干 fact 行 + tags JSON；
//   3. 用 Drift 打开同一个文件；
//   4. 验证能读到 fact，FTS 搜索能命中，schema 不报错。

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/memory/database.dart';
import 'package:hanako/memory/fact_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hanako_drift_compat_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('Drift opens legacy better-sqlite3 schema and reads existing rows',
      () async {
    final dbFile = File(p.join(tmp.path, 'facts.db'));

    // 1. 用 raw sqlite3 创建 v1 schema（与 legacy fact-store.js 完全一致）
    {
      final raw = sqlite3.open(dbFile.path);
      raw.execute('PRAGMA journal_mode = WAL');
      raw.execute('PRAGMA user_version = 1');
      raw.execute('''
        CREATE TABLE IF NOT EXISTS facts (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          fact       TEXT NOT NULL,
          tags       TEXT NOT NULL DEFAULT '[]',
          time       TEXT,
          session_id TEXT,
          created_at TEXT NOT NULL
        );
      ''');
      raw.execute(
          'CREATE INDEX IF NOT EXISTS idx_facts_time ON facts(time);');
      raw.execute(
          'CREATE INDEX IF NOT EXISTS idx_facts_session ON facts(session_id);');
      raw.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
          fact, content=facts, content_rowid=id, tokenize='unicode61'
        );
      ''');
      // 触发器
      raw.execute('''
        CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
          INSERT INTO facts_fts(rowid, fact) VALUES (new.id, new.fact);
        END;
      ''');

      // 写入两条 legacy 风格的事实
      final now = DateTime.now().toUtc().toIso8601String();
      raw.execute(
        "INSERT INTO facts (fact, tags, time, session_id, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        [
          '夏目宇宙人是来自外星的猫科生物',
          jsonEncode(['夏目', '猫']),
          now,
          's1',
          now,
        ],
      );
      raw.execute(
        "INSERT INTO facts (fact, tags, time, session_id, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        [
          'cosmo loves lasagna',
          jsonEncode(['cosmo', 'food']),
          now,
          's2',
          now,
        ],
      );
      raw.dispose();
    }

    // 2. 用 Drift 打开同一文件
    final db = HanaDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    // 3. 验证 schema_version
    final ver = await db
        .customSelect('PRAGMA user_version')
        .getSingle();
    expect(ver.read<int>('user_version'), 1);

    // 4. 验证读取
    final store = FactStore(db);
    final all = await store.getAll();
    expect(all.length, 2);
    expect(all.map((f) => f.fact),
        containsAll(['夏目宇宙人是来自外星的猫科生物', 'cosmo loves lasagna']));
    expect(all.firstWhere((f) => f.tags.contains('夏目')).sessionId, 's1');

    // 5. 验证 FTS 搜索（在 Drift 端）
    final hits = await store.searchFullText('cosmo');
    expect(hits.isNotEmpty, true);
    expect(hits.first.fact, 'cosmo loves lasagna');

    // 6. 验证 Drift 端写入也能被 FTS 索引（触发器 facts_ai 由 Drift create 时再次保证）
    await store.add(fact: 'verify drift insert', tags: ['drift']);
    final allAfter = await store.getAll();
    expect(allAfter.length, 3);
    final hits2 = await store.searchFullText('verify');
    expect(hits2.isNotEmpty, true);
  });
}
