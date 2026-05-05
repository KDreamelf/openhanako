import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/sub_window_client.dart';

/// SharedPreferences key（与主窗口启动读取共用）。
const String kPrefThemeMode = 'hanako.theme.mode';
const String kPrefFontScale = 'hanako.theme.fontScale';

/// Settings 子窗口主入口。
/// 子窗口通过 IPC `business.invoke` 与主窗口 engine 交互。
class SettingsWindow extends ConsumerStatefulWidget {
  const SettingsWindow({super.key});

  @override
  ConsumerState<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends ConsumerState<SettingsWindow> {
  List<Map<String, dynamic>>? _agents;
  Map<String, dynamic>? _prefs;
  Map<String, String>? _paths;
  Map<String, dynamic>? _runtime;
  String _themeMode = 'system';
  double _fontScale = 1.0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadLocalPrefs();
  }

  Future<void> _loadLocalPrefs() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _themeMode = sp.getString(kPrefThemeMode) ?? 'system';
      _fontScale = sp.getDouble(kPrefFontScale) ?? 1.0;
    });
  }

  Future<void> _saveThemeMode(String mode) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(kPrefThemeMode, mode);
    if (!mounted) return;
    setState(() => _themeMode = mode);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('主题已保存，重启子体生效'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _saveFontScale(double scale) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(kPrefFontScale, scale);
    if (!mounted) return;
    setState(() => _fontScale = scale);
  }

  Future<void> _refresh() async {
    try {
      final agents = await SubWindowEngineClient.listAgents();
      final prefs = await SubWindowEngineClient.readPreferences();
      final paths = await SubWindowEngineClient.homePaths();
      final runtime = await SubWindowEngineClient.runtimeInfo();
      if (!mounted) return;
      setState(() {
        _agents = agents;
        _prefs = prefs;
        _paths = paths;
        _runtime = runtime;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _openPath(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开失败：$e')));
    }
  }

  Future<void> _createAgent() async {
    final nameCtrl = TextEditingController();
    String yuan = 'hanako';
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建 Agent'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: '助手名称'),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: yuan,
              decoration: const InputDecoration(labelText: '源模板（yuan）'),
              items: const [
                DropdownMenuItem(value: 'hanako', child: Text('Hanako')),
                DropdownMenuItem(value: 'butter', child: Text('Butter')),
                DropdownMenuItem(value: 'ming', child: Text('Ming')),
              ],
              onChanged: (v) => yuan = v ?? 'hanako',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (result != true || nameCtrl.text.trim().isEmpty) return;
    try {
      await SubWindowEngineClient.call(
        'agents.create',
        payload: {'name': nameCtrl.text.trim(), 'yuan': yuan},
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('创建失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = _error != null
        ? Center(child: Text('Error: $_error'))
        : _agents == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Column(
                    children: [
                      _buildAgentsSection(),
                      const SizedBox(height: 24),
                      _buildAppearanceSection(),
                      const SizedBox(height: 24),
                      _buildShortcutsSection(),
                      const SizedBox(height: 24),
                      _buildPathsSection(),
                      const SizedBox(height: 24),
                      _buildPreferencesSection(),
                      const SizedBox(height: 24),
                      _buildAboutSection(),
                    ],
                  ),
                ),
              ),
            ],
          );

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _SettingsHeader(onRefresh: _refresh),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  // ===== Section 构建 =====

  Widget _buildAgentsSection() {
    return _Section(
      title: 'Agent 管理',
      subtitle: '子体的会话身份与源模板。',
      child: Card(
        child: Column(
          children: [
            for (final a in _agents!)
              ListTile(
                leading: Icon(
                  a['isPrimary'] == true ? Icons.star : Icons.person_outline,
                ),
                title: Text(a['name'] as String),
                subtitle: Text('${a['id']} · yuan=${a['yuan']}'),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'switch') {
                      await SubWindowEngineClient.call(
                        'agents.switch',
                        payload: {'id': a['id']},
                      );
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已切换到 ${a['name']}')),
                      );
                    } else if (v == 'delete') {
                      await SubWindowEngineClient.call(
                        'agents.delete',
                        payload: {'id': a['id']},
                      );
                      await _refresh();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'switch', child: Text('切换为活动')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新建 Agent'),
              onTap: _createAgent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppearanceSection() {
    return _Section(
      title: '外观',
      subtitle: '本地显示偏好，保存到当前设备。',
      child: Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('主题'),
              subtitle: const Text('保存后重启生效'),
              trailing: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'light', label: Text('浅')),
                  ButtonSegment(value: 'dark', label: Text('深')),
                  ButtonSegment(value: 'system', label: Text('跟随')),
                ],
                selected: {_themeMode},
                onSelectionChanged: (s) => _saveThemeMode(s.first),
              ),
            ),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.format_size),
              title: const Text('字体大小'),
              subtitle: Text('当前缩放：${_fontScale.toStringAsFixed(2)}x'),
              trailing: SizedBox(
                width: 200,
                child: Slider(
                  value: _fontScale.clamp(0.8, 1.4),
                  min: 0.8,
                  max: 1.4,
                  divisions: 12,
                  label: _fontScale.toStringAsFixed(2),
                  onChanged: (v) => _saveFontScale(v),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShortcutsSection() {
    final shortcuts = <_Shortcut>[
      _Shortcut('Ctrl + ,', '打开设置'),
      _Shortcut('Ctrl + N', '新会话'),
      _Shortcut('Ctrl + K', '快速切换模型'),
      _Shortcut('Ctrl + L', '清空当前会话'),
      _Shortcut('Enter', '发送消息'),
      _Shortcut('Shift + Enter', '换行'),
    ];
    return _Section(
      title: '快捷键',
      subtitle: '桌面端常用操作入口。',
      child: Card(
        child: Column(
          children: [
            for (final s in shortcuts)
              ListTile(
                dense: true,
                leading: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    s.key,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                title: Text(s.label),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPathsSection() {
    if (_paths == null) return const SizedBox.shrink();
    final entries = <(String, String)>[
      ('HANA_HOME', _paths!['root'] ?? ''),
      ('Agents', _paths!['agentsDir'] ?? ''),
      ('Skills', _paths!['skillsDir'] ?? ''),
      ('Logs', _paths!['logsDir'] ?? ''),
      ('Preferences', _paths!['preferencesFile'] ?? ''),
      ('Models JSON', _paths!['modelsJson'] ?? ''),
    ];
    return _Section(
      title: '路径',
      subtitle: '子体本地数据、技能、日志和配置位置。',
      child: Card(
        child: Column(
          children: [
            for (final (label, path) in entries)
              ListTile(
                dense: true,
                title: Text(label),
                subtitle: SelectableText(
                  path,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: '复制路径',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: path));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('路径已复制'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.folder_open, size: 18),
                      tooltip: '打开目录',
                      onPressed: () => _openPath(path),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreferencesSection() {
    return _Section(
      title: 'Preferences (raw)',
      subtitle: '直接查看当前偏好配置。',
      child: Card(
        child: Column(
          children: [
            for (final entry in (_prefs ?? {}).entries)
              ListTile(
                dense: true,
                title: Text(entry.key),
                subtitle: Text('${entry.value}'),
              ),
            if ((_prefs ?? {}).isEmpty) const ListTile(title: Text('（暂无配置）')),
          ],
        ),
      ),
    );
  }

  Widget _buildAboutSection() {
    return _Section(
      title: '关于',
      subtitle: '当前子体实现与上游项目引用。',
      child: Card(
        child: Column(
          children: [
            const ListTile(
              leading: Icon(Icons.info_outline, size: 22),
              title: Text('PH01 子体 / Hanako Flutter'),
              subtitle: Text('个人 AI 子体 · Flutter Desktop · 二次设计版本'),
            ),
            const Divider(height: 0),
            const ListTile(
              title: Text('原始开源项目'),
              subtitle: SelectableText(
                'liliMozi/openhanako\nhttps://github.com/liliMozi/openhanako',
              ),
            ),
            const Divider(height: 0),
            const ListTile(
              title: Text('原项目许可证'),
              subtitle: SelectableText(
                'Apache License 2.0\n本客户端保留对原始 openhanako 项目的来源引用；当前上游仓库标注为 Apache-2.0。',
              ),
            ),
            const Divider(height: 0),
            const ListTile(
              title: Text('二次设计说明'),
              subtitle: Text(
                '当前界面面向 PH01 子体重新设计，Hanako / openhanako 仅作为原始开源项目来源引用，不作为 PH01 系统品牌归属。',
              ),
            ),
            const Divider(height: 0),
            ListTile(
              title: const Text('运行平台'),
              subtitle: Text(
                '${_runtime?['platform']} '
                '(${_runtime?['numberOfProcessors']} 核, '
                '${_runtime?['localeName']})',
              ),
            ),
            ListTile(
              title: const Text('Dart Runtime'),
              subtitle: Text('${_runtime?['dartVersion'] ?? "?"}'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader({required this.onRefresh});
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.tune, color: c.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '子体设置',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '管理本地 Agent、外观、路径和项目来源信息。',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton.filledTonal(
              icon: const Icon(Icons.refresh),
              onPressed: onRefresh,
              tooltip: '刷新',
              style: IconButton.styleFrom(
                fixedSize: const Size(40, 40),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.child});
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: c.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
        child,
      ],
    );
  }
}

class _Shortcut {
  const _Shortcut(this.key, this.label);
  final String key;
  final String label;
}
