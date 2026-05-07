import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/activity_store.dart';
import 'package:hanako/core/agent_manager.dart';
import 'package:hanako/core/agent_runtime.dart';
import 'package:hanako/core/channel_manager.dart';
import 'package:hanako/core/collaboration_manager.dart';
import 'package:hanako/core/cron_scheduler.dart';
import 'package:hanako/core/preferences_manager.dart';
import 'package:hanako/core/runtime_session_store.dart';
import 'package:hanako/local_tools/local_tools.dart';
import 'package:hanako/shared/hana_home.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late HanaHome home;
  late AgentManager agents;
  late ActivityStore activityStore;
  late CollaborationManager collaboration;
  var sessionCounter = 0;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hanako_collaboration_');
    home = HanaHome.debugFromDirectory(tmp);
    final prefs = PreferencesManager(home);
    agents = AgentManager(home, prefs);
    await agents.createAgent(id: 'agent_01', name: '来源');
    await agents.createAgent(id: 'agent_02', name: '目标');
    await agents.switchAgent('agent_01');
    activityStore = ActivityStore(file: home.activityFile);
    collaboration = CollaborationManager(
      preferences: prefs,
      agentManager: agents,
      channelManager: ChannelManager(home),
      activityStore: activityStore,
      executeAgentTask:
          ({
            required agentId,
            required prompt,
            modelId,
            required source,
          }) async {
            sessionCounter++;
            final sessionId = 'collab_$sessionCounter';
            final sessionPath = p.join(
              home.agentSessions(agentId).path,
              '$sessionId.jsonl',
            );
            RuntimeSessionStore.createSessionFile(
              sessionPath,
              sessionId: sessionId,
              cwd: home.agentDesk(agentId).path,
            );
            RuntimeSessionStore.appendMessages(
              sessionPath,
              [
                RuntimeMessage.userText(prompt),
                RuntimeMessage.assistant(
                  blocks: [const RuntimeTextBlock('目标完成')],
                  stopReason: 'stop',
                ),
              ],
              sessionId: sessionId,
              cwd: home.agentDesk(agentId).path,
            );
            return IsolatedCronSessionResult(sessionPath: sessionPath);
          },
    );
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('delegate 工具触发目标 Agent 并记录活动', () async {
    final raw = await LocalToolRegistry.execute(
      LocalToolNames.delegate,
      {'agent': 'agent_02', 'task': '请整理结论'},
      activeAgentId: 'agent_01',
      collaborationManager: collaboration,
    );
    final body = jsonDecode(raw) as Map<String, dynamic>;

    expect(body['ok'], true);
    expect(body['agentId'], 'agent_02');
    expect(body['summary'], '目标完成');
    expect(File(body['sessionPath'] as String).existsSync(), true);

    final activity = activityStore.list().single;
    expect(activity.type, 'delegate');
    expect(activity.agentId, 'agent_02');
    expect(activity.status, 'success');
  });

  test('DM 自动回复开关可配置', () async {
    final raw = await LocalToolRegistry.execute(
      LocalToolNames.dm,
      {'action': 'configure', 'auto_reply': true},
      activeAgentId: 'agent_01',
      collaborationManager: collaboration,
    );
    final body = jsonDecode(raw) as Map<String, dynamic>;

    expect(body['ok'], true);
    expect((body['settings'] as Map)['dmAutoReply'], true);
    expect(collaboration.readSettings().dmAutoReply, true);
  });

  test('Channel triage 触发目标 Agent 并写回频道', () async {
    await collaboration.channel({
      'action': 'configure',
      'auto_triage': true,
    }, sourceAgentId: 'agent_01');
    await collaboration.channel({
      'action': 'create',
      'channel': 'team',
      'members': ['agent_02'],
    }, sourceAgentId: 'agent_01');

    final result = await collaboration.channel({
      'action': 'post',
      'channel': 'team',
      'content': '@agent_02 看一下这个问题',
      'sender': 'user',
    }, sourceAgentId: 'agent_01');

    expect(result['ok'], true);
    expect(result['triage'], 'triggered');
    final messages = await ChannelManager(home).readRecent('team', limit: 10);
    expect(messages.last.sender, 'agent:agent_02');
    expect(messages.last.body, '目标完成');
    expect(activityStore.list().single.type, 'channel_triage');
  });

  test('Channel triage 阻止 Agent 自我循环', () async {
    await collaboration.channel({
      'action': 'configure',
      'auto_triage': true,
    }, sourceAgentId: 'agent_01');
    await collaboration.channel({
      'action': 'create',
      'channel': 'loop',
      'members': ['agent_02'],
    }, sourceAgentId: 'agent_01');
    await ChannelManager(home).appendMessage('loop', 'agent:agent_02', '上一轮回复');

    final result = await collaboration.channel({
      'action': 'triage',
      'channel': 'loop',
      'agent': 'agent_02',
    }, sourceAgentId: 'agent_01');

    expect(result['ok'], false);
    expect(result['error'], 'loop_guard');
    final activity = activityStore.list().single;
    expect(activity.status, 'skipped');
    expect(activity.error, 'loop_guard');
  });
}
