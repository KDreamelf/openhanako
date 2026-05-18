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
import '../design/design.dart';

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

  Future<void> _installSkill() async {
    final eng = ref.read(engineProvider);
    final agentId = eng.agentManager.activeAgentId;
    if (agentId == null) {
      _showSnack('请先选择 Agent');
      return;
    }
    final pathCtrl = TextEditingController();
    final contentCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    var enable = true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('安装 Skill'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: pathCtrl,
                    decoration: const InputDecoration(
                      labelText: '本地 Skill 目录或 SKILL.md 路径',
                    ),
                  ),
                  const SizedBox(height: DS.s12),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Skill 名称（粘贴内容时可选）',
                    ),
                  ),
                  const SizedBox(height: DS.s12),
                  TextField(
                    controller: contentCtrl,
                    minLines: 6,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      labelText: 'SKILL.md 内容',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: enable,
                    title: const Text('安装后立即启用'),
                    onChanged: (value) =>
                        setDialogState(() => enable = value ?? true),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('安装'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;

    setState(() => _busy = true);
    try {
      final content = contentCtrl.text.trim();
      final path = pathCtrl.text.trim();
      final skill = content.isNotEmpty
          ? await eng.skillManager.installFromContent(
              agentId,
              skillContent: content,
              skillName: nameCtrl.text,
              enable: enable,
            )
          : path.isEmpty
          ? throw ArgumentError('需要本地路径或 SKILL.md 内容')
          : await eng.skillManager.installFromPath(
              agentId,
              path,
              enable: enable,
            );
      await _reload();
      _showSnack('已安装 Skill：${skill.name}');
    } catch (e) {
      _showSnack('安装失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleSkill(SkillSpec skill, bool enabled) async {
    final eng = ref.read(engineProvider);
    final agentId = eng.agentManager.activeAgentId;
    if (agentId == null) return;
    try {
      await eng.skillManager.setSkillEnabled(agentId, skill.name, enabled);
      await _reload();
      _showSnack(enabled ? 'Skill 已启用' : 'Skill 已禁用');
    } catch (e) {
      _showSnack('更新失败：$e');
    }
  }

  Future<void> _deleteSkill(SkillSpec skill) async {
    final eng = ref.read(engineProvider);
    final agentId = eng.agentManager.activeAgentId;
    if (agentId == null || skill.agentId != agentId) return;
    final palette = context.palette;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 Skill'),
        content: Text('删除 ${skill.displayName}？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: palette.accentCrimson,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await eng.skillManager.deleteLearnedSkill(agentId, skill.name);
      if (_selected?.name == skill.name &&
          _selected?.agentId == skill.agentId) {
        _selected = null;
        _selectedContent = null;
      }
      await _reload();
      _showSnack('Skill 已删除');
    } catch (e) {
      _showSnack('删除失败：$e');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开目录失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final eng = ref.watch(engineProvider);
    final agentId = eng.agentManager.activeAgentId;
    final enabled = agentId == null
        ? const <String>{}
        : eng.skillManager.enabledSkillNames(agentId).toSet();
    final all = eng.skillManager.allSkills
        .where((skill) => skill.agentId == null || skill.agentId == agentId)
        .toList(growable: false);
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
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: Column(
          children: [
            _SkillsHeader(
              agentId: agentId,
              total: all.length,
              busy: _busy,
              onInstall: _busy ? null : _installSkill,
              onReload: _busy ? null : _reload,
              onOpenRoot: () async {
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
              onClose: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final narrow = box.maxWidth < 880;
                  final listPane = SizedBox(
                    width: narrow ? null : 360,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            DS.s14,
                            DS.s12,
                            DS.s14,
                            DS.s8,
                          ),
                          child: _SkillSearchField(
                            onChanged: (v) => setState(() => _filter = v),
                          ),
                        ),
                        Expanded(
                          child: filtered.isEmpty
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(DS.s20),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.extension_outlined,
                                          size: 36,
                                          color: palette.textTertiary,
                                        ),
                                        const SizedBox(height: DS.s10),
                                        Text(
                                          all.isEmpty
                                              ? '尚未加载任何 skill'
                                              : '没有匹配的 skill',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: palette.textSecondary,
                                            fontSize: DS.t13,
                                          ),
                                        ),
                                        if (all.isEmpty) ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            eng.home.skillsDir.path,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: palette.textTertiary,
                                              fontSize: DS.t11,
                                              fontFamilyFallback: DS.monoFallback,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                )
                              : ListView(
                                  padding: const EdgeInsets.fromLTRB(
                                    DS.s10,
                                    DS.s4,
                                    DS.s10,
                                    DS.s14,
                                  ),
                                  children: [
                                    if (builtin.isNotEmpty)
                                      _SkillSectionHeader(
                                        '内置 SKILLS',
                                        count: builtin.length,
                                        color: palette.accentEmerald,
                                      ),
                                    for (final s in builtin)
                                      _SkillTile(
                                        spec: s,
                                        enabled: enabled.contains(s.name),
                                        canDelete: false,
                                        selected:
                                            _selected?.name == s.name &&
                                            _selected?.agentId == s.agentId,
                                        onTap: () => _onTapSkill(s),
                                        onToggle: (value) =>
                                            _toggleSkill(s, value),
                                        onDelete: null,
                                      ),
                                    if (learned.isNotEmpty)
                                      _SkillSectionHeader(
                                        '已学习 SKILLS',
                                        count: learned.length,
                                        color: palette.accentLavender,
                                      ),
                                    for (final s in learned)
                                      _SkillTile(
                                        spec: s,
                                        enabled: enabled.contains(s.name),
                                        canDelete: s.agentId == agentId,
                                        selected:
                                            _selected?.name == s.name &&
                                            _selected?.agentId == s.agentId,
                                        onTap: () => _onTapSkill(s),
                                        onToggle: (value) =>
                                            _toggleSkill(s, value),
                                        onDelete: s.agentId == agentId
                                            ? () => _deleteSkill(s)
                                            : null,
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  );
                  final detailPane = Expanded(
                    child: _selected == null
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.touch_app_outlined,
                                  size: 36,
                                  color: palette.textTertiary,
                                ),
                                const SizedBox(height: DS.s10),
                                Text(
                                  '选择一个 Skill 查看 SKILL.md',
                                  style: TextStyle(
                                    color: palette.textSecondary,
                                    fontSize: DS.t13,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : _SkillDetail(
                            spec: _selected!,
                            content: _selectedContent,
                            busy: _busy,
                            onOpenDir: () => _openSkillDir(_selected!),
                          ),
                  );
                  if (narrow) {
                    return Column(
                      children: [
                        SizedBox(height: 300, child: listPane),
                        Container(
                          height: DS.hairline,
                          color: palette.divider,
                        ),
                        detailPane,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      listPane,
                      Container(
                        width: DS.hairline,
                        color: palette.divider,
                      ),
                      detailPane,
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkillsHeader extends StatelessWidget {
  const _SkillsHeader({
    required this.agentId,
    required this.total,
    required this.busy,
    required this.onInstall,
    required this.onReload,
    required this.onOpenRoot,
    required this.onClose,
  });

  final String? agentId;
  final int total;
  final bool busy;
  final VoidCallback? onInstall;
  final VoidCallback? onReload;
  final VoidCallback onOpenRoot;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: palette.bgRaised.withValues(alpha: palette.isDark ? 0.70 : 0.86),
        border: Border(
          bottom: BorderSide(color: palette.divider, width: DS.hairline),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: DS.s16,
            vertical: DS.s12,
          ),
          child: Row(
            children: [
              GlassIconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: '返回',
                onPressed: onClose,
              ),
              const SizedBox(width: DS.s12),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      palette.accentLavender.withValues(alpha: 0.30),
                      palette.accentEmerald.withValues(alpha: 0.22),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(DS.r8),
                  border: Border.all(
                    color: palette.accentEmerald.withValues(alpha: 0.36),
                  ),
                ),
                child: Icon(
                  Icons.extension_outlined,
                  size: 18,
                  color: palette.accentEmerald,
                ),
              ),
              const SizedBox(width: DS.s10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Skill 管理',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t18,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                        if (total > 0) ...[
                          const SizedBox(width: DS.s10),
                          HanaPill(
                            label: '$total 个 skill',
                            color: palette.accentEmerald,
                            dense: true,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      agentId == null ? '未关联 Agent' : 'Agent · $agentId',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: DS.t12,
                      ),
                    ),
                  ],
                ),
              ),
              GlassButton(
                icon: Icons.add_rounded,
                label: '安装',
                dense: true,
                onPressed: onInstall,
              ),
              const SizedBox(width: DS.s4),
              GlassIconButton(
                icon: Icons.refresh_rounded,
                tooltip: '重新扫描',
                onPressed: onReload,
              ),
              const SizedBox(width: DS.s4),
              GlassIconButton(
                icon: Icons.folder_open_rounded,
                tooltip: '打开 skills 根目录',
                onPressed: onOpenRoot,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkillSearchField extends StatefulWidget {
  const _SkillSearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  State<_SkillSearchField> createState() => _SkillSearchFieldState();
}

class _SkillSearchFieldState extends State<_SkillSearchField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      child: FocusScope(
        onFocusChange: (v) => setState(() => _focused = v),
        child: AnimatedContainer(
          duration: DS.dQuick,
          decoration: BoxDecoration(
            color: palette.bgDeep.withValues(alpha: palette.isDark ? 0.5 : 0.4),
            borderRadius: BorderRadius.circular(DS.r10),
            border: Border.all(
              color: _focused
                  ? palette.accentEmerald.withValues(alpha: 0.55)
                  : palette.divider,
              width: _focused ? 1.4 : DS.hairline,
            ),
          ),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: palette.textTertiary,
              ),
              hintText: '搜索 skill…',
              hintStyle: TextStyle(color: palette.textTertiary),
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: DS.s10),
            ),
            cursorColor: palette.accentEmerald,
            onChanged: widget.onChanged,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: DS.t13,
            ),
          ),
        ),
      ),
    );
  }
}

class _SkillSectionHeader extends StatelessWidget {
  const _SkillSectionHeader(this.text, {required this.count, required this.color});
  final String text;
  final int count;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DS.s6, DS.s12, DS.s6, DS.s6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4),
              ],
            ),
          ),
          const SizedBox(width: DS.s8),
          Text(
            text,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: DS.t10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(width: DS.s6),
          Text(
            '$count',
            style: TextStyle(
              color: palette.textTertiary,
              fontSize: DS.t10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SkillTile extends StatefulWidget {
  const _SkillTile({
    required this.spec,
    required this.enabled,
    required this.canDelete,
    required this.selected,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
  });
  final SkillSpec spec;
  final bool enabled;
  final bool canDelete;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onDelete;

  @override
  State<_SkillTile> createState() => _SkillTileState();
}

class _SkillTileState extends State<_SkillTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = widget.enabled ? palette.accentEmerald : palette.textTertiary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DS.dFast,
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: widget.selected
              ? accent.withValues(alpha: 0.10)
              : _hover
                  ? palette.glassFill
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(DS.r8),
          border: widget.selected
              ? Border.all(color: accent.withValues(alpha: 0.36))
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(DS.r8),
          child: InkWell(
            borderRadius: BorderRadius.circular(DS.r8),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(DS.s10, DS.s10, DS.s6, DS.s10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(DS.r6),
                      border: Border.all(
                        color: accent.withValues(alpha: 0.30),
                      ),
                    ),
                    child: Icon(
                      widget.enabled
                          ? Icons.flash_on_rounded
                          : Icons.extension_outlined,
                      size: 14,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: DS.s10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.spec.displayName.isEmpty
                              ? widget.spec.name
                              : widget.spec.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.spec.description.isEmpty
                              ? '（无描述）'
                              : widget.spec.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textSecondary,
                            fontSize: DS.t11,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: DS.s6),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Transform.scale(
                        scale: 0.7,
                        child: Switch(
                          value: widget.enabled,
                          onChanged: widget.onToggle,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      if (widget.canDelete)
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 14,
                          ),
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                            width: 22,
                            height: 22,
                          ),
                          padding: EdgeInsets.zero,
                          color: palette.accentCrimson,
                          onPressed: widget.onDelete,
                        )
                      else if (widget.spec.agentId != null)
                        Tooltip(
                          message: 'agent: ${widget.spec.agentId}',
                          child: Icon(
                            Icons.person_pin_outlined,
                            size: 14,
                            color: palette.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: palette.bgRaised.withValues(
              alpha: palette.isDark ? 0.55 : 0.75,
            ),
            border: Border(
              bottom: BorderSide(color: palette.divider, width: DS.hairline),
            ),
          ),
          padding: const EdgeInsets.all(DS.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      spec.displayName.isEmpty ? spec.name : spec.displayName,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: DS.t20,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ),
                  GlassButton(
                    icon: Icons.folder_open_rounded,
                    label: '打开目录',
                    onPressed: onOpenDir,
                    dense: true,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: DS.s6,
                runSpacing: 4,
                children: [
                  HanaPill(
                    icon: Icons.tag_rounded,
                    label: spec.name,
                    color: palette.accentLavender,
                    dense: true,
                  ),
                  HanaPill(
                    icon: spec.source == 'learned'
                        ? Icons.school_outlined
                        : Icons.inventory_2_outlined,
                    label: spec.source == 'learned'
                        ? '已学习 · ${spec.agentId ?? "?"}'
                        : '内置',
                    color: spec.source == 'learned'
                        ? palette.accentCyan
                        : palette.accentEmerald,
                    dense: true,
                  ),
                  if (spec.license != null)
                    HanaPill(
                      icon: Icons.gavel_outlined,
                      label: 'license · ${spec.license}',
                      color: palette.accentAmber,
                      dense: true,
                    ),
                ],
              ),
              if (spec.description.isNotEmpty) ...[
                const SizedBox(height: DS.s10),
                Text(
                  spec.description,
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: DS.t13,
                    height: 1.55,
                  ),
                ),
              ],
              if (spec.allowedTools.isNotEmpty) ...[
                const SizedBox(height: DS.s10),
                Text(
                  'ALLOWED TOOLS',
                  style: TextStyle(
                    color: palette.textTertiary,
                    fontSize: DS.t10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: DS.s6,
                  runSpacing: 4,
                  children: [
                    for (final t in spec.allowedTools)
                      HanaPill(
                        label: t,
                        color: palette.accentCyan,
                        dense: true,
                        outlined: false,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: busy
              ? Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: palette.accentEmerald,
                    ),
                  ),
                )
              : content == null
              ? Center(
                  child: Text(
                    '内容尚未加载',
                    style: TextStyle(
                      color: palette.textTertiary,
                      fontSize: DS.t13,
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(DS.s20),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      content!,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontFamilyFallback: DS.monoFallback,
                        fontSize: DS.t13,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
        ),
        Container(
          decoration: BoxDecoration(
            color: palette.bgDeep.withValues(alpha: palette.isDark ? 0.5 : 0.4),
            border: Border(
              top: BorderSide(color: palette.divider, width: DS.hairline),
            ),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: DS.s16,
            vertical: DS.s10,
          ),
          child: Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 13,
                color: palette.textTertiary,
              ),
              const SizedBox(width: DS.s6),
              Expanded(
                child: Text(
                  spec.filePath,
                  style: TextStyle(
                    color: palette.textTertiary,
                    fontSize: DS.t11,
                    fontFamilyFallback: DS.monoFallback,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.copy_rounded,
                  size: 14,
                  color: palette.textSecondary,
                ),
                tooltip: '复制路径',
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints.tightFor(width: 26, height: 26),
                padding: EdgeInsets.zero,
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
