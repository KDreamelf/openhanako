import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class CronStore {
  CronStore({required File jobsFile, required Directory runsDir})
    : _jobsFile = jobsFile,
      _runsDir = runsDir {
    _load();
  }

  final File _jobsFile;
  final Directory _runsDir;

  final List<CronJob> _jobs = <CronJob>[];
  int _nextNum = 1;

  List<CronJob> listJobs() {
    _load();
    return List<CronJob>.unmodifiable(_jobs);
  }

  CronJob? getJob(String id) {
    _load();
    for (final job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  CronJob addJob({
    required String agentId,
    required String type,
    required Object schedule,
    required String prompt,
    String mode = 'isolated',
    String label = '',
    String model = '',
    DateTime? now,
  }) {
    final cleanAgentId = agentId.trim();
    final cleanPrompt = prompt.trim();
    if (cleanAgentId.isEmpty) throw ArgumentError('agentId is required');
    if (cleanPrompt.isEmpty) throw ArgumentError('prompt is required');
    final cleanType = _parseType(type);
    final cleanSchedule = _normalizeSchedule(cleanType, schedule);
    final base = (now ?? DateTime.now()).toUtc();
    final id = 'job_${_nextNum++}';
    final job = CronJob(
      id: id,
      agentId: cleanAgentId,
      type: cleanType,
      schedule: cleanSchedule,
      prompt: cleanPrompt,
      mode: mode.trim().isEmpty ? 'isolated' : mode.trim(),
      label: label.trim().isEmpty
          ? _labelFromPrompt(cleanPrompt)
          : label.trim(),
      model: model.trim(),
      enabled: true,
      createdAt: base,
      updatedAt: base,
      lastRunAt: null,
      nextRunAt: calcNextRun(cleanType, cleanSchedule, base),
    );
    _jobs.add(job);
    _save();
    return job;
  }

  bool removeJob(String id) {
    _load();
    final before = _jobs.length;
    _jobs.removeWhere((job) => job.id == id);
    if (_jobs.length == before) return false;
    _save();
    return true;
  }

  CronJob? toggleJob(String id, {bool? enabled, DateTime? now}) {
    _load();
    final index = _jobs.indexWhere((job) => job.id == id);
    if (index == -1) return null;
    final current = _jobs[index];
    final nextEnabled = enabled ?? !current.enabled;
    final updatedAt = (now ?? DateTime.now()).toUtc();
    final updated = current.copyWith(
      enabled: nextEnabled,
      updatedAt: updatedAt,
      nextRunAt: nextEnabled
          ? calcNextRun(current.type, current.schedule, updatedAt)
          : current.nextRunAt,
    );
    _jobs[index] = updated;
    _save();
    return updated;
  }

  CronJob? markRun(String id, {DateTime? now}) {
    _load();
    final index = _jobs.indexWhere((job) => job.id == id);
    if (index == -1) return null;
    final current = _jobs[index];
    final base = (now ?? DateTime.now()).toUtc();
    final updated = CronJob(
      id: current.id,
      agentId: current.agentId,
      type: current.type,
      schedule: current.schedule,
      prompt: current.prompt,
      mode: current.mode,
      label: current.label,
      model: current.model,
      enabled: current.type == 'at' ? false : current.enabled,
      createdAt: current.createdAt,
      updatedAt: base,
      lastRunAt: base,
      nextRunAt: current.type == 'at'
          ? null
          : calcNextRun(current.type, current.schedule, base),
    );
    _jobs[index] = updated;
    _save();
    return updated;
  }

  List<CronJob> dueJobs(DateTime now) {
    final base = now.toUtc();
    return listJobs()
        .where((job) => job.enabled && job.nextRunAt != null)
        .where((job) => !base.isBefore(job.nextRunAt!))
        .toList(growable: false);
  }

  void logRun(String jobId, CronRunRecord run) {
    final file = File(p.join(_runsDir.path, '$jobId.jsonl'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${jsonEncode(run.copyWith(jobId: jobId).toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  List<CronRunRecord> getRunHistory(String jobId, {int limit = 20}) {
    final file = File(p.join(_runsDir.path, '$jobId.jsonl'));
    if (!file.existsSync()) return const <CronRunRecord>[];
    final lines = file
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
    return lines
        .skip(lines.length > limit ? lines.length - limit : 0)
        .map(_decodeRun)
        .whereType<CronRunRecord>()
        .toList(growable: false);
  }

  int get size => listJobs().length;

  int get enabledCount => listJobs().where((job) => job.enabled).length;

  DateTime? calcNextRun(String type, Object schedule, DateTime from) {
    final cleanType = _parseType(type);
    final cleanSchedule = _normalizeSchedule(cleanType, schedule);
    final base = from.toUtc();
    switch (cleanType) {
      case 'at':
        final target = DateTime.tryParse(cleanSchedule.toString())?.toUtc();
        if (target == null || !target.isAfter(base)) return null;
        return target;
      case 'every':
        final ms = cleanSchedule is num
            ? cleanSchedule.toInt()
            : int.tryParse(cleanSchedule.toString());
        if (ms == null || ms <= 0) return null;
        return base.add(Duration(milliseconds: ms));
      case 'cron':
        return _parseSimpleCron(cleanSchedule.toString(), base);
    }
    return null;
  }

  void _load() {
    _jobs.clear();
    if (!_jobsFile.existsSync()) {
      _nextNum = 1;
      return;
    }
    try {
      final raw = jsonDecode(_jobsFile.readAsStringSync());
      if (raw is! Map) {
        _nextNum = 1;
        return;
      }
      final jobs = raw['jobs'];
      if (jobs is List) {
        for (final item in jobs) {
          if (item is Map) {
            final job = CronJob.fromJson(item.cast<String, dynamic>());
            if (job != null) _jobs.add(job);
          }
        }
      }
      final next = raw['nextNum'];
      _nextNum = next is num ? next.toInt() : _inferNextNum();
    } catch (_) {
      _jobs.clear();
      _nextNum = 1;
    }
  }

  int _inferNextNum() {
    var maxSeen = 0;
    for (final job in _jobs) {
      final match = RegExp(r'^job_(\d+)$').firstMatch(job.id);
      if (match == null) continue;
      final value = int.tryParse(match.group(1)!);
      if (value != null && value > maxSeen) maxSeen = value;
    }
    return maxSeen + 1;
  }

  void _save() {
    _jobsFile.parent.createSync(recursive: true);
    final tmp = File('${_jobsFile.path}.tmp');
    tmp.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'jobs': _jobs.map((job) => job.toJson()).toList(growable: false), 'nextNum': _nextNum})}\n',
      flush: true,
    );
    if (_jobsFile.existsSync()) {
      _jobsFile.deleteSync();
    }
    tmp.renameSync(_jobsFile.path);
  }

  static String _parseType(String type) {
    final clean = type.trim();
    if (clean == 'at' || clean == 'every' || clean == 'cron') return clean;
    throw ArgumentError('unsupported cron type: $type');
  }

  static Object _normalizeSchedule(String type, Object schedule) {
    if (type == 'every') {
      final ms = schedule is num
          ? schedule.toInt()
          : int.tryParse(schedule.toString().trim());
      if (ms == null || ms <= 0) {
        throw ArgumentError(
          'every schedule must be a positive millisecond value',
        );
      }
      return ms;
    }
    final clean = schedule.toString().trim();
    if (clean.isEmpty) throw ArgumentError('schedule is required');
    return clean;
  }

  static String _labelFromPrompt(String prompt) =>
      prompt.length <= 30 ? prompt : prompt.substring(0, 30);

  static DateTime? _parseSimpleCron(String expr, DateTime from) {
    final parts = expr.trim().split(RegExp(r'\s+'));
    if (parts.length < 5) return null;
    final minute = parts[0];
    final hour = parts[1];
    if (minute == '*' || hour == '*') {
      return from.add(const Duration(hours: 1));
    }
    final m = int.tryParse(minute);
    final h = int.tryParse(hour);
    if (m == null || h == null || m < 0 || m > 59 || h < 0 || h > 23) {
      return null;
    }
    var target = DateTime.utc(from.year, from.month, from.day, h, m);
    if (!target.isAfter(from)) {
      target = target.add(const Duration(days: 1));
    }
    return target;
  }

  static CronRunRecord? _decodeRun(String line) {
    try {
      final raw = jsonDecode(line);
      if (raw is Map<String, dynamic>) return CronRunRecord.fromJson(raw);
      if (raw is Map) {
        return CronRunRecord.fromJson(raw.cast<String, dynamic>());
      }
    } catch (_) {}
    return null;
  }
}

class CronJob {
  const CronJob({
    required this.id,
    required this.agentId,
    required this.type,
    required this.schedule,
    required this.prompt,
    required this.mode,
    required this.label,
    required this.model,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
    required this.lastRunAt,
    required this.nextRunAt,
  });

  final String id;
  final String agentId;
  final String type;
  final Object schedule;
  final String prompt;
  final String mode;
  final String label;
  final String model;
  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastRunAt;
  final DateTime? nextRunAt;

  bool isDue(DateTime now) =>
      enabled && nextRunAt != null && !now.toUtc().isBefore(nextRunAt!);

  CronJob copyWith({
    String? id,
    String? agentId,
    String? type,
    Object? schedule,
    String? prompt,
    String? mode,
    String? label,
    String? model,
    bool? enabled,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastRunAt,
    DateTime? nextRunAt,
  }) {
    return CronJob(
      id: id ?? this.id,
      agentId: agentId ?? this.agentId,
      type: type ?? this.type,
      schedule: schedule ?? this.schedule,
      prompt: prompt ?? this.prompt,
      mode: mode ?? this.mode,
      label: label ?? this.label,
      model: model ?? this.model,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      nextRunAt: nextRunAt ?? this.nextRunAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'agent': agentId,
    'agentId': agentId,
    'type': type,
    'schedule': schedule,
    'prompt': prompt,
    'mode': mode,
    'label': label,
    'model': model,
    'enabled': enabled,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'lastRunAt': lastRunAt?.toIso8601String(),
    'nextRunAt': nextRunAt?.toIso8601String(),
  };

  static CronJob? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim();
    final agentId = (json['agentId'] ?? json['agent'])?.toString().trim();
    final type = json['type']?.toString().trim();
    final schedule = json['schedule'];
    final prompt = json['prompt']?.toString();
    final createdAt = _parseDate(json['createdAt']) ?? DateTime.now().toUtc();
    if (id == null ||
        id.isEmpty ||
        agentId == null ||
        agentId.isEmpty ||
        type == null ||
        type.isEmpty ||
        schedule == null ||
        prompt == null ||
        prompt.trim().isEmpty) {
      return null;
    }
    return CronJob(
      id: id,
      agentId: agentId,
      type: type,
      schedule: schedule,
      prompt: prompt,
      mode: json['mode']?.toString().trim().isNotEmpty == true
          ? json['mode'].toString().trim()
          : 'isolated',
      label: json['label']?.toString().trim().isNotEmpty == true
          ? json['label'].toString().trim()
          : CronStore._labelFromPrompt(prompt),
      model: json['model']?.toString().trim() ?? '',
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      createdAt: createdAt,
      updatedAt: _parseDate(json['updatedAt']) ?? createdAt,
      lastRunAt: _parseDate(json['lastRunAt']),
      nextRunAt: _parseDate(json['nextRunAt']),
    );
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw == null) return null;
    return DateTime.tryParse(raw.toString())?.toUtc();
  }
}

class CronRunRecord {
  const CronRunRecord({
    required this.jobId,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    this.error,
    this.sessionPath,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? finishedAt;

  final String jobId;
  final String status;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String? error;
  final String? sessionPath;
  final DateTime timestamp;

  CronRunRecord copyWith({
    String? jobId,
    String? status,
    DateTime? startedAt,
    DateTime? finishedAt,
    String? error,
    String? sessionPath,
    DateTime? timestamp,
  }) {
    return CronRunRecord(
      jobId: jobId ?? this.jobId,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      error: error ?? this.error,
      sessionPath: sessionPath ?? this.sessionPath,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  Map<String, dynamic> toJson() => {
    'jobId': jobId,
    'status': status,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    if (error != null && error!.isNotEmpty) 'error': error,
    if (sessionPath != null && sessionPath!.isNotEmpty)
      'sessionPath': sessionPath,
    'timestamp': timestamp.toIso8601String(),
  };

  static CronRunRecord? fromJson(Map<String, dynamic> json) {
    final jobId = json['jobId']?.toString() ?? '';
    final status = json['status']?.toString() ?? '';
    final startedAt = DateTime.tryParse(json['startedAt']?.toString() ?? '');
    final finishedAt = DateTime.tryParse(json['finishedAt']?.toString() ?? '');
    if (jobId.isEmpty ||
        status.isEmpty ||
        startedAt == null ||
        finishedAt == null) {
      return null;
    }
    return CronRunRecord(
      jobId: jobId,
      status: status,
      startedAt: startedAt.toUtc(),
      finishedAt: finishedAt.toUtc(),
      error: json['error']?.toString(),
      sessionPath: json['sessionPath']?.toString(),
      timestamp:
          DateTime.tryParse(json['timestamp']?.toString() ?? '')?.toUtc() ??
          finishedAt.toUtc(),
    );
  }
}
