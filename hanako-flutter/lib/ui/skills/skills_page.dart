// lib/ui/skills/skills_page.dart
//
// Skill 管理页面：列出已加载 skill、查看 SKILL.md、reload、打开 skill 目录。
//
// 数据来源 [engine.skillManager.allSkills]。
// 当前不做"启用/禁用"切换 UI——启用列表在 agent.config.skills.enabled 里
// （per-agent 持久化），UI 入口将来配合 ChatPage 的 agent 切换器一起做。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/skill_manager.dart';

class SkillsPage extends ConsumerStatefulWidget {
  const SkillsPage({super.key});

  @override
  ConsumerState<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends ConsumerState<SkillsPage> {
  SkillSpec? _selected;
  String? _selectedContent;
  String _filter = '';
  bool _busy = false;

  Future<void> _reload() async {
    setState(() => _busy = true);
    try {
      final eng = ref.read(engineProvider);
      await eng.skillManager.reload();
      if (_selected != null) {
        // 重新读已选中 skill 的内容
        final updated = eng.skillManager.allSkills.firstWhere(
          (s) => s.name == _selected!.name && s.agentId == _selected!.agentId,
          orElse: () => SkillSpec.empty,
        );
        if (updated.filePath.isEmpty) {
          _selected = null;
          _selectedContent = null;
        } else {
          _selected = updated;
          _selectedContent = await File(updated.filePath).readAsString();
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _onTapSkill(SkillSpec skill) async {
    setState(() {
      _selected = skill;
      _selectedContent = null;
      _busy = true;
    });
    try {
      final content = await File(skill.filePath).readAsString();
      if (!mounted) return;
      setState(() {
        _selectedContent = content;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _selectedContent = '读取失败：$e';
        _busy = false;
      });
    }
  }

  Future<void> _openSkillDir(SkillSpec skill) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [skill.baseDir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [skill.baseDir]);
      } else {
        await Process.run('xdg-open', [skill.baseDir]);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开目录失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final eng = ref.watch(engineProvider);
    final all = eng.skillManager.allSkills;
    final filtered = _filter.isEmpty
        ? all
        : all.where((s) {
            final f = _filter.toLowerCase();
            return s.name.toLowerCase().contains(f) ||
                s.displayName.toLowerCase().contains(f) ||
                s.description.toLowerCase().contains(f);
          }).toList();

    final builtin = filtered.where((s) => s.source == 'builtin').toList();
    final learned = filtered.where((s) => s.source == 'learned').toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Skill 管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新扫描',
            onPressed: _busy ? null : _reload,
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: '打开 skills 根目录',
            onPressed: () async {
              try {
                final dir = eng.home.skillsDir;
                if (!dir.existsSync()) dir.createSync(recursive: true);
                if (Platform.isWindows) {
                  await Process.run('explorer', [dir.path]);
                } else if (Platform.isMacOS) {
                  await Process.run('open', [dir.path]);
                } else {
                  await Process.run('xdg-open', [dir.path]);
                }
              } catch (_) {}
            },
          ),
        ],
      ),
      body: Row(
        children: [
          // 左：列表
          SizedBox(
            width: 360,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search, size: 20),
                      hintText: '搜索 skill…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _filter = v),
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Text(
                            all.isEmpty
                                ? '尚未加载任何 skill\n（${eng.home.skillsDir.path}）'
                                : '没有匹配的 skill',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        )
                      : ListView(
                          children: [
                            if (builtin.isNotEmpty)
                              _SkillSectionHeader('内置（builtin）·  ${builtin.length}'),
                            for (final s in builtin)
                              _SkillTile(
                                spec: s,
                                selected: _selected?.name == s.name &&
                                    _selected?.agentId == s.agentId,
                                onTap: () => _onTapSkill(s),
                              ),
                            if (learned.isNotEmpty)
                              _SkillSectionHeader(
                                  '已学习（learned）·  ${learned.length}'),
                            for (final s in learned)
                              _SkillTile(
                                spec: s,
                                selected: _selected?.name == s.name &&
                                    _selected?.agentId == s.agentId,
                                onTap: () => _onTapSkill(s),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          // 右：详情
          Expanded(
            child: _selected == null
                ? const Center(
                    child: Text(
                      '从左侧选择一个 skill 查看 SKILL.md 内容',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : _SkillDetail(
                    spec: _selected!,
                    content: _selectedContent,
                    busy: _busy,
                    onOpenDir: () => _openSkillDir(_selected!),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SkillSectionHeader extends StatelessWidget {
  const _SkillSectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 0.5,
            ),
      ),
    );
  }
}

class _SkillTile extends StatelessWidget {
  const _SkillTile({
    required this.spec,
    required this.selected,
    required this.onTap,
  });
  final SkillSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      title: Text(spec.displayName.isEmpty ? spec.name : spec.displayName),
      subtitle: Text(
        spec.description.isEmpty ? '（无描述）' : spec.description,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: spec.agentId != null
          ? Tooltip(
              message: 'agent: ${spec.agentId}',
              child: const Icon(Icons.person_pin, size: 16),
            )
          : null,
      onTap: onTap,
    );
  }
}

class _SkillDetail extends StatelessWidget {
  const _SkillDetail({
    required this.spec,
    required this.content,
    required this.busy,
    required this.onOpenDir,
  });

  final SkillSpec spec;
  final String? content;
  final bool busy;
  final VoidCallback onOpenDir;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 头部信息
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      spec.displayName.isEmpty ? spec.name : spec.displayName,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('打开目录'),
                    onPressed: onOpenDir,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'name: ${spec.name}'
                '${spec.source == "learned" ? "  ·  agent: ${spec.agentId}" : "  ·  内置"}',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 8),
              if (spec.description.isNotEmpty)
                Text(spec.description, style: theme.textTheme.bodyMedium),
              if (spec.allowedTools.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    Text('allowed-tools: ',
                        style: theme.textTheme.bodySmall),
                    for (final t in spec.allowedTools)
                      Chip(
                        label: Text(t, style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                  ],
                ),
              ],
              if (spec.license != null) ...[
                const SizedBox(height: 4),
                Text('license: ${spec.license}',
                    style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        // SKILL.md 内容
        Expanded(
          child: busy
              ? const Center(child: CircularProgressIndicator())
              : content == null
                  ? const Center(child: Text('（内容尚未加载）'))
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          content!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                            height: 1.4,
                          ),
                        ),
                      ),
                    ),
        ),
        // 底部：路径 + 复制
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.description, size: 14, color: Colors.grey),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  spec.filePath,
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 14),
                tooltip: '复制路径',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: spec.filePath));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('路径已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
