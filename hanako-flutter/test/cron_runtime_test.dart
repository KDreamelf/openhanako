import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/core/cron_scheduler.dart';
import 'package:hanako/core/cron_store.dart';
import 'package:hanako/local_tools/local_tools.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late CronStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hanako_cron_');
    store = CronStore(
      jobsFile: File(p.join(tmp.path, 'desk', 'cron-jobs.json')),
      runsDir: Directory(p.join(tmp.path, 'desk', 'cron-runs')),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('cron store 持久化任务并恢复 nextNum', () {
    final now = DateTime.utc(2026, 1, 1, 8);
    final first = store.addJob(
      agentId: 'agent_01',
      type: 'every',
      schedule: 60000,
      prompt: '检查日报',
      now: now,
    );

    final reloaded = CronStore(
      jobsFile: File(p.join(tmp.path, 'desk', 'cron-jobs.json')),
      runsDir: Directory(p.join(tmp.path, 'desk', 'cron-runs')),
    );
    final second = reloaded.addJob(
      agentId: 'agent_01',
      type: 'cron',
      schedule: '0 7 * * *',
      prompt: '早报',
      now: now,
    );

    expect(first.id, 'job_1');
    expect(second.id, 'job_2');
    expect(reloaded.listJobs(), hasLength(2));
    expect(
      reloaded.listJobs().first.nextRunAt,
      now.add(const Duration(minutes: 1)),
    );
  });

  test('cron scheduler 命中到期任务并跳过未到期任务', () async {
    final now = DateTime.utc(2026, 1, 1, 8);
    final due = store.addJob(
      agentId: 'agent_01',
      type: 'at',
      schedule: now.toIso8601String(),
      prompt: '到期任务',
      now: now.subtract(const Duration(minutes: 1)),
    );
    store.addJob(
      agentId: 'agent_01',
      type: 'at',
      schedule: now.add(const Duration(hours: 1)).toIso8601String(),
      prompt: '未到期任务',
      now: now,
    );
    final executed = <String>[];
    final scheduler = CronScheduler(
      cronStore: store,
      executeJob: (job) async {
        executed.add(job.id);
        return IsolatedCronSessionResult(
          sessionPath: '/sessions/${job.id}.jsonl',
        );
      },
    );

    await scheduler.checkJobs(now: now);

    expect(executed, [due.id]);
    expect(store.getJob(due.id)?.enabled, false);
    expect(store.getRunHistory(due.id).single.status, 'success');
  });

  test('toggle 和 remove 后不会继续执行', () async {
    final now = DateTime.utc(2026, 1, 1, 8);
    final disabled = store.addJob(
      agentId: 'agent_01',
      type: 'at',
      schedule: now.toIso8601String(),
      prompt: '禁用任务',
      now: now.subtract(const Duration(minutes: 1)),
    );
    final removed = store.addJob(
      agentId: 'agent_01',
      type: 'at',
      schedule: now.toIso8601String(),
      prompt: '删除任务',
      now: now.subtract(const Duration(minutes: 1)),
    );
    store.toggleJob(disabled.id, enabled: false, now: now);
    store.removeJob(removed.id);
    final executed = <String>[];
    final scheduler = CronScheduler(
      cronStore: store,
      executeJob: (job) async {
        executed.add(job.id);
        return IsolatedCronSessionResult(
          sessionPath: '/sessions/${job.id}.jsonl',
        );
      },
    );

    await scheduler.checkJobs(now: now);

    expect(executed, isEmpty);
    expect(store.getRunHistory(disabled.id), isEmpty);
    expect(store.getJob(removed.id), isNull);
  });

  test('run history 记录错误与 session 路径', () async {
    final now = DateTime.utc(2026, 1, 1, 8);
    final success = store.addJob(
      agentId: 'agent_01',
      type: 'at',
      schedule: now.toIso8601String(),
      prompt: '成功任务',
      now: now.subtract(const Duration(minutes: 1)),
    );
    final scheduler = CronScheduler(
      cronStore: store,
      executeJob: (job) async =>
          IsolatedCronSessionResult(sessionPath: '/sessions/${job.id}.jsonl'),
    );

    await scheduler.checkJobs(now: now);

    final run = store.getRunHistory(success.id).single;
    expect(run.status, 'success');
    expect(run.sessionPath, '/sessions/${success.id}.jsonl');
  });

  test('cron 本地工具支持 add/list/toggle/run-now', () async {
    final addedRaw = await LocalToolRegistry.execute(
      LocalToolNames.cron,
      {
        'action': 'add',
        'type': 'every',
        'schedule': '60000',
        'prompt': '检查任务',
        'label': '检查',
      },
      activeAgentId: 'agent_01',
      cronStore: store,
      runCronNow: (_) async => throw StateError('not used'),
    );
    final added = jsonDecode(addedRaw) as Map<String, dynamic>;
    final jobId = (added['job'] as Map<String, dynamic>)['id'] as String;

    final listedRaw = await LocalToolRegistry.execute(
      LocalToolNames.cron,
      {'action': 'list'},
      activeAgentId: 'agent_01',
      cronStore: store,
      runCronNow: (_) async => throw StateError('not used'),
    );
    final listed = jsonDecode(listedRaw) as Map<String, dynamic>;

    final toggledRaw = await LocalToolRegistry.execute(
      LocalToolNames.cron,
      {'action': 'toggle', 'id': jobId, 'enabled': false},
      activeAgentId: 'agent_01',
      cronStore: store,
      runCronNow: (_) async => throw StateError('not used'),
    );
    final toggled = jsonDecode(toggledRaw) as Map<String, dynamic>;

    final runRaw = await LocalToolRegistry.execute(
      LocalToolNames.cron,
      {'action': 'run-now', 'id': jobId},
      activeAgentId: 'agent_01',
      cronStore: store,
      runCronNow: (id) async => CronRunRecord(
        jobId: id,
        status: 'success',
        startedAt: DateTime.utc(2026, 1, 1, 8),
        finishedAt: DateTime.utc(2026, 1, 1, 8, 1),
        sessionPath: '/sessions/$id.jsonl',
      ),
    );
    final run = jsonDecode(runRaw) as Map<String, dynamic>;

    expect(added['ok'], true);
    expect(listed['jobs'], hasLength(1));
    expect((toggled['job'] as Map<String, dynamic>)['enabled'], false);
    expect(run['ok'], true);
    expect(
      (run['run'] as Map<String, dynamic>)['sessionPath'],
      contains(jobId),
    );
  });
}
