import 'dart:async';

import 'cron_store.dart';

typedef CronJobExecutor =
    Future<IsolatedCronSessionResult> Function(CronJob job);

class CronScheduler {
  CronScheduler({
    required CronStore cronStore,
    required CronJobExecutor executeJob,
    Duration checkInterval = const Duration(minutes: 1),
    Duration executionTimeout = const Duration(minutes: 5),
  }) : _cronStore = cronStore,
       _executeJob = executeJob,
       _checkInterval = checkInterval,
       _executionTimeout = executionTimeout;

  final CronStore _cronStore;
  final CronJobExecutor _executeJob;
  final Duration _checkInterval;
  final Duration _executionTimeout;

  Timer? _timer;
  bool _checking = false;
  Future<void>? _checkFuture;

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_checkInterval, (_) {
      unawaited(checkJobs());
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _checkFuture?.catchError((_) {});
    _checkFuture = null;
  }

  Future<void> checkJobs({DateTime? now}) async {
    if (_checking) return;
    _checking = true;
    final future = _doCheck(now: now);
    _checkFuture = future;
    try {
      await future;
    } finally {
      _checking = false;
    }
  }

  Future<CronRunRecord> runNow(String jobId) async {
    final job = _cronStore.getJob(jobId);
    if (job == null) {
      throw StateError('Cron job not found: $jobId');
    }
    return _executeAndRecord(job, markRun: false);
  }

  Future<void> _doCheck({DateTime? now}) async {
    final base = (now ?? DateTime.now()).toUtc();
    for (final due in _cronStore.dueJobs(base)) {
      final current = _cronStore.getJob(due.id);
      if (current == null || !current.isDue(base)) continue;
      await _executeAndRecord(current, markRun: true);
    }
  }

  Future<CronRunRecord> _executeAndRecord(
    CronJob job, {
    required bool markRun,
  }) async {
    final startedAt = DateTime.now().toUtc();
    CronRunRecord record;
    try {
      final result = await _executeJob(job).timeout(_executionTimeout);
      final finishedAt = DateTime.now().toUtc();
      record = CronRunRecord(
        jobId: job.id,
        status: 'success',
        startedAt: startedAt,
        finishedAt: finishedAt,
        sessionPath: result.sessionPath,
      );
      _cronStore.logRun(job.id, record);
      if (markRun) _cronStore.markRun(job.id, now: finishedAt);
    } on CronSkipException catch (e) {
      final finishedAt = DateTime.now().toUtc();
      record = CronRunRecord(
        jobId: job.id,
        status: 'skipped',
        startedAt: startedAt,
        finishedAt: finishedAt,
        error: e.message,
      );
      _cronStore.logRun(job.id, record);
    } catch (e) {
      final finishedAt = DateTime.now().toUtc();
      record = CronRunRecord(
        jobId: job.id,
        status: 'error',
        startedAt: startedAt,
        finishedAt: finishedAt,
        error: e.toString(),
      );
      _cronStore.logRun(job.id, record);
      if (markRun) _cronStore.markRun(job.id, now: finishedAt);
    }
    return record;
  }
}

class IsolatedCronSessionResult {
  const IsolatedCronSessionResult({required this.sessionPath});

  final String sessionPath;
}

class CronSkipException implements Exception {
  const CronSkipException(this.message);

  final String message;

  @override
  String toString() => message;
}
