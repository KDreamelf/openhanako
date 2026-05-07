import 'dart:convert';
import 'dart:io';

class ActivityStore {
  ActivityStore({required File file, int maxEntries = 100})
    : _file = file,
      _maxEntries = maxEntries {
    _load();
  }

  final File _file;
  final int _maxEntries;
  final List<ActivityRecord> _entries = <ActivityRecord>[];

  List<ActivityRecord> list({int? limit}) {
    _load();
    if (limit == null || _entries.length <= limit) {
      return List<ActivityRecord>.unmodifiable(_entries);
    }
    return List<ActivityRecord>.unmodifiable(_entries.take(limit));
  }

  ActivityRecord? get(String id) {
    _load();
    for (final entry in _entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  ActivityRecord add(ActivityRecord entry) {
    _load();
    _entries.insert(0, entry);
    while (_entries.length > _maxEntries) {
      _entries.removeLast();
    }
    _save();
    return entry;
  }

  void _load() {
    _entries.clear();
    if (!_file.existsSync()) return;
    try {
      final raw = jsonDecode(_file.readAsStringSync());
      if (raw is! List) return;
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          final record = ActivityRecord.fromJson(item);
          if (record != null) _entries.add(record);
        } else if (item is Map) {
          final record = ActivityRecord.fromJson(item.cast<String, dynamic>());
          if (record != null) _entries.add(record);
        }
      }
    } catch (_) {
      _entries.clear();
    }
  }

  void _save() {
    _file.parent.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(_entries.map((entry) => entry.toJson()).toList()),
      flush: true,
    );
    if (_file.existsSync()) _file.deleteSync();
    tmp.renameSync(_file.path);
  }
}

class ActivityRecord {
  const ActivityRecord({
    required this.id,
    required this.type,
    required this.agentId,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    this.label,
    this.targetPath,
    this.summary,
    this.error,
    this.sessionPath,
  });

  final String id;
  final String type;
  final String agentId;
  final String status;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String? label;
  final String? targetPath;
  final String? summary;
  final String? error;
  final String? sessionPath;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'agentId': agentId,
    'status': status,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    if (label != null && label!.isNotEmpty) 'label': label,
    if (targetPath != null && targetPath!.isNotEmpty) 'targetPath': targetPath,
    if (summary != null && summary!.isNotEmpty) 'summary': summary,
    if (error != null && error!.isNotEmpty) 'error': error,
    if (sessionPath != null && sessionPath!.isNotEmpty)
      'sessionPath': sessionPath,
  };

  static ActivityRecord? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final type = json['type']?.toString() ?? '';
    final agentId = json['agentId']?.toString() ?? '';
    final status = json['status']?.toString() ?? '';
    final startedAt = DateTime.tryParse(json['startedAt']?.toString() ?? '');
    final finishedAt = DateTime.tryParse(json['finishedAt']?.toString() ?? '');
    if (id.isEmpty ||
        type.isEmpty ||
        agentId.isEmpty ||
        status.isEmpty ||
        startedAt == null ||
        finishedAt == null) {
      return null;
    }
    return ActivityRecord(
      id: id,
      type: type,
      agentId: agentId,
      status: status,
      startedAt: startedAt.toUtc(),
      finishedAt: finishedAt.toUtc(),
      label: json['label']?.toString(),
      targetPath: json['targetPath']?.toString(),
      summary: json['summary']?.toString(),
      error: json['error']?.toString(),
      sessionPath: json['sessionPath']?.toString(),
    );
  }
}
