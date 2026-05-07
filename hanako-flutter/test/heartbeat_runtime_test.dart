import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/activity_store.dart';
import 'package:hanako/core/cron_scheduler.dart';
import 'package:hanako/core/heartbeat_runtime.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Directory workspace;
  late ActivityStore activities;
  late HeartbeatRuntime heartbeat;
  late List<({String agentId, String prompt, String cwd})> executions;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hanako_heartbeat_');
    workspace = Directory(p.join(tmp.path, 'workspace'))..createSync();
    activities = ActivityStore(file: File(p.join(tmp.path, 'activities.json')));
    executions = <({String agentId, String prompt, String cwd})>[];
    heartbeat = HeartbeatRuntime(
      configFile: File(p.join(tmp.path, 'heartbeat-config.json')),
      registryFile: File(p.join(tmp.path, 'jian-registry.json')),
      activityStore: activities,
      resolveAgentId: () => 'agent_01',
      executeJian: ({required agentId, required prompt, required cwd}) async {
        executions.add((agentId: agentId, prompt: prompt, cwd: cwd));
        return IsolatedCronSessionResult(
          sessionPath: p.join(
            tmp.path,
            'sessions',
            '${executions.length}.jsonl',
          ),
        );
      },
    );
    heartbeat.writeConfig(
      HeartbeatConfig(
        enabled: true,
        workspaceRoots: [workspace.path],
        staleAfterMinutes: 60,
      ),
    );
  });

  tearDown(() async {
    await heartbeat.stop();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('发现 jian.md 并更新注册表', () async {
    File(p.join(workspace.path, 'jian.md')).writeAsStringSync('请整理根目录');
    File(p.join(workspace.path, 'note.txt')).writeAsStringSync('hello');

    await heartbeat.beat(now: DateTime.utc(2026, 1, 1, 8));

    final registry = JianRegistry(
      File(p.join(tmp.path, 'jian-registry.json')),
    ).read();
    expect(executions, hasLength(1));
    expect(executions.single.cwd, workspace.path);
    expect(registry.keys, contains(p.normalize(workspace.path)));
    expect(activities.list().single.status, 'success');
  });

  test('重复扫描不重复触发', () async {
    File(p.join(workspace.path, 'jian.md')).writeAsStringSync('请整理根目录');

    await heartbeat.beat(now: DateTime.utc(2026, 1, 1, 8));
    await heartbeat.beat(now: DateTime.utc(2026, 1, 1, 8, 10));

    expect(executions, hasLength(1));
    expect(activities.list(), hasLength(1));
  });

  test('禁用巡检后不触发并写入 skipped 活动', () async {
    heartbeat.writeConfig(
      HeartbeatConfig(enabled: false, workspaceRoots: [workspace.path]),
    );
    File(p.join(workspace.path, 'jian.md')).writeAsStringSync('请整理根目录');

    await heartbeat.beat(now: DateTime.utc(2026, 1, 1, 8));

    expect(executions, isEmpty);
    expect(activities.list().single.status, 'skipped');
  });

  test('一级子目录 jian.md 触发隔离 session', () async {
    final child = Directory(p.join(workspace.path, 'project_a'))..createSync();
    File(p.join(child.path, 'jian.md')).writeAsStringSync('检查 project_a');

    await heartbeat.beat(now: DateTime.utc(2026, 1, 1, 8));

    expect(executions, hasLength(1));
    expect(executions.single.agentId, 'agent_01');
    expect(executions.single.cwd, child.path);
    expect(executions.single.prompt, contains('[目录巡检]'));
    expect(activities.list().single.sessionPath, contains('1.jsonl'));
  });

  test('删除 jian.md 记录 skipped，执行失败记录 error', () async {
    final jian = File(p.join(workspace.path, 'jian.md'))
      ..writeAsStringSync('请整理根目录');
    await heartbeat.beat(now: DateTime.utc(2026, 1, 1, 8));
    jian.deleteSync();

    await heartbeat.beat(now: DateTime.utc(2026, 1, 1, 8, 10));

    expect(activities.list().first.status, 'skipped');

    File(p.join(workspace.path, 'jian.md')).writeAsStringSync('重新出现');
    final failing = HeartbeatRuntime(
      configFile: File(p.join(tmp.path, 'heartbeat-config.json')),
      registryFile: File(p.join(tmp.path, 'jian-registry.json')),
      activityStore: activities,
      resolveAgentId: () => 'agent_01',
      executeJian: ({required agentId, required prompt, required cwd}) async {
        throw StateError('boom');
      },
    );
    await failing.beat(now: DateTime.utc(2026, 1, 1, 8, 20));

    expect(activities.list().first.status, 'error');
    expect(activities.list().first.error, contains('boom'));
  });
}
