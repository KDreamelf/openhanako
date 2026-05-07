import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../identity/identity.dart';
import '../onboarding/onboarding_page.dart';

/// SharedPreferences key（与主窗口启动读取共用）。
const String kPrefThemeMode = 'hanako.theme.mode';
const String kPrefFontScale = 'hanako.theme.fontScale';

/// Settings 主窗口页面。
///
/// 设置页需要直接访问主窗口 ProviderScope 中的 HanaEngine；不再通过
/// desktop_multi_window 创建独立子 Engine。
class SettingsWindow extends ConsumerStatefulWidget {
  const SettingsWindow({super.key});

  @override
  ConsumerState<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends ConsumerState<SettingsWindow> {
  List<Map<String, dynamic>>? _agents;
  Map<String, dynamic>? _prefs;
  Map<String, dynamic>? _authConfig;
  Map<String, dynamic>? _userConfig;
  Map<String, String>? _paths;
  Map<String, dynamic>? _runtime;
  bool _hasSavedIdentity = false;
  bool _identityReady = false;
  bool _accountBusy = false;
  String? _identityPublicKeyHash;
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
      final eng = ref.read(engineProvider);
      final repo = ref.read(identityRepositoryProvider);
      final agents = await eng.agentManager.listAgents(forceRefresh: true);
      final prefs = eng.preferences.getPreferences();
      final cfg = eng.config.read();
      final identity = repo.current;
      final hasSavedIdentity = await repo.hasSavedIdentity();
      final paths = {
        'root': eng.home.root.path,
        'agentsDir': eng.home.agentsDir.path,
        'skillsDir': eng.home.skillsDir.path,
        'userDir': eng.home.userDir.path,
        'logsDir': eng.home.logsDir.path,
        'preferencesFile': eng.home.preferencesFile.path,
        'modelsJson': eng.home.modelsJson.path,
        'authJson': eng.home.authJson.path,
      };
      final runtime = {
        'platform': Platform.operatingSystem,
        'platformVersion': Platform.operatingSystemVersion,
        'numberOfProcessors': Platform.numberOfProcessors,
        'localeName': Platform.localeName,
        'dartVersion': Platform.version,
      };
      if (!mounted) return;
      setState(() {
        _agents = agents.map((a) => a.toJson()).toList();
        _prefs = prefs;
        _authConfig = _stringKeyMap(cfg['auth']);
        _userConfig = _stringKeyMap(cfg['user']);
        _hasSavedIdentity = hasSavedIdentity;
        _identityReady = identity != null;
        _identityPublicKeyHash = identity?.publicKeyHash;
        _paths = paths;
        _runtime = runtime;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _openAccountSetup() async {
    final result = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const OnboardingPage()));
    if (result == true && mounted) {
      ref.read(identityRevisionProvider.notifier).state++;
    }
    await _refresh();
  }

  Future<HanakoIdentity> _loadIdentityForAccountAction() async {
    final repo = ref.read(identityRepositoryProvider);
    final current = repo.current;
    if (current != null) return current;
    final identity = await repo.unlock();
    ref.read(identityRevisionProvider.notifier).state++;
    return identity;
  }

  Future<void> _unlockIdentity() async {
    if (_accountBusy) return;
    setState(() => _accountBusy = true);
    try {
      final eng = ref.read(engineProvider);
      final repo = ref.read(identityRepositoryProvider);
      final identity = await repo.unlock();
      ref.read(identityRevisionProvider.notifier).state++;
      try {
        await eng.syncGatewayModels(identity);
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本机身份已解锁')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('解锁失败：$e')));
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _lockIdentity() async {
    if (_accountBusy) return;
    setState(() => _accountBusy = true);
    try {
      await ref.read(identityRepositoryProvider).lock();
      ref.read(identityRevisionProvider.notifier).state++;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('身份已锁定，本机密钥仍保留')));
      await _refresh();
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _syncModels() async {
    if (_accountBusy) return;
    final identity = ref.read(identityRepositoryProvider).current;
    if (identity == null) return;
    setState(() => _accountBusy = true);
    try {
      await ref.read(engineProvider).syncGatewayModels(identity);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('模型列表已同步')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('同步失败：$e')));
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _showMnemonic() async {
    if (_accountBusy) return;
    setState(() => _accountBusy = true);
    try {
      final identity = await _loadIdentityForAccountAction();
      final words = identity.mnemonic?.words;
      if (words == null || words.length != 12) {
        throw StateError('当前身份没有保存助记词');
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _MnemonicDialog(
          words: words,
          publicKeyHash: identity.publicKeyHash,
        ),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('查看助记词失败：$e')));
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _regenerateStory() async {
    if (_accountBusy) return;
    setState(() => _accountBusy = true);
    try {
      final registration = await ref
          .read(identityRepositoryProvider)
          .regenerateStoryForCurrent();
      ref.read(identityRevisionProvider.notifier).state++;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _StoryDialog(registration: registration),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('重新生成故事失败：$e')));
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _deleteLocalIdentity() async {
    if (_accountBusy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除本机身份？'),
        content: const Text(
          '这会删除当前 Windows 用户下的本机加密身份 vault。'
          '覆盖安装不会删它，但这里确认删除后只能用 12 个名词或记忆故事重新登录恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _accountBusy = true);
    try {
      await ref.read(identityRepositoryProvider).logout();
      ref.read(identityRevisionProvider.notifier).state++;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本机身份已删除')));
      await _refresh();
    } finally {
      if (mounted) setState(() => _accountBusy = false);
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
      final eng = ref.read(engineProvider);
      await eng.agentManager.createAgent(
        name: nameCtrl.text.trim(),
        yuan: yuan,
      );
      ref.invalidate(agentListProvider);
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
                      _buildMySection(),
                      const SizedBox(height: 24),
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
            _SettingsHeader(
              onRefresh: _refresh,
              onClose: () => Navigator.of(context).maybePop(),
            ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  // ===== Section 构建 =====

  Widget _buildMySection() {
    final auth = _authConfig ?? const <String, dynamic>{};
    final user = _userConfig ?? const <String, dynamic>{};
    final username = _textValue(auth['username']) ?? _textValue(user['name']);
    final userId = _textValue(auth['user_id']);
    final tier = _textValue(auth['tier']);
    final configPubkeyHash = _textValue(auth['pubkey_hash']);
    final currentHash = _identityPublicKeyHash ?? configPubkeyHash;
    final vaultLabel = _hasSavedIdentity ? '本机密钥已保存' : '本机密钥未创建';
    final identityLabel = _identityReady ? '身份已解锁' : '身份未解锁';
    final accountParts = [
      if (userId != null) 'ID $userId',
      if (tier != null) '等级 $tier',
      if (currentHash != null) '指纹 ${_shortHash(currentHash)}',
    ];

    return _Section(
      title: '我的',
      subtitle: '账号、本机身份和恢复信息。',
      child: Card(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _identityReady
                            ? Icons.verified_user
                            : Icons.lock_outline,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              identityLabel,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              vaultLabel,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (!_identityReady && _hasSavedIdentity)
                        FilledButton.icon(
                          onPressed: _accountBusy ? null : _unlockIdentity,
                          icon: const Icon(Icons.lock_open, size: 18),
                          label: const Text('解锁'),
                        ),
                      if (_identityReady)
                        OutlinedButton.icon(
                          onPressed: _accountBusy ? null : _showMnemonic,
                          icon: const Icon(Icons.visibility_outlined, size: 18),
                          label: const Text('查看助记词'),
                        ),
                      if (_identityReady)
                        OutlinedButton.icon(
                          onPressed: _accountBusy ? null : _regenerateStory,
                          icon: const Icon(
                            Icons.auto_stories_outlined,
                            size: 18,
                          ),
                          label: const Text('重新生成故事'),
                        ),
                      if (_identityReady)
                        OutlinedButton.icon(
                          onPressed: _accountBusy ? null : _syncModels,
                          icon: const Icon(Icons.sync, size: 18),
                          label: const Text('同步模型'),
                        ),
                      if (_identityReady)
                        OutlinedButton.icon(
                          onPressed: _accountBusy ? null : _lockIdentity,
                          icon: const Icon(Icons.lock, size: 18),
                          label: const Text('锁定'),
                        ),
                      if (!_identityReady)
                        OutlinedButton.icon(
                          onPressed: _accountBusy ? null : _openAccountSetup,
                          icon: const Icon(Icons.manage_accounts, size: 18),
                          label: Text(_hasSavedIdentity ? '恢复其他账号' : '创建账号'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(username == null ? '未绑定云端账号' : '账号：$username'),
              subtitle: Text(
                accountParts.isEmpty
                    ? '完成注册或登录后会显示云端账号信息'
                    : accountParts.join(' · '),
              ),
              trailing: _hasSavedIdentity
                  ? TextButton.icon(
                      onPressed: _accountBusy ? null : _deleteLocalIdentity,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除本机身份'),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

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
                    final eng = ref.read(engineProvider);
                    if (v == 'switch') {
                      final id = a['id'] as String;
                      await eng.agentManager.switchAgent(id);
                      eng.config.retarget(id);
                      ref.read(activeAgentIdProvider.notifier).state = id;
                      ref.invalidate(agentListProvider);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已切换到 ${a['name']}')),
                      );
                    } else if (v == 'delete') {
                      await eng.agentManager.deleteAgent(a['id'] as String);
                      if (ref.read(activeAgentIdProvider) == a['id']) {
                        ref.read(activeAgentIdProvider.notifier).state = null;
                      }
                      ref.invalidate(agentListProvider);
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
              title: Text('幻宙01 / PH01 子体'),
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
  const _SettingsHeader({required this.onRefresh, required this.onClose});
  final VoidCallback onRefresh;
  final VoidCallback onClose;

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
            IconButton.filledTonal(
              icon: const Icon(Icons.arrow_back),
              onPressed: onClose,
              tooltip: '返回',
              style: IconButton.styleFrom(
                fixedSize: const Size(40, 40),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(width: 12),
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
            const SizedBox(width: 12),
            FilledButton.icon(
              icon: const Icon(Icons.check),
              label: const Text('完成'),
              onPressed: onClose,
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

class _MnemonicDialog extends StatelessWidget {
  const _MnemonicDialog({required this.words, required this.publicKeyHash});

  final List<String> words;
  final String publicKeyHash;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('助记词'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '这是当前本机身份的 12 个名词。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < words.length; i++)
                    Chip(
                      label: Text('${i + 1}. ${words[i]}'),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              SelectableText(
                words.join(' '),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 12),
              Text(
                '指纹：${_shortHash(publicKeyHash)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: words.join(' ')));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('助记词已复制'),
                duration: Duration(seconds: 1),
              ),
            );
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('复制'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _StoryDialog extends StatelessWidget {
  const _StoryDialog({required this.registration});

  final IdentityRegistration registration;

  @override
  Widget build(BuildContext context) {
    final story = registration.story.trim();
    final hasStory = story.isNotEmpty && !registration.fallback;
    return AlertDialog(
      title: const Text('记忆故事'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasStory)
                SelectableText(
                  story,
                  style: Theme.of(context).textTheme.bodyLarge,
                )
              else
                Text(
                  '故事生成暂不可用，当前可直接保存 12 个名词。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < registration.words.length; i++)
                    Chip(
                      label: Text('${i + 1}. ${registration.words[i]}'),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (hasStory)
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: story));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('故事已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制故事'),
          ),
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(
              ClipboardData(text: registration.words.join(' ')),
            );
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('助记词已复制'),
                duration: Duration(seconds: 1),
              ),
            );
          },
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('复制助记词'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

Map<String, dynamic> _stringKeyMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, dynamic value) => MapEntry('$key', value));
}

String? _textValue(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

String _shortHash(String hash) {
  final text = hash.trim();
  if (text.length <= 16) return text;
  return '${text.substring(0, 16)}...';
}
