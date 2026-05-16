import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/llm/provider.dart';
import 'package:hanako/local_tools/local_tools.dart';
import 'package:hanako/memory/claude_memory.dart';
import 'package:hanako/memory/database.dart';
import 'package:hanako/memory/fact_store.dart';
import 'package:hanako/memory/memory_compile.dart';
import 'package:hanako/memory/session_summary.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hanako_memory_parity_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('facts 写入去重并支持标签与全文搜索', () async {
    final db = HanaDatabase(NativeDatabase(File(p.join(tmp.path, 'facts.db'))));
    addTearDown(db.close);
    final store = FactStore(db);

    final first = await store.add(
      fact: 'Hanako prefers compact memory summaries',
      tags: ['memory', 'memory', 'summary'],
      sessionId: 's1',
    );
    final duplicate = await store.add(
      fact: 'Hanako prefers compact memory summaries',
      tags: ['other'],
      sessionId: 's2',
    );
    await store.importAll([
      const FactInput(
        fact: 'Angel likes structured Chinese replies',
        tags: ['angel', 'style'],
      ),
      const FactInput(
        fact: 'Angel likes structured Chinese replies',
        tags: ['duplicate'],
      ),
    ]);

    expect(duplicate, first);
    expect(await store.count(), 2);
    expect((await store.getById(first))!.tags, ['memory', 'summary']);
    expect(
      (await store.searchByTags(['memory'])).single.fact,
      'Hanako prefers compact memory summaries',
    );
    expect(
      (await store.searchFullText('structured')).single.fact,
      'Angel likes structured Chinese replies',
    );
  });

  test('session summary 可保存、读取并标记已处理', () {
    final summaries = SessionSummaryStore(Directory(p.join(tmp.path, 'sum')));
    final now = DateTime.now().toUtc().toIso8601String();
    summaries.save(
      SessionSummary(
        sessionId: 's1',
        createdAt: now,
        updatedAt: now,
        summary: '## 重要事实\n天使偏好简洁。\n\n## 事情经过\n完成记忆验收。',
        snapshot: '',
      ),
    );

    final loaded = summaries.load('s1');
    expect(loaded?.sessionId, 's1');
    expect(summaries.getDirty().map((s) => s.sessionId), ['s1']);

    summaries.markProcessed('s1');
    expect(summaries.load('s1')!.isDirty, false);
    expect(summaries.getDirty(), isEmpty);
  });

  test('memory compiler 继承旧 facts 并避免 longterm 重复折叠', () async {
    final memoryDir = Directory(p.join(tmp.path, 'memory'))..createSync();
    final summaries = SessionSummaryStore(
      Directory(p.join(memoryDir.path, 'summaries')),
    );
    final provider = _StaticLlmProvider('长期记忆已更新');
    final compiler = MemoryCompiler(
      memoryDir: memoryDir,
      summaries: summaries,
      compilerProvider: provider,
      compilerModel: 'test-model',
    );
    final factsFile = File(p.join(memoryDir.path, 'facts.md'))
      ..writeAsStringSync('- 旧事实\n');

    expect(await compiler.compileFacts(), CompileStatus.empty);
    expect(factsFile.readAsStringSync(), '- 旧事实\n');

    final now = DateTime.now().toUtc().toIso8601String();
    summaries.save(
      SessionSummary(
        sessionId: 's2',
        createdAt: now,
        updatedAt: now,
        summary: '## 重要事实\n- 天使希望任务完成一个接一个推进。\n\n## 事情经过\n完成记忆 parity。',
        snapshot: '',
      ),
    );

    expect(await compiler.compileFacts(), CompileStatus.compiled);
    expect(factsFile.readAsStringSync(), contains('- 旧事实'));
    expect(factsFile.readAsStringSync(), contains('一个接一个推进'));

    File(p.join(memoryDir.path, 'week.md')).writeAsStringSync('');
    File(p.join(memoryDir.path, 'longterm.md')).writeAsStringSync('旧长期记忆');
    expect(await compiler.compileLongterm(), CompileStatus.cached);
    expect(provider.calls, 0);

    File(p.join(memoryDir.path, 'week.md')).writeAsStringSync('本周新增');
    expect(await compiler.compileLongterm(), CompileStatus.compiled);
    expect(provider.calls, 1);
    expect(await compiler.compileLongterm(), CompileStatus.cached);
    expect(provider.calls, 1);

    await compiler.assemble();
    final assembled = File(
      p.join(memoryDir.path, 'memory.md'),
    ).readAsStringSync();
    expect(assembled, contains('## 重要事实'));
    expect(assembled, contains('## 最近一周'));
    expect(assembled, contains('长期记忆已更新'));
  });

  test('pinned memory 支持 pin / list / unpin', () async {
    final names = LocalToolRegistry.buildTools()
        .map((tool) => tool.name)
        .toSet();
    expect(names, contains(LocalToolNames.listPinnedMemory));

    await LocalToolRegistry.execute(LocalToolNames.pinMemory, {
      'content': '记住邮箱 angel@example.com',
    }, agentDir: tmp.path);
    await LocalToolRegistry.execute(LocalToolNames.pinMemory, {
      'content': '记住邮箱 angel@example.com',
    }, agentDir: tmp.path);

    final listedRaw = await LocalToolRegistry.execute(
      LocalToolNames.listPinnedMemory,
      {},
      agentDir: tmp.path,
    );
    final listed = jsonDecode(listedRaw) as Map<String, dynamic>;
    expect(listed['ok'], true);
    expect(listed['items'], ['记住邮箱 [REDACTED:EMAIL]']);

    await LocalToolRegistry.execute(LocalToolNames.unpinMemory, {
      'keyword': 'redacted',
    }, agentDir: tmp.path);
    final afterRaw = await LocalToolRegistry.execute(
      LocalToolNames.listPinnedMemory,
      {},
      agentDir: tmp.path,
    );
    final after = jsonDecode(afterRaw) as Map<String, dynamic>;
    expect(after['items'], isEmpty);
  });

  test('Claude 风格记忆目录会加载 MEMORY.md 并递归扫描 topic 文件', () async {
    final agentDir = Directory(p.join(tmp.path, 'agents', 'agent_01'))
      ..createSync(recursive: true);
    final memoryRoot = getClaudeMemoryRoot(agentDir);
    final teamRoot = getClaudeTeamMemoryRoot(agentDir);
    await ensureMemoryDirExists(memoryRoot);
    await ensureMemoryDirExists(teamRoot);

    File(
      p.join(memoryRoot.path, 'MEMORY.md'),
    ).writeAsStringSync('- [用户偏好](user.md) — 天使的中文回复约定\n');
    File(p.join(memoryRoot.path, 'user.md')).writeAsStringSync(
      '---\n'
      'description: 用户偏好\n'
      'type: user\n'
      '---\n'
      '天使喜欢简洁中文回复。\n',
    );
    File(
      p.join(teamRoot.path, 'MEMORY.md'),
    ).writeAsStringSync('- [团队约定](rule.md) — 不同步全量列表\n');
    File(p.join(teamRoot.path, 'rule.md')).writeAsStringSync(
      '---\n'
      'description: 团队约定\n'
      'type: project\n'
      '---\n'
      '部署时只缓存经手内容，不做全量同步。\n',
    );

    final headers = await scanMemoryFiles(memoryRoot);
    expect(
      headers.map((header) => header.filename),
      containsAll(['user.md', p.join('team', 'rule.md')]),
    );

    final results = await searchMemoryFiles(memoryRoot, '中文回复', maxResults: 5);
    expect(results, hasLength(1));
    expect(results.single.filename, 'user.md');
    expect(results.single.description, '用户偏好');
    expect(
      results.single.toJson(),
      containsPair('path', p.join(memoryRoot.path, 'user.md')),
    );

    final prompt = await buildMemoryPrompt(
      memoryRoot: memoryRoot,
      displayName: 'auto memory',
      teamMode: true,
      teamMemoryRoot: teamRoot,
    );
    expect(prompt, contains(memoryRoot.path));
    expect(prompt, contains('用户偏好'));
    expect(prompt, contains('团队约定'));
    expect(prompt, contains('frontmatter'));
    expect(prompt, contains('MEMORY.md 只是索引'));
    expect(prompt, contains('从记忆给出建议前必须验证'));
    expect(prompt, contains('非平凡实现任务的步骤和进度使用 update_plan'));
  });
}

class _StaticLlmProvider implements LlmProvider {
  _StaticLlmProvider(this.response);

  final String response;
  int calls = 0;

  @override
  String get name => 'static';

  @override
  Stream<LlmEvent> chat({
    required List<Message> messages,
    required String model,
    List<Tool>? tools,
    bool? thinking,
    CancelToken? cancelToken,
  }) async* {
    calls++;
    yield TextDelta(response);
    yield const MessageDone();
  }
}
