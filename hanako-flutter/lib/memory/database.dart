import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

part 'database.g.dart';

/// 与 legacy-electron/lib/memory/fact-store.js schema 对齐。
/// v2 简化版：单表 facts + FTS5 虚表 facts_fts。
/// 不再有 importance / decay / hit_count（v1 已废弃）。
@DataClassName('Fact')
class Facts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get fact => text()();

  /// JSON-encoded `List<String>`
  TextColumn get tags => text().withDefault(const Constant('[]'))();

  TextColumn get time => text().nullable()();

  TextColumn get sessionId =>
      text().nullable().named('session_id')();

  TextColumn get createdAt => text().named('created_at')();
}

@DriftDatabase(tables: [Facts])
class HanaDatabase extends _$HanaDatabase {
  HanaDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _ensureFtsAndTriggers();
        },
        beforeOpen: (details) async {
          // 与 legacy fact-store.js 一致的 PRAGMA
          await customStatement('PRAGMA journal_mode = WAL');
          await customStatement('PRAGMA synchronous = NORMAL');
          await customStatement('PRAGMA cache_size = -16000');
          await customStatement('PRAGMA temp_store = MEMORY');
          await customStatement('PRAGMA mmap_size = 30000000');

          // 兼容外部（legacy node 端）创建的 db
          if (!details.wasCreated) {
            await _ensureFtsAndTriggers();
          }
        },
      );

  Future<void> _ensureFtsAndTriggers() async {
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
        fact,
        content=facts,
        content_rowid=id,
        tokenize='unicode61'
      )
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
        INSERT INTO facts_fts(rowid, fact) VALUES (new.id, new.fact);
      END;
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS facts_ad AFTER DELETE ON facts BEGIN
        INSERT INTO facts_fts(facts_fts, rowid, fact) VALUES ('delete', old.id, old.fact);
      END;
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS facts_au AFTER UPDATE ON facts BEGIN
        INSERT INTO facts_fts(facts_fts, rowid, fact) VALUES ('delete', old.id, old.fact);
        INSERT INTO facts_fts(rowid, fact) VALUES (new.id, new.fact);
      END;
    ''');
  }
}

LazyDatabase _openConnection(File dbFile) {
  return LazyDatabase(() async {
    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
    }
    final cachebase = (await getTemporaryDirectory()).path;
    sqlite3.tempDirectory = cachebase;
    return NativeDatabase.createInBackground(dbFile);
  });
}

/// 打开指定路径的 facts.db（直接复用现有 better-sqlite3 创建的 db）。
HanaDatabase openHanaDatabaseAt(File file) {
  file.parent.createSync(recursive: true);
  return HanaDatabase(_openConnection(file));
}
