import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/local_tools/local_tools.dart';

void main() {
  test('原生工具面包含原 TS 版基础工具与自定义工具', () {
    final names = LocalToolRegistry.buildTools()
        .map((tool) => tool.name)
        .toSet();

    expect(
      names,
      containsAll(<String>[
        'read',
        'write',
        'edit',
        'bash',
        'grep',
        'find',
        'ls',
        'web_search',
        'web_fetch',
        'todo',
        'search_memory',
        'pin_memory',
        'unpin_memory',
        'recall_experience',
        'record_experience',
        'present_files',
        'create_artifact',
        'browser',
        'delegate',
      ]),
    );
  });

  test('读取本地文本文件', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}sample.txt')
      ..writeAsStringSync('hello ph01');

    final raw = await LocalToolRegistry.execute(LocalToolNames.readTextFile, {
      'path': file.path,
    }, cwd: dir.path);
    final body = jsonDecode(raw) as Map<String, dynamic>;

    expect(body['ok'], true);
    expect(body['content'], 'hello ph01');
  });

  test('搜索本地文本', () async {
    final dir = await Directory.systemTemp.createTemp('hanako_local_tools_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(
      '${dir.path}${Platform.pathSeparator}a.dart',
    ).writeAsStringSync('const marker = "ph01";\n');

    final raw = await LocalToolRegistry.execute(LocalToolNames.searchText, {
      'root': dir.path,
      'query': 'marker',
    }, cwd: dir.path);
    final body = jsonDecode(raw) as Map<String, dynamic>;
    final results = body['results'] as List;

    expect(body['ok'], true);
    expect(results, hasLength(1));
    expect(results.single['line'], 1);
  });
}
