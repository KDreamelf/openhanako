import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'activity_store.dart';
import 'cron_scheduler.dart';

typedef HeartbeatExecutor =
    Future<IsolatedCronSessionResult> Function({
      required String agentId,
      required String prompt,
      required String cwd,
    });

class HeartbeatRuntime {
  HeartbeatRuntime({
    required File configFile,
    required File registryFile,
    required ActivityStore activityStore,
    required String Function() resolveAgentId,
    required HeartbeatExecutor executeJian,
    Duration? beatTimeout,
  }) : _configFile = configFile,
       _registryFile = registryFile,
       _activityStore = activityStore,
       _resolveAgentId = resolveAgentId,
       _executeJian = executeJian,
       _beatTimeout = beatTimeout ?? const Duration(minutes: 5);

  final File _configFile;
  final File _registryFile;
  final ActivityStore _activityStore;
  final String Function() _resolveAgentId;
  final HeartbeatExecutor _executeJian;
  final Duration _beatTimeout;

  Timer? _timer;
  bool _running = false;
  Future<void>? _beatFuture;

  bool get isRunning => _timer != null;

  HeartbeatConfig readConfig() => HeartbeatConfigStore(_configFile).read();

  void writeConfig(HeartbeatConfig config) {
    HeartbeatConfigStore(_configFile).write(config);
    if (_timer != null) {
      start();
    }
  }

  void start() {
    _timer?.cancel();
    final config = readConfig();
    if (!config.enabled) {
      _timer = null;
      return;
    }
    final interval = Duration(minutes: config.intervalMinutes);
    _timer = Timer.periodic(interval, (_) {
      unawaited(beat());
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _beatFuture?.catchError((_) {});
    _beatFuture = null;
    _running = false;
  }

  Future<void> beat({DateTime? now}) async {
    if (_running) return;
    _running = true;
    final future = _doBeat(now: now ?? DateTime.now().toUtc());
    _beatFuture = future;
    try {
      await future;
    } finally {
      _running = false;
    }
  }

  HeartbeatScanResult scan({DateTime? now}) {
    final config = readConfig();
    final registry = JianRegistry(_registryFile);
    final entries = registry.read();
    return _scan(
      config: config,
      registry: entries,
      now: now ?? DateTime.now().toUtc(),
    );
  }

  Future<void> _doBeat({required DateTime now}) async {
    final config = readConfig();
    final agentId = (config.agentId?.trim().isNotEmpty == true)
        ? config.agentId!.trim()
        : _resolveAgentId();
    if (!config.enabled) {
      _activityStore.add(
        _activity(
          type: 'heartbeat',
          agentId: agentId,
          status: 'skipped',
          label: '巡检已禁用',
          startedAt: now,
          finishedAt: DateTime.now().toUtc(),
          summary: '巡检已禁用',
        ),
      );
      return;
    }
    if (config.workspaceRoots.isEmpty) {
      _activityStore.add(
        _activity(
          type: 'heartbeat',
          agentId: agentId,
          status: 'skipped',
          label: '未配置工作区',
          startedAt: now,
          finishedAt: DateTime.now().toUtc(),
          summary: '未配置工作区，跳过巡检',
        ),
      );
      return;
    }

    final registry = JianRegistry(_registryFile);
    final currentRegistry = registry.read();
    final scan = _scan(config: config, registry: currentRegistry, now: now);
    final nextRegistry = Map<String, JianRegistryEntry>.from(currentRegistry);

    for (final change in scan.changes) {
      if (change.kind == JianChangeKind.deleted) {
        nextRegistry.remove(change.path);
        _activityStore.add(
          _activity(
            type: 'heartbeat',
            agentId: agentId,
            status: 'skipped',
            label: '笺已删除',
            targetPath: change.path,
            startedAt: now,
            finishedAt: DateTime.now().toUtc(),
            summary: '笺已删除：${change.path}',
          ),
        );
        continue;
      }
      final startedAt = DateTime.now().toUtc();
      try {
        final prompt = _buildJianPrompt(change);
        final result = await _executeJian(
          agentId: agentId,
          prompt: prompt,
          cwd: change.path,
        ).timeout(_beatTimeout);
        final post = _readJianDir(change.path, config);
        if (post != null) {
          nextRegistry[change.path] = JianRegistryEntry(
            jianHash: post.jianHash,
            filesHash: post.filesHash,
            lastCheckedAt: DateTime.now().toUtc(),
          );
        }
        _activityStore.add(
          _activity(
            type: 'heartbeat',
            agentId: agentId,
            status: 'success',
            label: change.kind.label,
            targetPath: change.path,
            startedAt: startedAt,
            finishedAt: DateTime.now().toUtc(),
            sessionPath: result.sessionPath,
            summary: '笺巡检完成：${p.basename(change.path)}',
          ),
        );
      } catch (e) {
        _activityStore.add(
          _activity(
            type: 'heartbeat',
            agentId: agentId,
            status: 'error',
            label: change.kind.label,
            targetPath: change.path,
            startedAt: startedAt,
            finishedAt: DateTime.now().toUtc(),
            error: e.toString(),
            summary: '笺巡检失败：${p.basename(change.path)}',
          ),
        );
      }
    }
    registry.write(nextRegistry);
  }

  HeartbeatScanResult _scan({
    required HeartbeatConfig config,
    required Map<String, JianRegistryEntry> registry,
    required DateTime now,
  }) {
    final found = <String, JianDirectory>{};
    for (final root in config.workspaceRoots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final jian in _scanJianDirs(dir, config)) {
        found[jian.path] = jian;
      }
    }

    final changes = <JianChange>[];
    for (final entry in found.values) {
      final previous = registry[entry.path];
      final kind = previous == null
          ? JianChangeKind.created
          : previous.jianHash != entry.jianHash ||
                previous.filesHash != entry.filesHash
          ? JianChangeKind.modified
          : now.difference(previous.lastCheckedAt).inMinutes >=
                config.staleAfterMinutes
          ? JianChangeKind.stale
          : null;
      if (kind != null) {
        changes.add(JianChange(kind: kind, directory: entry));
      }
    }

    for (final key in registry.keys) {
      final insideConfiguredRoot = config.workspaceRoots.any((root) {
        final normalizedRoot = p.normalize(root);
        final normalizedKey = p.normalize(key);
        return normalizedKey == normalizedRoot ||
            p.isWithin(normalizedRoot, normalizedKey);
      });
      if (insideConfiguredRoot && !found.containsKey(key)) {
        changes.add(JianChange.deleted(path: key));
      }
    }
    return HeartbeatScanResult(found: found.values.toList(), changes: changes);
  }

  List<JianDirectory> _scanJianDirs(Directory root, HeartbeatConfig config) {
    final out = <JianDirectory>[];
    final rootJian = _readJianDir(root.path, config);
    if (rootJian != null) out.add(rootJian);
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.') || config.isExcluded(entity.path)) continue;
      final jian = _readJianDir(entity.path, config);
      if (jian != null) out.add(jian);
    }
    return out;
  }

  JianDirectory? _readJianDir(String dirPath, HeartbeatConfig config) {
    if (config.isExcluded(dirPath)) return null;
    final jianFile = File(p.join(dirPath, 'jian.md'));
    if (!jianFile.existsSync()) return null;
    try {
      final content = jianFile.readAsStringSync();
      final files = _listDirFiles(Directory(dirPath), config);
      final fileFingerprint = files
          .map((file) => '${file.name}:${file.modified.toIso8601String()}')
          .join('|');
      return JianDirectory(
        path: p.normalize(dirPath),
        jianContent: content,
        jianHash: _quickHash(content),
        filesHash: _quickHash(fileFingerprint),
        files: files,
      );
    } catch (_) {
      return null;
    }
  }

  List<JianFileEntry> _listDirFiles(Directory dir, HeartbeatConfig config) {
    final out = <JianFileEntry>[];
    for (final entity in dir.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.') || name == 'jian.md') continue;
      if (config.isExcluded(entity.path)) continue;
      final stat = entity.statSync();
      if (stat.type == FileSystemEntityType.link) continue;
      out.add(
        JianFileEntry(
          name: name,
          isDirectory: stat.type == FileSystemEntityType.directory,
          size: stat.size,
          modified: stat.modified.toUtc(),
        ),
      );
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  ActivityRecord _activity({
    required String type,
    required String agentId,
    required String status,
    required DateTime startedAt,
    required DateTime finishedAt,
    String? label,
    String? targetPath,
    String? summary,
    String? error,
    String? sessionPath,
  }) {
    return ActivityRecord(
      id: '${type}_${DateTime.now().microsecondsSinceEpoch}',
      type: type,
      agentId: agentId,
      status: status,
      startedAt: startedAt,
      finishedAt: finishedAt,
      label: label,
      targetPath: targetPath,
      summary: summary,
      error: error,
      sessionPath: sessionPath,
    );
  }

  String _buildJianPrompt(JianChange change) {
    final dir = change.directory;
    final parts = <String>[
      '[目录巡检] ${dir.path}',
      '',
      '**注意：这是系统自动触发的目录巡检，不是用户发来的消息。**',
      '请根据笺的指令独立判断并处理，不要向用户提问或等待回复。',
      '',
      '## 笺',
      dir.jianContent,
      '',
    ];
    if (dir.files.isNotEmpty) {
      parts.add('## 文件列表');
      for (final file in dir.files) {
        final icon = file.isDirectory ? '目录' : '文件';
        final size = file.isDirectory ? '' : ' (${_formatSize(file.size)})';
        parts.add('- $icon ${file.name}$size');
      }
      parts.add('');
    }
    parts.add('## 变化');
    parts.add('- 类型：${change.kind.label}');
    parts.add('');
    parts.add('请根据笺的指令处理。如果无需行动，不要调用任何工具。');
    return parts.join('\n');
  }
}

class HeartbeatConfigStore {
  const HeartbeatConfigStore(this.file);

  final File file;

  HeartbeatConfig read() {
    if (!file.existsSync()) return const HeartbeatConfig();
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is Map<String, dynamic>) return HeartbeatConfig.fromJson(raw);
      if (raw is Map) {
        return HeartbeatConfig.fromJson(raw.cast<String, dynamic>());
      }
    } catch (_) {}
    return const HeartbeatConfig();
  }

  void write(HeartbeatConfig config) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(config.toJson())}\n',
      flush: true,
    );
  }
}

class HeartbeatConfig {
  const HeartbeatConfig({
    this.enabled = true,
    this.intervalMinutes = 17,
    this.workspaceRoots = const <String>[],
    this.excludePatterns = const <String>[],
    this.staleAfterMinutes = 24 * 60,
    this.agentId,
  });

  final bool enabled;
  final int intervalMinutes;
  final List<String> workspaceRoots;
  final List<String> excludePatterns;
  final int staleAfterMinutes;
  final String? agentId;

  bool isExcluded(String path) {
    final normalized = p.normalize(path).toLowerCase();
    return excludePatterns.any((pattern) {
      final clean = pattern.trim().toLowerCase();
      if (clean.isEmpty) return false;
      return normalized.contains(clean);
    });
  }

  HeartbeatConfig copyWith({
    bool? enabled,
    int? intervalMinutes,
    List<String>? workspaceRoots,
    List<String>? excludePatterns,
    int? staleAfterMinutes,
    String? agentId,
  }) {
    return HeartbeatConfig(
      enabled: enabled ?? this.enabled,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      workspaceRoots: workspaceRoots ?? this.workspaceRoots,
      excludePatterns: excludePatterns ?? this.excludePatterns,
      staleAfterMinutes: staleAfterMinutes ?? this.staleAfterMinutes,
      agentId: agentId ?? this.agentId,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'intervalMinutes': intervalMinutes,
    'workspaceRoots': workspaceRoots,
    'excludePatterns': excludePatterns,
    'staleAfterMinutes': staleAfterMinutes,
    if (agentId != null && agentId!.isNotEmpty) 'agentId': agentId,
  };

  static HeartbeatConfig fromJson(Map<String, dynamic> json) {
    return HeartbeatConfig(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      intervalMinutes: _positiveInt(json['intervalMinutes'], 17),
      workspaceRoots: _stringList(json['workspaceRoots']),
      excludePatterns: _stringList(json['excludePatterns']),
      staleAfterMinutes: _positiveInt(json['staleAfterMinutes'], 24 * 60),
      agentId: json['agentId']?.toString(),
    );
  }

  static int _positiveInt(Object? value, int fallback) {
    final raw = value is num ? value.toInt() : int.tryParse('$value');
    if (raw == null || raw <= 0) return fallback;
    return raw;
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
}

class JianRegistry {
  const JianRegistry(this.file);

  final File file;

  Map<String, JianRegistryEntry> read() {
    if (!file.existsSync()) return <String, JianRegistryEntry>{};
    try {
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return <String, JianRegistryEntry>{};
      final out = <String, JianRegistryEntry>{};
      raw.forEach((key, value) {
        if (value is Map<String, dynamic>) {
          final entry = JianRegistryEntry.fromJson(value);
          if (entry != null) out[p.normalize(key.toString())] = entry;
        } else if (value is Map) {
          final entry = JianRegistryEntry.fromJson(
            value.cast<String, dynamic>(),
          );
          if (entry != null) out[p.normalize(key.toString())] = entry;
        }
      });
      return out;
    } catch (_) {
      return <String, JianRegistryEntry>{};
    }
  }

  void write(Map<String, JianRegistryEntry> entries) {
    file.parent.createSync(recursive: true);
    final raw = entries.map((key, value) => MapEntry(key, value.toJson()));
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(raw)}\n',
      flush: true,
    );
  }
}

class JianRegistryEntry {
  const JianRegistryEntry({
    required this.jianHash,
    required this.filesHash,
    required this.lastCheckedAt,
  });

  final String jianHash;
  final String filesHash;
  final DateTime lastCheckedAt;

  Map<String, dynamic> toJson() => {
    'jianHash': jianHash,
    'filesHash': filesHash,
    'lastCheckedAt': lastCheckedAt.toIso8601String(),
  };

  static JianRegistryEntry? fromJson(Map<String, dynamic> json) {
    final jianHash = json['jianHash']?.toString() ?? '';
    final filesHash = json['filesHash']?.toString() ?? '';
    final lastCheckedAt = DateTime.tryParse(
      json['lastCheckedAt']?.toString() ?? '',
    );
    if (jianHash.isEmpty || filesHash.isEmpty || lastCheckedAt == null) {
      return null;
    }
    return JianRegistryEntry(
      jianHash: jianHash,
      filesHash: filesHash,
      lastCheckedAt: lastCheckedAt.toUtc(),
    );
  }
}

class HeartbeatScanResult {
  const HeartbeatScanResult({required this.found, required this.changes});

  final List<JianDirectory> found;
  final List<JianChange> changes;
}

class JianChange {
  JianChange({required this.kind, required this.directory})
    : path = directory.path;

  const JianChange.deleted({required this.path})
    : kind = JianChangeKind.deleted,
      directory = const JianDirectory(
        path: '',
        jianContent: '',
        jianHash: '',
        filesHash: '',
        files: <JianFileEntry>[],
      );

  final JianChangeKind kind;
  final JianDirectory directory;
  final String path;
}

enum JianChangeKind {
  created('新增'),
  modified('修改'),
  deleted('删除'),
  stale('过期');

  const JianChangeKind(this.label);
  final String label;
}

class JianDirectory {
  const JianDirectory({
    required this.path,
    required this.jianContent,
    required this.jianHash,
    required this.filesHash,
    required this.files,
  });

  final String path;
  final String jianContent;
  final String jianHash;
  final String filesHash;
  final List<JianFileEntry> files;
}

class JianFileEntry {
  const JianFileEntry({
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });

  final String name;
  final bool isDirectory;
  final int size;
  final DateTime modified;
}

String _quickHash(String value) =>
    md5.convert(utf8.encode(value)).toString().substring(0, 12);

String _formatSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}
