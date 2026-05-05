// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $FactsTable extends Facts with TableInfo<$FactsTable, Fact> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FactsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _factMeta = const VerificationMeta('fact');
  @override
  late final GeneratedColumn<String> fact = GeneratedColumn<String>(
    'fact',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tagsMeta = const VerificationMeta('tags');
  @override
  late final GeneratedColumn<String> tags = GeneratedColumn<String>(
    'tags',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumn<String> time = GeneratedColumn<String>(
    'time',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    fact,
    tags,
    time,
    sessionId,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'facts';
  @override
  VerificationContext validateIntegrity(
    Insertable<Fact> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('fact')) {
      context.handle(
        _factMeta,
        fact.isAcceptableOrUnknown(data['fact']!, _factMeta),
      );
    } else if (isInserting) {
      context.missing(_factMeta);
    }
    if (data.containsKey('tags')) {
      context.handle(
        _tagsMeta,
        tags.isAcceptableOrUnknown(data['tags']!, _tagsMeta),
      );
    }
    if (data.containsKey('time')) {
      context.handle(
        _timeMeta,
        time.isAcceptableOrUnknown(data['time']!, _timeMeta),
      );
    }
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Fact map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Fact(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      fact: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fact'],
      )!,
      tags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags'],
      )!,
      time: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}time'],
      ),
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $FactsTable createAlias(String alias) {
    return $FactsTable(attachedDatabase, alias);
  }
}

class Fact extends DataClass implements Insertable<Fact> {
  final int id;
  final String fact;

  /// JSON-encoded `List<String>`
  final String tags;
  final String? time;
  final String? sessionId;
  final String createdAt;
  const Fact({
    required this.id,
    required this.fact,
    required this.tags,
    this.time,
    this.sessionId,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['fact'] = Variable<String>(fact);
    map['tags'] = Variable<String>(tags);
    if (!nullToAbsent || time != null) {
      map['time'] = Variable<String>(time);
    }
    if (!nullToAbsent || sessionId != null) {
      map['session_id'] = Variable<String>(sessionId);
    }
    map['created_at'] = Variable<String>(createdAt);
    return map;
  }

  FactsCompanion toCompanion(bool nullToAbsent) {
    return FactsCompanion(
      id: Value(id),
      fact: Value(fact),
      tags: Value(tags),
      time: time == null && nullToAbsent ? const Value.absent() : Value(time),
      sessionId: sessionId == null && nullToAbsent
          ? const Value.absent()
          : Value(sessionId),
      createdAt: Value(createdAt),
    );
  }

  factory Fact.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Fact(
      id: serializer.fromJson<int>(json['id']),
      fact: serializer.fromJson<String>(json['fact']),
      tags: serializer.fromJson<String>(json['tags']),
      time: serializer.fromJson<String?>(json['time']),
      sessionId: serializer.fromJson<String?>(json['sessionId']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'fact': serializer.toJson<String>(fact),
      'tags': serializer.toJson<String>(tags),
      'time': serializer.toJson<String?>(time),
      'sessionId': serializer.toJson<String?>(sessionId),
      'createdAt': serializer.toJson<String>(createdAt),
    };
  }

  Fact copyWith({
    int? id,
    String? fact,
    String? tags,
    Value<String?> time = const Value.absent(),
    Value<String?> sessionId = const Value.absent(),
    String? createdAt,
  }) => Fact(
    id: id ?? this.id,
    fact: fact ?? this.fact,
    tags: tags ?? this.tags,
    time: time.present ? time.value : this.time,
    sessionId: sessionId.present ? sessionId.value : this.sessionId,
    createdAt: createdAt ?? this.createdAt,
  );
  Fact copyWithCompanion(FactsCompanion data) {
    return Fact(
      id: data.id.present ? data.id.value : this.id,
      fact: data.fact.present ? data.fact.value : this.fact,
      tags: data.tags.present ? data.tags.value : this.tags,
      time: data.time.present ? data.time.value : this.time,
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Fact(')
          ..write('id: $id, ')
          ..write('fact: $fact, ')
          ..write('tags: $tags, ')
          ..write('time: $time, ')
          ..write('sessionId: $sessionId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, fact, tags, time, sessionId, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Fact &&
          other.id == this.id &&
          other.fact == this.fact &&
          other.tags == this.tags &&
          other.time == this.time &&
          other.sessionId == this.sessionId &&
          other.createdAt == this.createdAt);
}

class FactsCompanion extends UpdateCompanion<Fact> {
  final Value<int> id;
  final Value<String> fact;
  final Value<String> tags;
  final Value<String?> time;
  final Value<String?> sessionId;
  final Value<String> createdAt;
  const FactsCompanion({
    this.id = const Value.absent(),
    this.fact = const Value.absent(),
    this.tags = const Value.absent(),
    this.time = const Value.absent(),
    this.sessionId = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  FactsCompanion.insert({
    this.id = const Value.absent(),
    required String fact,
    this.tags = const Value.absent(),
    this.time = const Value.absent(),
    this.sessionId = const Value.absent(),
    required String createdAt,
  }) : fact = Value(fact),
       createdAt = Value(createdAt);
  static Insertable<Fact> custom({
    Expression<int>? id,
    Expression<String>? fact,
    Expression<String>? tags,
    Expression<String>? time,
    Expression<String>? sessionId,
    Expression<String>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (fact != null) 'fact': fact,
      if (tags != null) 'tags': tags,
      if (time != null) 'time': time,
      if (sessionId != null) 'session_id': sessionId,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  FactsCompanion copyWith({
    Value<int>? id,
    Value<String>? fact,
    Value<String>? tags,
    Value<String?>? time,
    Value<String?>? sessionId,
    Value<String>? createdAt,
  }) {
    return FactsCompanion(
      id: id ?? this.id,
      fact: fact ?? this.fact,
      tags: tags ?? this.tags,
      time: time ?? this.time,
      sessionId: sessionId ?? this.sessionId,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (fact.present) {
      map['fact'] = Variable<String>(fact.value);
    }
    if (tags.present) {
      map['tags'] = Variable<String>(tags.value);
    }
    if (time.present) {
      map['time'] = Variable<String>(time.value);
    }
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FactsCompanion(')
          ..write('id: $id, ')
          ..write('fact: $fact, ')
          ..write('tags: $tags, ')
          ..write('time: $time, ')
          ..write('sessionId: $sessionId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$HanaDatabase extends GeneratedDatabase {
  _$HanaDatabase(QueryExecutor e) : super(e);
  $HanaDatabaseManager get managers => $HanaDatabaseManager(this);
  late final $FactsTable facts = $FactsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [facts];
}

typedef $$FactsTableCreateCompanionBuilder =
    FactsCompanion Function({
      Value<int> id,
      required String fact,
      Value<String> tags,
      Value<String?> time,
      Value<String?> sessionId,
      required String createdAt,
    });
typedef $$FactsTableUpdateCompanionBuilder =
    FactsCompanion Function({
      Value<int> id,
      Value<String> fact,
      Value<String> tags,
      Value<String?> time,
      Value<String?> sessionId,
      Value<String> createdAt,
    });

class $$FactsTableFilterComposer extends Composer<_$HanaDatabase, $FactsTable> {
  $$FactsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fact => $composableBuilder(
    column: $table.fact,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FactsTableOrderingComposer
    extends Composer<_$HanaDatabase, $FactsTable> {
  $$FactsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fact => $composableBuilder(
    column: $table.fact,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FactsTableAnnotationComposer
    extends Composer<_$HanaDatabase, $FactsTable> {
  $$FactsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get fact =>
      $composableBuilder(column: $table.fact, builder: (column) => column);

  GeneratedColumn<String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<String> get time =>
      $composableBuilder(column: $table.time, builder: (column) => column);

  GeneratedColumn<String> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$FactsTableTableManager
    extends
        RootTableManager<
          _$HanaDatabase,
          $FactsTable,
          Fact,
          $$FactsTableFilterComposer,
          $$FactsTableOrderingComposer,
          $$FactsTableAnnotationComposer,
          $$FactsTableCreateCompanionBuilder,
          $$FactsTableUpdateCompanionBuilder,
          (Fact, BaseReferences<_$HanaDatabase, $FactsTable, Fact>),
          Fact,
          PrefetchHooks Function()
        > {
  $$FactsTableTableManager(_$HanaDatabase db, $FactsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FactsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FactsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FactsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> fact = const Value.absent(),
                Value<String> tags = const Value.absent(),
                Value<String?> time = const Value.absent(),
                Value<String?> sessionId = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
              }) => FactsCompanion(
                id: id,
                fact: fact,
                tags: tags,
                time: time,
                sessionId: sessionId,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String fact,
                Value<String> tags = const Value.absent(),
                Value<String?> time = const Value.absent(),
                Value<String?> sessionId = const Value.absent(),
                required String createdAt,
              }) => FactsCompanion.insert(
                id: id,
                fact: fact,
                tags: tags,
                time: time,
                sessionId: sessionId,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FactsTableProcessedTableManager =
    ProcessedTableManager<
      _$HanaDatabase,
      $FactsTable,
      Fact,
      $$FactsTableFilterComposer,
      $$FactsTableOrderingComposer,
      $$FactsTableAnnotationComposer,
      $$FactsTableCreateCompanionBuilder,
      $$FactsTableUpdateCompanionBuilder,
      (Fact, BaseReferences<_$HanaDatabase, $FactsTable, Fact>),
      Fact,
      PrefetchHooks Function()
    >;

class $HanaDatabaseManager {
  final _$HanaDatabase _db;
  $HanaDatabaseManager(this._db);
  $$FactsTableTableManager get facts =>
      $$FactsTableTableManager(_db, _db.facts);
}
