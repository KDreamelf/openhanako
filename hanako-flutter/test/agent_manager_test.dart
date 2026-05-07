import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/agent_manager.dart';
import 'package:hanako/core/preferences_manager.dart';
import 'package:hanako/shared/hana_home.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late HanaHome home;
  late AgentManager manager;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hanako_agent_manager_');
    home = HanaHome.debugFromDirectory(tmp);
    manager = AgentManager(home, PreferencesManager(home));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('新建 Agent 后目录结构完整', () async {
    final agent = await manager.createAgent(
      id: 'agent_01',
      name: '测试 Agent',
      yuan: 'ming',
    );

    expect(agent.id, 'agent_01');
    expect(home.agentConfig(agent.id).existsSync(), true);
    expect(
      File(p.join(home.agentDir(agent.id).path, 'identity.md')).existsSync(),
      true,
    );
    expect(
      File(p.join(home.agentDir(agent.id).path, 'ishiki.md')).existsSync(),
      true,
    );
    expect(
      Directory(p.join(home.agentDir(agent.id).path, 'sessions')).existsSync(),
      true,
    );
    expect(
      Directory(p.join(home.agentDir(agent.id).path, 'memory')).existsSync(),
      true,
    );
    expect(
      Directory(
        p.join(home.agentDir(agent.id).path, 'learned-skills'),
      ).existsSync(),
      true,
    );
    expect(
      Directory(p.join(home.agentDir(agent.id).path, 'avatars')).existsSync(),
      true,
    );
    expect(
      Directory(p.join(home.agentDir(agent.id).path, 'desk')).existsSync(),
      true,
    );
  });

  test('修改 Agent 档案后持久化到 config 与 md 文件', () async {
    await manager.createAgent(id: 'agent_01', name: '旧名');
    final avatarSource = File(p.join(tmp.path, 'avatar-source.png'))
      ..writeAsBytesSync(<int>[137, 80, 78, 71, 13, 10, 26, 10]);

    final updated = await manager.updateAgent(
      'agent_01',
      name: '新名',
      yuan: 'butter',
      identity: '# 新身份\n',
      ishiki: '# 新人格\n',
      avatarSourcePath: avatarSource.path,
    );
    final listed = await manager.listAgents(forceRefresh: true);

    expect(updated.name, '新名');
    expect(updated.yuan, 'butter');
    expect(updated.avatarPath, isNotNull);
    expect(File(updated.avatarPath!).existsSync(), true);
    expect(listed.single.name, '新名');
    expect(listed.single.identity, '# 新身份\n');
    expect(listed.single.ishiki, '# 新人格\n');
    expect(listed.single.avatarPath, updated.avatarPath);

    final removed = await manager.updateAgent('agent_01', removeAvatar: true);
    expect(removed.avatarPath, isNull);
  });

  test('切换 Agent 不串会话与记忆目录', () async {
    final a = await manager.createAgent(id: 'agent_a', name: 'A');
    final b = await manager.createAgent(id: 'agent_b', name: 'B');

    await manager.switchAgent(a.id);
    final aSession = File(p.join(home.agentSessions(a.id).path, 'a.jsonl'))
      ..writeAsStringSync('a');
    final aMemory = File(p.join(home.agentMemory(a.id).path, 'memory.md'))
      ..writeAsStringSync('memory a');

    await manager.switchAgent(b.id);
    final bSession = File(p.join(home.agentSessions(b.id).path, 'b.jsonl'))
      ..writeAsStringSync('b');
    final bMemory = File(p.join(home.agentMemory(b.id).path, 'memory.md'))
      ..writeAsStringSync('memory b');

    expect(manager.activeAgentId, b.id);
    expect(aSession.readAsStringSync(), 'a');
    expect(bSession.readAsStringSync(), 'b');
    expect(aMemory.readAsStringSync(), 'memory a');
    expect(bMemory.readAsStringSync(), 'memory b');
  });
}
