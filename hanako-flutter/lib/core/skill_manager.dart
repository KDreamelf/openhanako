import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../shared/hana_home.dart';

/// SkillManager 实现 **Anthropic Agent Skills 标准**。
///
/// Skill 是一个文件夹，根目录有 `SKILL.md` 作为入口。SKILL.md 顶部 YAML
/// frontmatter 描述 skill 的元信息，Markdown 主体是给模型阅读的 instructions。
/// 文件夹内可放 scripts / resources，模型用通用工具（read_file / bash 等）按
/// 需要读取并执行——SkillManager **不负责 "执行" skill**，只负责发现 + 解析 +
/// 把可用列表注入 system prompt。
///
/// 标准 frontmatter 字段（Anthropic spec）：
///   name           : skill ID（小写、`-` 分隔，与文件夹名一致）
///   description    : 一句话描述（用于 model 决定何时调用）
///   license        : 可选
///   allowed-tools  : 可选，list of tool names this skill is allowed to use
///
/// 兼容字段（legacy hanako）：
///   title          : 显示名（fallback 到 `name`）
///
/// 数据来源：
///   - 全局：`HANA_HOME/skills/{name}/SKILL.md`
///   - per-agent learned：`HANA_HOME/agents/{id}/learned-skills/{name}/SKILL.md`
///
/// per-agent 隔离：learned skill 标记 `_agentId`，不同 agent 间不共享。
/// watch：1s debounce 自动 reload。
class SkillManager {
  SkillManager(this._home);

  final HanaHome _home;

  final List<SkillSpec> _allSkills = [];
  StreamSubscription<FileSystemEvent>? _watcher;
  Timer? _reloadTimer;
  void Function()? _onReloaded;

  List<SkillSpec> get allSkills => List.unmodifiable(_allSkills);

  Future<void> initialize() async {
    await reload();
  }

  Future<void> reload() async {
    _allSkills.clear();
    if (_home.skillsDir.existsSync()) {
      _allSkills.addAll(_scanDir(
        _home.skillsDir,
        source: 'builtin',
        agentId: null,
      ));
    }
    if (_home.agentsDir.existsSync()) {
      for (final agentDir
          in _home.agentsDir.listSync().whereType<Directory>()) {
        final agentId = p.basename(agentDir.path);
        final learned = Directory(p.join(agentDir.path, 'learned-skills'));
        if (!learned.existsSync()) continue;
        _allSkills.addAll(_scanDir(
          learned,
          source: 'learned',
          agentId: agentId,
        ));
      }
    }
  }

  /// 按 agent.config.skills.enabled + per-agent 隔离过滤。
  /// 返回的列表中每个 [SkillSpec] 都可直接送进 system prompt（用 [formatForPrompt]）。
  ({List<SkillSpec> skills, List<String> diagnostics}) getSkillsForAgent(
    String agentId,
    List<String> enabledNames,
  ) {
    if (enabledNames.isEmpty) {
      return (skills: const [], diagnostics: const []);
    }
    final out = <SkillSpec>[];
    for (final s in _allSkills) {
      if (!enabledNames.contains(s.name)) continue;
      if (s.agentId != null && s.agentId != agentId) continue;
      out.add(s);
    }
    final diags = <String>[];
    for (final n in enabledNames) {
      if (!out.any((s) => s.name == n)) {
        diags.add('skill "$n" 已启用但未找到');
      }
    }
    return (skills: out, diagnostics: diags);
  }

  /// 把 enabled skills 列表格式化为 system prompt 段，让模型知道有哪些 skill
  /// 可用、做什么、文件在哪。模型决定要用时自己 `read_file` 加载完整 SKILL.md。
  ///
  /// 这是 Anthropic Agent Skills 推荐的"懒加载"模式——避免一次性把所有 skill
  /// 全文塞进 context。
  static String formatForPrompt(List<SkillSpec> skills) {
    if (skills.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('## Available Skills')
      ..writeln()
      ..writeln(
          'Read the SKILL.md file at the listed path to load the skill\'s '
          'full instructions before using it.')
      ..writeln();
    for (final s in skills) {
      buf
        ..write('- **${s.name}**')
        ..write(s.displayName != s.name ? ' (${s.displayName})' : '')
        ..writeln(' — ${s.description}')
        ..writeln('  path: `${s.filePath}`');
      if (s.allowedTools.isNotEmpty) {
        buf.writeln('  allowed tools: ${s.allowedTools.join(", ")}');
      }
    }
    return buf.toString();
  }

  /// 加载某个 skill 的完整 SKILL.md 内容（在 model 触发时由 read_file tool 调用，
  /// 这里也直接暴露一个 helper 用于内部需要的场景）。
  String? readSkillContent(String name, {String? agentId}) {
    final s = _allSkills.firstWhere(
      (s) => s.name == name && (s.agentId == null || s.agentId == agentId),
      orElse: () => SkillSpec.empty,
    );
    if (s.filePath.isEmpty) return null;
    final f = File(s.filePath);
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  Future<void> watch({required void Function() onReloaded}) async {
    _onReloaded = onReloaded;
    if (_watcher != null) return;
    if (!_home.skillsDir.existsSync()) return;
    try {
      _watcher = _home.skillsDir
          .watch(recursive: true, events: FileSystemEvent.all)
          .listen((event) {
        final name = p.basename(event.path);
        if (name.startsWith('.') || name.endsWith('~') || name.endsWith('#')) {
          return;
        }
        _reloadTimer?.cancel();
        _reloadTimer = Timer(const Duration(seconds: 1), _autoReload);
      });
    } catch (_) {}
  }

  Future<void> _autoReload() async {
    try {
      await reload();
      _onReloaded?.call();
    } catch (_) {}
  }

  Future<void> dispose() async {
    _reloadTimer?.cancel();
    _reloadTimer = null;
    await _watcher?.cancel();
    _watcher = null;
  }

  // -- internals --

  Iterable<SkillSpec> _scanDir(
    Directory dir, {
    required String source,
    String? agentId,
  }) sync* {
    for (final entry in dir.listSync()) {
      if (entry is! Directory) continue;
      final skillFile = File(p.join(entry.path, 'SKILL.md'));
      if (!skillFile.existsSync()) continue;
      try {
        final fm = _parseFrontmatter(skillFile.readAsStringSync());
        final folderName = p.basename(entry.path);
        final name = fm['name'] ?? folderName;
        final displayName = fm['title'] ?? name; // legacy 兼容
        final allowedTools = _parseList(fm['allowed-tools']);
        yield SkillSpec(
          name: name,
          displayName: displayName,
          description: fm['description'] ?? '',
          license: fm['license'],
          allowedTools: allowedTools,
          filePath: skillFile.path,
          baseDir: entry.path,
          source: source,
          agentId: agentId,
        );
      } catch (_) {}
    }
  }

  Map<String, String> _parseFrontmatter(String content) {
    final m = RegExp(r'^---\s*\n([\s\S]*?)\n---').firstMatch(content);
    final out = <String, String>{};
    if (m == null) return out;
    for (final line in m.group(1)!.split('\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final k = line.substring(0, colon).trim();
      var v = line.substring(colon + 1).trim();
      if ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'"))) {
        v = v.substring(1, v.length - 1);
      }
      out[k] = v;
    }
    return out;
  }

  List<String> _parseList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    var s = raw.trim();
    if (s.startsWith('[') && s.endsWith(']')) {
      s = s.substring(1, s.length - 1);
    }
    final out = <String>[];
    for (final part in s.split(RegExp(r'[,\s]+'))) {
      var t = part.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('"') || t.startsWith("'")) t = t.substring(1);
      if (t.endsWith('"') || t.endsWith("'")) {
        t = t.substring(0, t.length - 1);
      }
      if (t.isNotEmpty) out.add(t);
    }
    return out;
  }
}

class SkillSpec {
  final String name;
  final String displayName;
  final String description;
  final String? license;
  final List<String> allowedTools;
  final String filePath;
  final String baseDir;
  final String source; // builtin / learned
  final String? agentId;

  const SkillSpec({
    required this.name,
    required this.displayName,
    required this.description,
    this.license,
    this.allowedTools = const [],
    required this.filePath,
    required this.baseDir,
    required this.source,
    this.agentId,
  });

  static const empty = SkillSpec(
    name: '',
    displayName: '',
    description: '',
    filePath: '',
    baseDir: '',
    source: '',
  );

  Map<String, dynamic> toJson() => {
        'name': name,
        'displayName': displayName,
        'description': description,
        if (license != null) 'license': license,
        if (allowedTools.isNotEmpty) 'allowed-tools': allowedTools,
        'filePath': filePath,
        'baseDir': baseDir,
        'source': source,
        if (agentId != null) 'agentId': agentId,
      };
}
