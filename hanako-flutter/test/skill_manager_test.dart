import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/agent_manager.dart';
import 'package:hanako/core/preferences_manager.dart';
import 'package:hanako/core/skill_manager.dart';
import 'package:hanako/local_tools/local_tools.dart';
import 'package:hanako/shared/hana_home.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late HanaHome home;
  late SkillManager skills;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hanako_skills_');
    home = HanaHome.debugFromDirectory(tmp);
    await AgentManager(
      home,
      PreferencesManager(home),
    ).createAgent(id: 'agent_01', name: '测试 Agent');
    skills = SkillManager(home);
    await skills.initialize();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('安装、启用、禁用和删除 learned skill', () async {
    final skill = await skills.installFromContent(
      'agent_01',
      skillContent: _validSkill('memo-skill'),
      enable: true,
    );

    expect(skill.name, 'memo-skill');
    expect(skills.allSkills.map((item) => item.name), contains('memo-skill'));
    expect(skills.enabledSkillNames('agent_01'), ['memo-skill']);
    expect(
      skills.getSkillsForAgent('agent_01', ['memo-skill']).skills.single.name,
      'memo-skill',
    );

    await skills.setSkillEnabled('agent_01', 'memo-skill', false);
    expect(skills.enabledSkillNames('agent_01'), isEmpty);
    expect(
      skills.getSkillsForAgent('agent_01', ['memo-skill']).skills.single.name,
      'memo-skill',
    );

    await skills.deleteLearnedSkill('agent_01', 'memo-skill');
    expect(
      skills.allSkills.map((item) => item.name),
      isNot(contains('memo-skill')),
    );
  });

  test('无效 Skill 不会污染列表', () async {
    expect(
      () => skills.installFromContent(
        'agent_01',
        skillContent: '---\nname: bad-skill\n---\nbody',
      ),
      throwsA(isA<StateError>()),
    );
    expect(skills.allSkills, isEmpty);
  });

  test('install_skill 工具与 SkillManager 状态一致', () async {
    final raw = await LocalToolRegistry.execute(
      LocalToolNames.installSkill,
      {'skill_content': _validSkill('tool-skill'), 'enabled': true},
      activeAgentId: 'agent_01',
      skillManager: skills,
    );
    final body = jsonDecode(raw) as Map<String, dynamic>;

    expect(body['ok'], true);
    expect(body['skill']['name'], 'tool-skill');
    expect(skills.enabledSkillNames('agent_01'), ['tool-skill']);
  });

  test('可从本地目录安装并保留资源文件', () async {
    final src = Directory(p.join(tmp.path, 'source-skill'))..createSync();
    File(
      p.join(src.path, 'SKILL.md'),
    ).writeAsStringSync(_validSkill('path-skill'));
    Directory(p.join(src.path, 'scripts')).createSync();
    File(p.join(src.path, 'scripts', 'run.txt')).writeAsStringSync('ok');

    final skill = await skills.installFromPath('agent_01', src.path);

    expect(skill.name, 'path-skill');
    expect(
      File(p.join(skill.baseDir, 'scripts', 'run.txt')).readAsStringSync(),
      'ok',
    );
  });
}

String _validSkill(String name) =>
    '''---
name: $name
description: 用于测试 Skill 管理闭环。
allowed-tools: [read, write]
---

请按测试说明行动。
''';
