import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// HANA_HOME 路径与子目录解析。与 legacy-electron 完全一致：
/// - Windows: %APPDATA%\hanako
/// - macOS / Linux: ~/.hanako
/// - 任何平台均可通过 HANA_HOME 环境变量覆盖
///
/// 子目录：
///   user/preferences.json
///   agents/{id}/{config.yaml, identity.md, ishiki.md, sessions/, memory/, ...}
///   models.json, auth.json
///   channels/{id}.md
///   skills/
class HanaHome {
  HanaHome._(this.root);

  final Directory root;

  static HanaHome? _cached;

  /// 解析并缓存 HANA_HOME。第一次访问时创建目录。
  static Future<HanaHome> resolve() async {
    if (_cached != null) return _cached!;
    final dir = await _resolveRootDir();
    dir.createSync(recursive: true);
    return _cached = HanaHome._(dir);
  }

  static Future<Directory> _resolveRootDir() async {
    final env = Platform.environment['HANA_HOME'];
    if (env != null && env.trim().isNotEmpty) {
      return Directory(env.trim());
    }
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return Directory(p.join(appData, 'hanako'));
      }
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        return Directory(p.join(userProfile, 'AppData', 'Roaming', 'hanako'));
      }
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(p.join(home, '.hanako'));
    }
    return await getApplicationSupportDirectory();
  }

  Directory get userDir => _ensure(p.join(root.path, 'user'));
  Directory get agentsDir => _ensure(p.join(root.path, 'agents'));
  Directory get channelsDir => _ensure(p.join(root.path, 'channels'));
  Directory get skillsDir => _ensure(p.join(root.path, 'skills'));
  Directory get logsDir => _ensure(p.join(root.path, 'logs'));

  File get preferencesFile => File(p.join(userDir.path, 'preferences.json'));
  File get modelsJson => File(p.join(root.path, 'models.json'));
  File get authJson => File(p.join(root.path, 'auth.json'));

  Directory agentDir(String agentId) =>
      _ensure(p.join(agentsDir.path, agentId));

  File agentConfig(String agentId) =>
      File(p.join(agentDir(agentId).path, 'config.yaml'));

  Directory agentSessions(String agentId) =>
      _ensure(p.join(agentDir(agentId).path, 'sessions'));

  Directory agentMemory(String agentId) =>
      _ensure(p.join(agentDir(agentId).path, 'memory'));

  File agentFactsDb(String agentId) =>
      File(p.join(agentMemory(agentId).path, 'facts.db'));

  Directory agentLearnedSkills(String agentId) =>
      _ensure(p.join(agentDir(agentId).path, 'learned-skills'));

  static Directory _ensure(String path) {
    final d = Directory(path);
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 仅供测试：清空缓存，使下一次 [resolve] 重新读取环境变量。
  static void resetForTesting() => _cached = null;
}
