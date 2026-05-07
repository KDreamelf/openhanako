import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../shared/hana_home.dart';
import '../shared/yaml_io.dart';
import 'agent.dart';
import 'preferences_manager.dart';

/// AgentManager 与 legacy core/agent-manager.js 对齐。
/// 当前 spike 阶段：CRUD + switch + list + 30s list 缓存。
class AgentManager {
  AgentManager(this._home, this._prefs);

  final HanaHome _home;
  final PreferencesManager _prefs;
  final _uuid = const Uuid();

  String? _activeAgentId;
  ({List<Agent> raw, DateTime ts})? _listCache;
  static const _cacheTtl = Duration(seconds: 30);

  String? get activeAgentId => _activeAgentId;

  Future<List<Agent>> listAgents({bool forceRefresh = false}) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _listCache != null &&
        now.difference(_listCache!.ts) < _cacheTtl) {
      return _listCache!.raw;
    }
    final agentsDir = _home.agentsDir;
    final out = <Agent>[];
    if (agentsDir.existsSync()) {
      final primary = _prefs.getPrimaryAgent();
      for (final entry in agentsDir.listSync().whereType<Directory>()) {
        final id = p.basename(entry.path);
        final cfgFile = _home.agentConfig(id);
        if (!cfgFile.existsSync()) continue;
        final cfg = YamlIo.readMap(cfgFile);
        final agentBlock = cfg['agent'] as Map?;
        final name = (agentBlock?['name'] as String?) ?? id;
        final yuan = (agentBlock?['yuan'] as String?) ?? 'hanako';
        final identityFile = File(p.join(entry.path, 'identity.md'));
        final ishikiFile = File(p.join(entry.path, 'ishiki.md'));
        final avatarFile = File(p.join(entry.path, 'avatars', 'avatar.png'));
        out.add(
          Agent(
            id: id,
            name: name,
            yuan: yuan,
            identity: identityFile.existsSync()
                ? identityFile.readAsStringSync()
                : null,
            ishiki: ishikiFile.existsSync()
                ? ishikiFile.readAsStringSync()
                : null,
            avatarPath: avatarFile.existsSync() ? avatarFile.path : null,
            isPrimary: primary == id,
          ),
        );
      }
    }
    _listCache = (raw: out, ts: now);
    return out;
  }

  Future<Agent> createAgent({
    required String name,
    String? id,
    String yuan = 'hanako',
  }) async {
    final agentId = id ?? _uuid.v4().substring(0, 8);
    final dir = _home.agentDir(agentId);
    if (dir.existsSync() && dir.listSync().isNotEmpty) {
      throw StateError('Agent $agentId already exists');
    }
    dir.createSync(recursive: true);

    // config.yaml 模板（最小可用）
    YamlIo.writeWhole(_home.agentConfig(agentId), {
      'agent': {'name': name, 'yuan': yuan},
      'user': {'name': 'User'},
      'memory': {'enabled': true},
      'skills': {'enabled': <String>[]},
    });
    File(
      p.join(dir.path, 'identity.md'),
    ).writeAsStringSync('# $name\n\n身份描述...\n');
    File(p.join(dir.path, 'ishiki.md')).writeAsStringSync('# 意识流模板\n');

    _home.agentSessions(agentId);
    _home.agentMemory(agentId);
    _home.agentLearnedSkills(agentId);
    Directory(p.join(dir.path, 'avatars')).createSync(recursive: true);
    _home.agentDesk(agentId);

    _listCache = null;
    return Agent(id: agentId, name: name, yuan: yuan);
  }

  Future<Agent> updateAgent(
    String agentId, {
    String? name,
    String? yuan,
    String? identity,
    String? ishiki,
    String? avatarSourcePath,
    bool removeAvatar = false,
  }) async {
    final dir = Directory(p.join(_home.agentsDir.path, agentId));
    if (!dir.existsSync() || !_home.agentConfig(agentId).existsSync()) {
      throw StateError('Agent $agentId not found');
    }
    final cfgFile = _home.agentConfig(agentId);
    final cfg = YamlIo.readMap(cfgFile);
    final agentBlock = Map<String, dynamic>.from(
      (cfg['agent'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    final cleanName = name?.trim();
    if (cleanName != null) {
      if (cleanName.isEmpty) throw ArgumentError('Agent name is required');
      agentBlock['name'] = cleanName;
    }
    final cleanYuan = yuan?.trim();
    if (cleanYuan != null && cleanYuan.isNotEmpty) {
      agentBlock['yuan'] = cleanYuan;
    }
    cfg['agent'] = agentBlock;
    YamlIo.writeWhole(cfgFile, cfg);
    if (identity != null) {
      File(p.join(dir.path, 'identity.md')).writeAsStringSync(identity);
    }
    if (ishiki != null) {
      File(p.join(dir.path, 'ishiki.md')).writeAsStringSync(ishiki);
    }
    final avatarFile = File(p.join(dir.path, 'avatars', 'avatar.png'));
    if (removeAvatar && avatarFile.existsSync()) {
      avatarFile.deleteSync();
    }
    final cleanAvatarPath = avatarSourcePath?.trim();
    if (cleanAvatarPath != null && cleanAvatarPath.isNotEmpty) {
      final source = File(cleanAvatarPath);
      if (!source.existsSync()) {
        throw StateError('Avatar source not found: $cleanAvatarPath');
      }
      avatarFile.parent.createSync(recursive: true);
      source.copySync(avatarFile.path);
    }
    _listCache = null;
    final updated = await getAgent(agentId);
    if (updated == null) throw StateError('Agent $agentId not found');
    return updated;
  }

  Future<void> switchAgent(String agentId) async {
    final dir = _home.agentDir(agentId);
    if (!dir.existsSync()) {
      throw StateError('Agent $agentId not found');
    }
    _activeAgentId = agentId;
  }

  Future<void> deleteAgent(String agentId) async {
    final dir = _home.agentDir(agentId);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    if (_activeAgentId == agentId) _activeAgentId = null;
    if (_prefs.getPrimaryAgent() == agentId) {
      _prefs.savePrimaryAgent(null);
    }
    _listCache = null;
  }

  Future<Agent?> getAgent(String agentId) async {
    final list = await listAgents();
    for (final a in list) {
      if (a.id == agentId) return a;
    }
    return null;
  }

  /// 自动选取活动 agent：preferences.primaryAgent → 第一个 → null
  Future<String?> resolveDefaultAgentId() async {
    final primary = _prefs.getPrimaryAgent();
    final list = await listAgents();
    if (primary != null && list.any((a) => a.id == primary)) return primary;
    if (list.isNotEmpty) return list.first.id;
    return null;
  }
}
