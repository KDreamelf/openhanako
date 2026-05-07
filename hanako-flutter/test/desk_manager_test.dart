import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/desk_manager.dart';
import 'package:hanako/shared/hana_home.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late HanaHome home;
  late DeskManager manager;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hanako_desk_');
    home = HanaHome.debugFromDirectory(tmp);
    manager = DeskManager(home);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('列出并预览 desk 中的文本、Markdown、图片和二进制文件', () async {
    final desk = home.agentDesk('agent_01');
    File(p.join(desk.path, 'note.md')).writeAsStringSync('# 标题\n\n内容');
    Directory(p.join(desk.path, 'reports')).createSync(recursive: true);
    File(
      p.join(desk.path, 'reports', 'log.txt'),
    ).writeAsStringSync('plain text');
    File(
      p.join(desk.path, 'image.png'),
    ).writeAsBytesSync(<int>[137, 80, 78, 71, 13, 10, 26, 10]);
    File(p.join(desk.path, 'archive.bin')).writeAsBytesSync(<int>[0, 1, 2, 3]);

    final files = manager.listFiles('agent_01');
    expect(files.map((entry) => entry.relativePath), contains('note.md'));
    expect(
      files.map((entry) => entry.relativePath),
      contains(p.join('reports', 'log.txt')),
    );

    final markdown = await manager.preview('agent_01', 'note.md');
    expect(markdown.kind, DeskFileKind.markdown);
    expect(markdown.text, contains('内容'));

    final text = await manager.preview(
      'agent_01',
      p.join('reports', 'log.txt'),
    );
    expect(text.kind, DeskFileKind.text);
    expect(text.text, 'plain text');

    final image = await manager.preview('agent_01', 'image.png');
    expect(image.kind, DeskFileKind.image);
    expect(image.text, isNull);

    final binary = await manager.preview('agent_01', 'archive.bin');
    expect(binary.kind, DeskFileKind.binary);
    expect(binary.text, isNull);
  });

  test('resolveDeskFile 阻止路径逃逸', () {
    final outside = File(p.join(tmp.path, 'outside.txt'))
      ..writeAsStringSync('outside');
    expect(
      () => manager.resolveDeskFile('agent_01', p.join('..', '..', 'x.txt')),
      throwsArgumentError,
    );
    expect(
      () => manager.resolveDeskFile('agent_01', outside.path),
      throwsArgumentError,
    );
  });
}
