import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/agent_runtime.dart';
import 'package:hanako/core/runtime_session_store.dart';
import 'package:hanako/local_tools/local_tools.dart';
import 'package:path/path.dart' as p;

void main() {
  test('模型可见本地工具只保留 Codex 未覆盖的能力', () {
    final names = LocalToolRegistry.buildTools()
        .map((tool) => tool.name)
        .toSet();

    expect(
      names,
      containsAll(<String>[
        'web_search',
        'web_fetch',
        'search_memory',
        'pin_memory',
        'unpin_memory',
        'create_experience',
        'experience_search',
        'create_artifact',
        'browser',
      ]),
    );
    expect(names, isNot(contains('present_files')));
    expect(LocalToolRegistry.canExecute('present_files'), false);
    expect(names, isNot(contains('todo')));
    expect(names, isNot(contains('delegate')));
    expect(names, isNot(contains('dm')));
    expect(names, isNot(contains('message_agent')));
    expect(names, isNot(contains('ask_agent')));
    expect(names, isNot(contains('channel')));
    expect(names, isNot(contains('read')));
    expect(names, isNot(contains('write')));
    expect(names, isNot(contains('edit')));
    expect(names, isNot(contains('bash')));
    expect(names, isNot(contains('grep')));
    expect(names, isNot(contains('find')));
    expect(names, isNot(contains('ls')));
    expect(names, isNot(contains('experience_submit')));
    expect(names, isNot(contains('recall_experience')));
    expect(names, isNot(contains('record_experience')));

    final createExperience = LocalToolRegistry.buildTools().firstWhere(
      (tool) => tool.name == LocalToolNames.createExperience,
    );
    final properties =
        createExperience.parameters['properties'] as Map<String, dynamic>;
    final source = properties['source'] as Map<String, dynamic>;
    expect(source['enum'], ['current_session', 'raw_directory']);
    expect(properties.keys, isNot(contains('max_messages')));
    expect(properties.keys, isNot(contains('conversation')));
    expect(properties.keys, isNot(contains('events')));
  });

  test('create_experience 可把当前会话保存为本地私有经验', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sessionPath = [
      dir.path,
      'sessions',
      's1.jsonl',
    ].join(Platform.pathSeparator);
    RuntimeSessionStore.createSessionFile(sessionPath, sessionId: 's1');
    RuntimeSessionStore.appendMessages(sessionPath, [
      RuntimeMessage.userText('用户提出 needle 需求'),
      RuntimeMessage.assistant(
        blocks: [RuntimeTextBlock('AI 给出处理方案')],
        stopReason: 'stop',
      ),
    ], sessionId: 's1');

    final raw = await LocalToolRegistry.execute(
      LocalToolNames.createExperience,
      {
        'title': '会话经验',
        'brief': '从当前会话生成',
        'keywords': ['needle', '经验'],
      },
      agentDir: dir.path,
      sessionPath: sessionPath,
    );
    final body = jsonDecode(raw) as Map<String, dynamic>;
    final conversation = File(
      [
        body['content_path'] as String,
        'raw',
        'conversation.md',
      ].join(Platform.pathSeparator),
    ).readAsStringSync();

    expect(body['ok'], true);
    expect(body['scope'], 'private');
    expect(conversation, contains('用户提出 needle 需求'));
    expect(conversation, contains('AI 给出处理方案'));
  });

  test('create_experience 会在对话流中保留工具位置并保存图片附件', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sessionPath = [
      dir.path,
      'sessions',
      's1.jsonl',
    ].join(Platform.pathSeparator);
    RuntimeSessionStore.createSessionFile(sessionPath, sessionId: 's1');
    RuntimeSessionStore.appendMessages(sessionPath, [
      RuntimeMessage.userText('请检查屏幕'),
      RuntimeMessage.assistant(
        blocks: [
          const RuntimeTextBlock('我先读取图片。'),
          RuntimeToolCallBlock(
            id: 'call_1',
            name: 'view_image',
            argumentsJson: jsonEncode({'path': 'screen.png'}),
          ),
          const RuntimeTextBlock('读取后继续判断。'),
        ],
        stopReason: 'tool_calls',
      ),
      RuntimeMessage.toolResult(
        toolCallId: 'call_1',
        toolName: 'view_image',
        content: jsonEncode({
          'ok': true,
          'image_url': 'data:image/png;base64,$_onePixelPngBase64',
        }),
      ),
    ], sessionId: 's1');

    final raw = await LocalToolRegistry.execute(
      LocalToolNames.createExperience,
      {'title': '工具经验'},
      agentDir: dir.path,
      sessionPath: sessionPath,
    );
    final body = jsonDecode(raw) as Map<String, dynamic>;
    final contentPath = body['content_path'] as String;
    final conversation = File(
      [contentPath, 'raw', 'conversation.md'].join(Platform.pathSeparator),
    ).readAsStringSync();
    final events = File(
      [contentPath, 'raw', 'events.md'].join(Platform.pathSeparator),
    ).readAsStringSync();
    final toolFiles = Directory(
      [contentPath, 'tool-calls'].join(Platform.pathSeparator),
    ).listSync().whereType<File>().toList();
    final attachments = Directory(
      [contentPath, 'attachments'].join(Platform.pathSeparator),
    ).listSync().whereType<File>().toList();
    final toolText = toolFiles.single.readAsStringSync();

    expect(conversation, contains('我先读取图片。'));
    expect(conversation, contains('[工具调用 t0001：view_image]'));
    expect(conversation, contains('读取后继续判断。'));
    expect(events, contains('t0001 · 消息 2 · AI · view_image'));
    expect(toolText, contains('## 参数'));
    expect(toolText, contains('## 返回'));
    expect(toolText, isNot(contains('data:image/png;base64')));
    expect(toolText, contains('![t0001-result]'));
    expect(attachments.single.path, endsWith('.png'));
  });

  test('create_artifact 会写入本地文件并返回文件引用', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final raw = await LocalToolRegistry.execute(LocalToolNames.createArtifact, {
      'type': 'markdown',
      'title': '能力表格',
      'content': '# 能力表格\n\n| A | B |\n| - | - |\n',
    }, cwd: dir.path);
    final body = jsonDecode(raw) as Map<String, dynamic>;
    final artifact = body['artifact'] as Map<String, dynamic>;
    final files = body['files'] as List;
    final filePath = artifact['file_path'] as String;

    expect(body['ok'], true);
    expect(artifact.keys, isNot(contains('content')));
    expect(files, hasLength(1));
    expect((files.single as Map)['path'], filePath);
    expect(File(filePath).existsSync(), true);
    expect(File(filePath).readAsStringSync(), contains('| A | B |'));
    expect(p.basename(p.dirname(filePath)), 'artifacts');
  });

  test('assistant Markdown 本地文件链接会渲染为文件卡片块', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'report.md'))
      ..writeAsStringSync('# report');
    final sessionPath = p.join(dir.path, 'sessions', 's1.jsonl');
    RuntimeSessionStore.createSessionFile(sessionPath, sessionId: 's1');
    RuntimeSessionStore.appendMessages(sessionPath, [
      RuntimeMessage.assistant(
        blocks: [RuntimeTextBlock('已生成：\n- [报告.md](<${file.path}>)\n请查看。')],
        stopReason: 'stop',
      ),
    ], sessionId: 's1');

    final display = RuntimeSessionStore.loadDisplayMessages(sessionPath);
    final assistant = display.single;
    final fileBlock = assistant.blocks
        .whereType<RuntimeDisplayFileBlock>()
        .single;
    expect(fileBlock.path, file.path);
    expect(fileBlock.label, '报告.md');
    expect(fileBlock.exists, true);
    expect(assistant.copyText, contains('[文件：报告.md]'));
    expect(
      assistant.blocks.whereType<RuntimeDisplayTextBlock>().last.text,
      '请查看。',
    );
  });

  test('assistant Markdown 网页链接会渲染为网页链接卡片块', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sessionPath = p.join(dir.path, 'sessions', 's1.jsonl');
    RuntimeSessionStore.createSessionFile(sessionPath, sessionId: 's1');
    RuntimeSessionStore.appendMessages(sessionPath, [
      RuntimeMessage.assistant(
        blocks: [RuntimeTextBlock('参考 [示例站点](https://example.com/path)。')],
        stopReason: 'stop',
      ),
    ], sessionId: 's1');

    final display = RuntimeSessionStore.loadDisplayMessages(sessionPath);
    final assistant = display.single;
    final linkBlock = assistant.blocks
        .whereType<RuntimeDisplayLinkBlock>()
        .single;
    expect(linkBlock.url, 'https://example.com/path');
    expect(linkBlock.label, '示例站点');
    expect(assistant.copyText, contains('[链接：示例站点]'));
  });

  test('create_experience 可导入 Agent 写好的 raw_directory 脱敏目录', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final rawDir = Directory(
      [dir.path, 'redaction-work'].join(Platform.pathSeparator),
    )..createSync(recursive: true);
    Directory(
      [rawDir.path, 'raw'].join(Platform.pathSeparator),
    ).createSync(recursive: true);
    Directory(
      [rawDir.path, 'tool-calls'].join(Platform.pathSeparator),
    ).createSync(recursive: true);
    Directory(
      [rawDir.path, 'attachments'].join(Platform.pathSeparator),
    ).createSync(recursive: true);
    File(
      [rawDir.path, 'metadata.json'].join(Platform.pathSeparator),
    ).writeAsStringSync(
      jsonEncode({
        'schema_version': 'ph01.experience.raw.v1',
        'experience_id': 'exp_redacted_demo',
        'title': '脱敏经验',
        'brief': '由独立 Agent 脱敏任务生成',
        'keywords': ['needle', '脱敏'],
        'created_at': '2026-05-10T00:00:00Z',
      }),
    );
    File(
      [rawDir.path, 'raw', 'conversation.md'].join(Platform.pathSeparator),
    ).writeAsStringSync('## 1. 用户\n\n脱敏后的 needle 内容\n');
    File(
      [rawDir.path, 'raw', 'events.md'].join(Platform.pathSeparator),
    ).writeAsStringSync('## 1. AI 调用 read\n\n{}\n');

    final raw = await LocalToolRegistry.execute(
      LocalToolNames.createExperience,
      {
        'source': 'raw_directory',
        'title': '脱敏经验',
        'raw_directory': rawDir.path,
      },
      agentDir: dir.path,
      cwd: dir.path,
    );
    final body = jsonDecode(raw) as Map<String, dynamic>;
    final conversation = File(
      [
        body['content_path'] as String,
        'raw',
        'conversation.md',
      ].join(Platform.pathSeparator),
    ).readAsStringSync();

    expect(body['ok'], true);
    expect(body['experience_id'], 'exp_redacted_demo');
    expect(body['scope'], 'private');
    expect(conversation, contains('脱敏后的 needle 内容'));
  });

  test('create_experience 拒绝 AI 直接提供完整经验正文', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final raw =
        await LocalToolRegistry.execute(LocalToolNames.createExperience, {
          'source': 'provided_content',
          'title': '不允许的经验',
          'conversation': 'AI 直接输出的完整经验正文',
        }, agentDir: dir.path);
    final body = jsonDecode(raw) as Map<String, dynamic>;

    expect(body['ok'], false);
    expect(body['message'], contains('未知 create_experience source'));
  });

  test('search_memory 会递归搜索 topic 文件并忽略 MEMORY.md 本体', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final memoryRoot = Directory(p.join(dir.path, 'memory'))
      ..createSync(recursive: true);
    Directory(p.join(memoryRoot.path, 'team')).createSync(recursive: true);
    File(
      p.join(memoryRoot.path, 'MEMORY.md'),
    ).writeAsStringSync('- [用户偏好](user.md) — 中文回复\n');
    File(p.join(memoryRoot.path, 'user.md')).writeAsStringSync(
      '---\n'
      'description: 用户偏好\n'
      'type: user\n'
      '---\n'
      '这里包含 needle 命中。\n',
    );
    File(p.join(memoryRoot.path, 'team', 'rule.md')).writeAsStringSync(
      '---\n'
      'description: 团队约定\n'
      'type: project\n'
      '---\n'
      '团队文件里也有 needle 命中。\n',
    );

    final raw = await LocalToolRegistry.execute(LocalToolNames.searchMemory, {
      'query': 'needle',
      'max_results': 10,
    }, agentDir: dir.path);
    final body = jsonDecode(raw) as Map<String, dynamic>;
    final results = (body['results'] as List)
        .map((item) => item as Map<String, dynamic>)
        .toList(growable: false);
    final paths = results.map((item) => item['path'] as String).toList();

    expect(body['ok'], true);
    expect(body['memory_root'], memoryRoot.path);
    expect(
      paths,
      containsAll([
        p.join(memoryRoot.path, 'user.md'),
        p.join(memoryRoot.path, 'team', 'rule.md'),
      ]),
    );
    expect(paths, isNot(contains(p.join(memoryRoot.path, 'MEMORY.md'))));
    expect(
      results.firstWhere(
        (item) => item['path'] == p.join(memoryRoot.path, 'user.md'),
      )['line'],
      5,
    );
  });

  test('experience_search 只返回路径行号片段', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final contentDir = Directory(
      [
        dir.path,
        'experience',
        'private',
        'exp_demo',
        'content',
        'raw',
      ].join(Platform.pathSeparator),
    )..createSync(recursive: true);
    File(
      [contentDir.parent.path, 'metadata.json'].join(Platform.pathSeparator),
    ).writeAsStringSync('{"experience_id":"exp_demo","title":"Demo"}');
    File(
      [contentDir.path, 'conversation.md'].join(Platform.pathSeparator),
    ).writeAsStringSync('第一行 needle 命中，但全文不应直接返回\n第二行上下文\n');

    final raw = await LocalToolRegistry.execute(
      LocalToolNames.experienceSearch,
      {'query': 'needle'},
      agentDir: dir.path,
    );
    final body = jsonDecode(raw) as Map<String, dynamic>;
    final results = body['results'] as List;
    final first = results.single as Map<String, dynamic>;

    expect(body['ok'], true);
    expect(first['experience_id'], 'exp_demo');
    expect(first['line'], 1);
    expect(first.keys, containsAll(['path', 'line', 'snippet']));
    expect(first.keys, isNot(contains('content')));
  });
}

const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=';
