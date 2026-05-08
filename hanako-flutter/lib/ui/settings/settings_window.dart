import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../core/browser_manager.dart';
import '../../core/bridge_source_manager.dart';
import '../../core/collaboration_manager.dart';
import '../../core/heartbeat_runtime.dart';
import '../../identity/identity.dart';
import '../../local_tools/local_tools.dart';
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
  HeartbeatConfig? _heartbeatConfig;
  List<Map<String, dynamic>> _cronJobs = const [];
  List<Map<String, dynamic>> _activities = const [];
  List<BridgeSourceConfig> _bridgeSources = const [];
  Map<String, BridgeSourceStatus> _bridgeStatuses = const {};
  BrowserStatus? _browserStatus;
  CollaborationSettings? _collaborationSettings;
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
      final heartbeatConfig = eng.heartbeatRuntime.readConfig();
      final cronJobs = eng.cronStore
          .listJobs()
          .map((job) {
            final runs = eng.cronStore.getRunHistory(job.id, limit: 1);
            return {
              ...job.toJson(),
              if (runs.isNotEmpty) 'lastRun': runs.first.toJson(),
            };
          })
          .toList(growable: false);
      final activities = eng.activityStore
          .list(limit: 20)
          .map((entry) => entry.toJson())
          .toList(growable: false);
      final bridgeSources = eng.bridgeSourceManager.listSources();
      final bridgeStatuses = eng.bridgeSourceManager.statuses();
      final browserStatus = eng.browserManager.status();
      final collaborationSettings = eng.collaborationManager.readSettings();
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
        _heartbeatConfig = heartbeatConfig;
        _cronJobs = cronJobs;
        _activities = activities;
        _bridgeSources = bridgeSources;
        _bridgeStatuses = bridgeStatuses;
        _browserStatus = browserStatus;
        _collaborationSettings = collaborationSettings;
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

  Future<void> _verifyStoryRecovery() async {
    if (_accountBusy) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _StoryVerificationDialog(onVerify: _runStoryRecovery),
    );
    await _refresh();
  }

  String? _configuredUsername() {
    return _textValue((_authConfig ?? const <String, dynamic>{})['username']) ??
        _textValue((_userConfig ?? const <String, dynamic>{})['name']);
  }

  Future<void> _rotatePubkey() async {
    if (_accountBusy) return;
    final username = _configuredUsername();
    if (username == null || username.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前配置缺少云端用户名')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _PubkeyRotationDialog(
        username: username.trim(),
        onSendCode: () => _startPubkeyRotationEmail(username.trim()),
        onRotate: (challengeId, code) => _confirmPubkeyRotation(
          username: username.trim(),
          challengeId: challengeId,
          code: code,
        ),
      ),
    );
    await _refresh();
  }

  Future<PubkeyRotationEmailChallenge> _startPubkeyRotationEmail(
    String username,
  ) async {
    final identity = await _loadIdentityForAccountAction();
    return ref
        .read(engineProvider)
        .backendClient
        .startPubkeyRotationEmail(
          keyPair: identity.keyPair,
          username: username,
        );
  }

  Future<_PubkeyRotationOutcome> _confirmPubkeyRotation({
    required String username,
    required String challengeId,
    required String code,
  }) async {
    final eng = ref.read(engineProvider);
    final repo = ref.read(identityRepositoryProvider);
    final oldIdentity = await _loadIdentityForAccountAction();
    final replacement = await repo.generateReplacementIdentityPreview();
    final result = await eng.backendClient.rotatePubkey(
      keyPair: oldIdentity.keyPair,
      username: username,
      emailChallengeId: challengeId,
      emailCode: code,
      newPubkeyHex: replacement.identity.publicKeyHex,
    );
    if (result.newPubkeyHash != replacement.identity.publicKeyHash) {
      throw StateError('认证中心返回的新公钥指纹与本机新身份不一致');
    }

    String? warning;
    var localPersisted = false;
    try {
      await repo.replaceCurrentIdentity(replacement.identity);
      localPersisted = true;
    } catch (e) {
      warning = '云端密钥已轮换，但本机身份 vault 写入失败：$e';
    }
    if (localPersisted) {
      try {
        eng.config.writeAt([
          'identity',
          'public_key',
        ], replacement.identity.publicKeyHex);
        eng.config.writeAt([
          'identity',
          'public_key_hash',
        ], replacement.identity.publicKeyHash);
        eng.config.writeAt(['auth', 'user_id'], result.userId);
        eng.config.writeAt(['auth', 'username'], result.username);
        eng.config.writeAt(['auth', 'tier'], result.tier);
        eng.config.writeAt(['auth', 'pubkey_hash'], result.newPubkeyHash);
        ref.read(identityRevisionProvider.notifier).state++;
      } catch (e) {
        warning = '密钥已轮换，本机身份已更新，但配置写入失败：$e';
      }
    }
    if (localPersisted) {
      try {
        await eng.syncGatewayModels(replacement.identity);
      } catch (e) {
        warning = warning == null ? '密钥已轮换，但模型同步失败：$e' : '$warning；模型同步失败：$e';
      }
    }

    return _PubkeyRotationOutcome(
      registration: replacement,
      result: result,
      localPersisted: localPersisted,
      warning: warning,
    );
  }

  Future<_StoryVerificationResult> _runStoryRecovery(
    String story,
    void Function(StoryRecoveryProgress progress) onProgress,
  ) async {
    final eng = ref.read(engineProvider);
    final repo = ref.read(identityRepositoryProvider);
    final username =
        _textValue((_authConfig ?? const <String, dynamic>{})['username']) ??
        _textValue((_userConfig ?? const <String, dynamic>{})['name']);
    final outcome = await repo.verifyCurrentStory(
      storyOrWords: story,
      softDeadline: const Duration(minutes: 5),
      hardDeadline: const Duration(minutes: 10),
      onRecoveryProgress: onProgress,
    );
    ref.read(identityRevisionProvider.notifier).state++;
    if (!outcome.success) {
      return _StoryVerificationResult(
        success: false,
        message: outcome.malformed
            ? '无法解析这段故事；可以直接粘贴 12 个名词再试。'
            : outcome.timedOut
            ? '恢复超时；这段故事暂时无法稳定复原当前身份。'
            : '未能恢复当前身份；请检查故事锚点和顺序。',
        attempted: outcome.attempted,
        elapsedMs: outcome.elapsedMs,
        hammingDistance: outcome.hammingDistance,
        usedLlm: outcome.usedLlm,
        score: _memoryAccuracyScore(outcome),
        candidateMatrix: outcome.parsedColumns,
        candidatesPerColumn: outcome.candidatesPerColumn,
        anchors: outcome.anchors,
      );
    }

    final identity = outcome.identity!;
    if (username != null && username.trim().isNotEmpty) {
      final auth = await eng.backendClient.login(
        keyPair: identity.keyPair,
        username: username.trim(),
      );
      if (auth.pubkeyHash != identity.publicKeyHash) {
        throw StateError('云端返回的身份指纹与本地恢复结果不一致');
      }
    }

    return _StoryVerificationResult(
      success: true,
      message: username == null || username.trim().isEmpty
          ? '验证通过：这段故事可以复原当前本机身份。'
          : '验证通过：这段故事可以复原当前身份，并通过云端身份确认。',
      attempted: outcome.attempted,
      elapsedMs: outcome.elapsedMs,
      hammingDistance: outcome.hammingDistance,
      usedLlm: outcome.usedLlm,
      score: _memoryAccuracyScore(outcome),
      publicKeyHash: identity.publicKeyHash,
      candidateMatrix: outcome.parsedColumns,
      candidatesPerColumn: outcome.candidatesPerColumn,
      anchors: outcome.anchors,
    );
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

  Future<void> _editAgentProfile(Map<String, dynamic> agent) async {
    final id = agent['id'] as String;
    final nameCtrl = TextEditingController(
      text: _textValue(agent['name']) ?? '',
    );
    final identityCtrl = TextEditingController(
      text: _textValue(agent['identity']) ?? '',
    );
    final ishikiCtrl = TextEditingController(
      text: _textValue(agent['ishiki']) ?? '',
    );
    final avatarCtrl = TextEditingController();
    var yuan = _textValue(agent['yuan']) ?? 'hanako';
    var removeAvatar = false;
    final currentAvatar = _textValue(agent['avatarPath']);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('编辑 Agent 档案'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _AgentAvatar(
                        avatarPath: currentAvatar,
                        isPrimary: agent['isPrimary'] == true,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: avatarCtrl,
                          decoration: const InputDecoration(
                            labelText: '头像文件路径（留空不变）',
                          ),
                        ),
                      ),
                    ],
                  ),
                  CheckboxListTile(
                    value: removeAvatar,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('删除当前头像'),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: currentAvatar == null
                        ? null
                        : (value) => setDialogState(
                            () => removeAvatar = value ?? false,
                          ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: yuan,
                    decoration: const InputDecoration(labelText: '源模板（yuan）'),
                    items: const [
                      DropdownMenuItem(value: 'hanako', child: Text('Hanako')),
                      DropdownMenuItem(value: 'butter', child: Text('Butter')),
                      DropdownMenuItem(value: 'ming', child: Text('Ming')),
                      DropdownMenuItem(value: 'kong', child: Text('Kong')),
                    ],
                    onChanged: (value) => yuan = value ?? 'hanako',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: identityCtrl,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '身份设定 identity.md',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ishikiCtrl,
                    minLines: 6,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      labelText: '人格设定 ishiki.md',
                      border: OutlineInputBorder(),
                    ),
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
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    try {
      await ref
          .read(engineProvider)
          .agentManager
          .updateAgent(
            id,
            name: nameCtrl.text,
            yuan: yuan,
            identity: identityCtrl.text,
            ishiki: ishikiCtrl.text,
            avatarSourcePath: avatarCtrl.text,
            removeAvatar: removeAvatar,
          );
      ref.invalidate(agentListProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Agent 档案已保存')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  Future<void> _saveHeartbeatConfig(HeartbeatConfig next) async {
    final eng = ref.read(engineProvider);
    eng.heartbeatRuntime.writeConfig(next);
    if (next.enabled) {
      eng.heartbeatRuntime.start();
    } else {
      await eng.heartbeatRuntime.stop();
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('工作巡检配置已保存')));
    await _refresh();
  }

  Future<void> _editWorkspaceRoots() async {
    final current = _heartbeatConfig ?? const HeartbeatConfig();
    final ctrl = TextEditingController(text: current.workspaceRoots.join('\n'));
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('工作目录'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: ctrl,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '每行一个目录',
              border: OutlineInputBorder(),
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
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final roots = ctrl.text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    await _saveHeartbeatConfig(current.copyWith(workspaceRoots: roots));
  }

  Future<void> _setHeartbeatInterval(int minutes) async {
    final current = _heartbeatConfig ?? const HeartbeatConfig();
    await _saveHeartbeatConfig(current.copyWith(intervalMinutes: minutes));
  }

  Future<void> _toggleCronScheduler(bool enabled) async {
    final eng = ref.read(engineProvider);
    if (enabled) {
      eng.cronScheduler.start();
    } else {
      await eng.cronScheduler.stop();
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(enabled ? 'Cron 调度已启动' : 'Cron 调度已停止')),
    );
    await _refresh();
  }

  Future<void> _editBridgeSource(BridgeSourceConfig current) async {
    final agentIdCtrl = TextEditingController(text: current.agentId ?? '');
    final tokenCtrl = TextEditingController(
      text: current.credentials['token'] ?? '',
    );
    final appIdCtrl = TextEditingController(
      text: current.credentials['appId'] ?? current.credentials['appID'] ?? '',
    );
    final appSecretCtrl = TextEditingController(
      text: current.credentials['appSecret'] ?? '',
    );
    final verificationCtrl = TextEditingController(
      text: current.credentials['verificationToken'] ?? '',
    );
    final encryptCtrl = TextEditingController(
      text: current.credentials['encryptKey'] ?? '',
    );
    var enabled = current.enabled;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('配置 ${current.label}'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: agentIdCtrl,
                    decoration: const InputDecoration(
                      labelText: '目标 Agent ID（留空使用当前活动 Agent）',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (current.platform == 'telegram')
                    TextField(
                      controller: tokenCtrl,
                      decoration: const InputDecoration(labelText: 'Bot Token'),
                      obscureText: true,
                    ),
                  if (current.platform == 'feishu') ...[
                    TextField(
                      controller: appIdCtrl,
                      decoration: const InputDecoration(labelText: 'App ID'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: appSecretCtrl,
                      decoration: const InputDecoration(
                        labelText: 'App Secret',
                      ),
                      obscureText: true,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: verificationCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Verification Token（可选）',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: encryptCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Encrypt Key（可选）',
                      ),
                      obscureText: true,
                    ),
                  ],
                  if (current.platform == 'qq') ...[
                    TextField(
                      controller: appIdCtrl,
                      decoration: const InputDecoration(labelText: 'App ID'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: appSecretCtrl,
                      decoration: const InputDecoration(
                        labelText: 'App Secret 或 Token',
                      ),
                      obscureText: true,
                    ),
                  ],
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: enabled,
                    title: const Text('启用'),
                    onChanged: (value) =>
                        setDialogState(() => enabled = value ?? false),
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
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;

    final credentials = <String, String>{};
    switch (current.platform) {
      case 'telegram':
        credentials['token'] = tokenCtrl.text;
      case 'feishu':
        credentials
          ..['appId'] = appIdCtrl.text
          ..['appSecret'] = appSecretCtrl.text
          ..['verificationToken'] = verificationCtrl.text
          ..['encryptKey'] = encryptCtrl.text;
      case 'qq':
        credentials
          ..['appID'] = appIdCtrl.text
          ..['appSecret'] = appSecretCtrl.text;
    }
    await ref
        .read(engineProvider)
        .bridgeSourceManager
        .save(
          BridgeSourceConfig(
            platform: current.platform,
            enabled: enabled,
            agentId: agentIdCtrl.text,
            credentials: credentials,
          ),
        );
    await _refresh();
  }

  Future<void> _deleteBridgeSource(BridgeSourceConfig source) async {
    await ref.read(engineProvider).bridgeSourceManager.delete(source.platform);
    await _refresh();
  }

  Future<void> _toggleBrowserTool(bool enabled) async {
    ref.read(engineProvider).browserManager.setEnabled(enabled);
    await _refresh();
  }

  Future<void> _toggleDmAutoReply(bool enabled) async {
    final eng = ref.read(engineProvider);
    eng.collaborationManager.saveSettings(
      eng.collaborationManager.readSettings().copyWith(dmAutoReply: enabled),
    );
    await _refresh();
  }

  Future<void> _toggleChannelAutoTriage(bool enabled) async {
    final eng = ref.read(engineProvider);
    eng.collaborationManager.saveSettings(
      eng.collaborationManager.readSettings().copyWith(
        channelAutoTriage: enabled,
      ),
    );
    await _refresh();
  }

  Future<void> _toggleCronJob(String id, bool enabled) async {
    ref.read(engineProvider).cronStore.toggleJob(id, enabled: enabled);
    await _refresh();
  }

  Future<void> _runCronNow(String id) async {
    try {
      final run = await ref.read(engineProvider).cronScheduler.runNow(id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('立即执行完成：${run.status}')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('立即执行失败：$e')));
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
                      _buildWorkSection(),
                      const SizedBox(height: 24),
                      _buildBridgeSection(),
                      const SizedBox(height: 24),
                      _buildBrowserSection(),
                      const SizedBox(height: 24),
                      _buildCollaborationSection(),
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
                          onPressed: _accountBusy ? null : _verifyStoryRecovery,
                          icon: const Icon(Icons.fact_check_outlined, size: 18),
                          label: const Text('尝试验证'),
                        ),
                      if (_identityReady)
                        OutlinedButton.icon(
                          onPressed: _accountBusy ? null : _rotatePubkey,
                          icon: const Icon(Icons.key_outlined, size: 18),
                          label: const Text('密钥轮换'),
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
                leading: _AgentAvatar(
                  avatarPath: _textValue(a['avatarPath']),
                  isPrimary: a['isPrimary'] == true,
                ),
                title: Text(a['name'] as String),
                subtitle: Text(
                  [
                    '${a['id']} · yuan=${a['yuan']}',
                    if (_textValue(a['identity']) != null)
                      _textValue(a['identity'])!
                          .split('\n')
                          .firstWhere(
                            (line) => line.trim().isNotEmpty,
                            orElse: () => '',
                          )
                          .trim(),
                  ].where((line) => line.isNotEmpty).join('\n'),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    final eng = ref.read(engineProvider);
                    if (v == 'edit') {
                      await _editAgentProfile(a);
                    } else if (v == 'switch') {
                      final id = a['id'] as String;
                      await eng.agentManager.switchAgent(id);
                      eng.config.retarget(id);
                      ref.read(activeAgentIdProvider.notifier).state = id;
                      ref.invalidate(agentListProvider);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已切换到 ${a['name']}')),
                      );
                    } else if (v == 'primary') {
                      eng.preferences.savePrimaryAgent(a['id'] as String);
                      ref.invalidate(agentListProvider);
                      await _refresh();
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
                    PopupMenuItem(value: 'edit', child: Text('编辑档案')),
                    PopupMenuItem(value: 'switch', child: Text('切换为活动')),
                    PopupMenuItem(value: 'primary', child: Text('设为主 Agent')),
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
            const Divider(height: 0),
            _buildToolCapabilitiesTile(),
          ],
        ),
      ),
    );
  }

  Widget _buildToolCapabilitiesTile() {
    final names = LocalToolRegistry.buildTools()
        .map((tool) => tool.name)
        .toList(growable: false);
    return ExpansionTile(
      leading: const Icon(Icons.extension_outlined),
      title: const Text('工具能力'),
      subtitle: Text('${names.length} 个已注册工具'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final name in names)
                Chip(
                  label: Text(name),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBridgeSection() {
    return _Section(
      title: '消息来源',
      subtitle: 'Telegram、飞书/Lark、QQ 外部入口。',
      child: Card(
        child: Column(
          children: [
            for (final source in _bridgeSources)
              ListTile(
                leading: Icon(_bridgeIcon(source.platform)),
                title: Text(source.label),
                subtitle: Text(_bridgeSubtitle(source)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: source.enabled,
                      onChanged: (value) async {
                        await ref
                            .read(engineProvider)
                            .bridgeSourceManager
                            .setEnabled(source.platform, value);
                        await _refresh();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: '编辑',
                      onPressed: () => _editBridgeSource(source),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: '删除配置',
                      onPressed: source.configured || source.enabled
                          ? () => _deleteBridgeSource(source)
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _bridgeSubtitle(BridgeSourceConfig source) {
    final status = _bridgeStatuses[source.platform];
    final parts = <String>[
      source.configured ? '已配置' : '未配置',
      source.enabled ? '已启用' : '已禁用',
      '状态：${_bridgeStateLabel(status?.state ?? "disabled")}',
      if (source.agentId != null && source.agentId!.isNotEmpty)
        'agent=${source.agentId}',
      if (status?.error != null) status!.error!,
    ];
    return parts.join(' · ');
  }

  String _bridgeStateLabel(String state) => switch (state) {
    'connected' => '已连接',
    'error' => '错误',
    'disabled' => '已停止',
    _ => '未连接',
  };

  IconData _bridgeIcon(String platform) => switch (platform) {
    'telegram' => Icons.send_outlined,
    'feishu' || 'lark' => Icons.business_center_outlined,
    'qq' => Icons.chat_bubble_outline,
    _ => Icons.forum_outlined,
  };

  Widget _buildBrowserSection() {
    final status = _browserStatus;
    final enabled = status?.enabled ?? true;
    final running = status?.running ?? false;
    final title = status?.title;
    final url = status?.url;
    return _Section(
      title: 'Browser',
      subtitle: '网页工具状态与权限开关。',
      child: Card(
        child: Column(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.public_outlined),
              title: const Text('允许 Agent 使用 Browser 工具'),
              subtitle: Text(running ? '运行中' : '未运行'),
              value: enabled,
              onChanged: _toggleBrowserTool,
            ),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.travel_explore_outlined),
              title: Text(title == null || title.isEmpty ? '当前没有页面' : title),
              subtitle: Text(url == null || url.isEmpty ? '未打开 URL' : url),
              trailing: IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: '刷新状态',
                onPressed: _refresh,
              ),
            ),
            if (status?.lastError != null)
              ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('最近错误'),
                subtitle: Text(status!.lastError!),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollaborationSection() {
    final settings = _collaborationSettings ?? const CollaborationSettings();
    return _Section(
      title: '多 Agent 协作',
      subtitle: 'Delegate、DM 自动回复和频道 triage。',
      child: Card(
        child: Column(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.mark_chat_unread_outlined),
              title: const Text('DM 自动回复'),
              subtitle: const Text('关闭后只保留显式 message_agent / dm 工具调用'),
              value: settings.dmAutoReply,
              onChanged: _toggleDmAutoReply,
            ),
            const Divider(height: 0),
            SwitchListTile(
              secondary: const Icon(Icons.hub_outlined),
              title: const Text('Channel 自动 triage'),
              subtitle: Text('最大协作深度 ${settings.maxDepth}'),
              value: settings.channelAutoTriage,
              onChanged: _toggleChannelAutoTriage,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkSection() {
    final heartbeat = _heartbeatConfig ?? const HeartbeatConfig();
    final cronRunning = ref.read(engineProvider).cronScheduler.isRunning;
    final rootsLabel = heartbeat.workspaceRoots.isEmpty
        ? '未配置'
        : heartbeat.workspaceRoots.join('\n');
    return _Section(
      title: '工作',
      subtitle: '工作目录、巡检、Cron 和后台活动。',
      child: Card(
        child: Column(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.monitor_heart_outlined),
              title: const Text('Heartbeat 巡检'),
              subtitle: Text('每 ${heartbeat.intervalMinutes} 分钟扫描 jian.md'),
              value: heartbeat.enabled,
              onChanged: (value) =>
                  _saveHeartbeatConfig(heartbeat.copyWith(enabled: value)),
            ),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.folder_copy_outlined),
              title: const Text('工作目录'),
              subtitle: SelectableText(rootsLabel),
              trailing: Wrap(
                spacing: 8,
                children: [
                  if (heartbeat.workspaceRoots.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.folder_open),
                      tooltip: '打开第一个目录',
                      onPressed: () =>
                          _openPath(heartbeat.workspaceRoots.first),
                    ),
                  IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: '编辑工作目录',
                    onPressed: _editWorkspaceRoots,
                  ),
                ],
              ),
            ),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('巡检间隔'),
              subtitle: const Text('修改后立即保存'),
              trailing: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 5, label: Text('5 分')),
                  ButtonSegment(value: 17, label: Text('17 分')),
                  ButtonSegment(value: 30, label: Text('30 分')),
                ],
                selected: {5, 17, 30}.contains(heartbeat.intervalMinutes)
                    ? {heartbeat.intervalMinutes}
                    : <int>{},
                emptySelectionAllowed: true,
                onSelectionChanged: (values) {
                  if (values.isNotEmpty) _setHeartbeatInterval(values.first);
                },
              ),
            ),
            const Divider(height: 0),
            SwitchListTile(
              secondary: const Icon(Icons.schedule_outlined),
              title: const Text('Cron 调度'),
              subtitle: Text(
                _cronJobs.isEmpty ? '暂无定时任务' : '${_cronJobs.length} 个任务',
              ),
              value: cronRunning,
              onChanged: _toggleCronScheduler,
            ),
            if (_cronJobs.isEmpty)
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('Cron 任务为空'),
                subtitle: Text('Agent 可通过 cron 工具创建定时任务。'),
              )
            else
              for (final job in _cronJobs) _buildCronJobTile(job),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.history_outlined),
              title: const Text('最近活动'),
              subtitle: Text(
                _activities.isEmpty ? '暂无后台活动' : '${_activities.length} 条记录',
              ),
            ),
            if (_activities.isEmpty)
              const ListTile(
                leading: Icon(Icons.inbox_outlined),
                title: Text('暂无活动记录'),
                subtitle: Text('Heartbeat 或 Cron 执行后会出现在这里。'),
              )
            else
              for (final activity in _activities.take(8))
                _buildActivityTile(activity),
          ],
        ),
      ),
    );
  }

  Widget _buildCronJobTile(Map<String, dynamic> job) {
    final id = _textValue(job['id']) ?? '';
    final label = _textValue(job['label']) ?? id;
    final type = _textValue(job['type']) ?? '?';
    final enabled = job['enabled'] == true;
    final nextRun = _textValue(job['nextRunAt']) ?? '无';
    final lastRun = job['lastRun'] is Map
        ? job['lastRun'] as Map<String, dynamic>
        : null;
    final lastStatus = _textValue(lastRun?['status']);
    final lastError = _textValue(lastRun?['error']);
    return ListTile(
      leading: Icon(enabled ? Icons.play_circle_outline : Icons.pause_circle),
      title: Text(label),
      subtitle: Text(
        [
          '$id · $type · 下次 $nextRun',
          if (lastStatus != null) '最近：$lastStatus',
          if (lastError != null) '错误：$lastError',
        ].join('\n'),
      ),
      isThreeLine: lastStatus != null || lastError != null,
      trailing: Wrap(
        spacing: 4,
        children: [
          IconButton(
            icon: Icon(enabled ? Icons.toggle_on : Icons.toggle_off),
            tooltip: enabled ? '禁用' : '启用',
            onPressed: id.isEmpty ? null : () => _toggleCronJob(id, !enabled),
          ),
          IconButton(
            icon: const Icon(Icons.flash_on_outlined),
            tooltip: '立即执行',
            onPressed: id.isEmpty ? null : () => _runCronNow(id),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityTile(Map<String, dynamic> activity) {
    final status = _textValue(activity['status']) ?? '?';
    final type = _textValue(activity['type']) ?? 'activity';
    final summary = _textValue(activity['summary']) ?? type;
    final target = _textValue(activity['targetPath']);
    final error = _textValue(activity['error']);
    final color = switch (status) {
      'success' || 'done' => Colors.green,
      'error' => Theme.of(context).colorScheme.error,
      'skipped' => Theme.of(context).colorScheme.outline,
      _ => Theme.of(context).colorScheme.primary,
    };
    return ListTile(
      dense: true,
      leading: Icon(Icons.circle, color: color, size: 12),
      title: Text(summary),
      subtitle: Text(
        ['$type · $status', ?target, if (error != null) '错误：$error'].join('\n'),
      ),
      isThreeLine: target != null || error != null,
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

int _memoryAccuracyScore(LoginOutcome outcome) {
  if (!outcome.success) return 0;
  final distance = outcome.hammingDistance.clamp(0, 12).toInt();
  var score = outcome.usedLlm ? 88 : 100;
  score -= distance * 7;
  if (outcome.usedLlm && distance == 0) {
    score -= 3;
  }
  if (outcome.elapsedMs > 15000) {
    score -= 3;
  } else if (outcome.elapsedMs > 5000) {
    score -= 1;
  }
  return score.clamp(20, 100).toInt();
}

String _memoryScoreLabel(int score) {
  if (score >= 95) return '完美复述';
  if (score >= 85) return '稳定记忆';
  if (score >= 70) return '轻微偏差';
  if (score >= 50) return '需要练习';
  if (score > 0) return '遗忘边缘';
  return '未通过';
}

Color _memoryScoreColor(int score, ColorScheme c) {
  if (score >= 90) return Colors.green.shade600;
  if (score >= 75) return Colors.teal.shade600;
  if (score >= 55) return Colors.orange.shade700;
  return c.error;
}

class _StoryVerificationResult {
  const _StoryVerificationResult({
    required this.success,
    required this.message,
    required this.attempted,
    required this.elapsedMs,
    required this.hammingDistance,
    required this.usedLlm,
    required this.score,
    required this.candidateMatrix,
    required this.candidatesPerColumn,
    required this.anchors,
    this.publicKeyHash,
  });

  final bool success;
  final String message;
  final int attempted;
  final int elapsedMs;
  final int hammingDistance;
  final bool usedLlm;
  final int score;
  final List<List<int>> candidateMatrix;
  final int candidatesPerColumn;
  final List<String> anchors;
  final String? publicKeyHash;
}

class _PubkeyRotationOutcome {
  const _PubkeyRotationOutcome({
    required this.registration,
    required this.result,
    required this.localPersisted,
    this.warning,
  });

  final IdentityRegistration registration;
  final PubkeyRotationResult result;
  final bool localPersisted;
  final String? warning;
}

class _PubkeyRotationDialog extends StatefulWidget {
  const _PubkeyRotationDialog({
    required this.username,
    required this.onSendCode,
    required this.onRotate,
  });

  final String username;
  final Future<PubkeyRotationEmailChallenge> Function() onSendCode;
  final Future<_PubkeyRotationOutcome> Function(String challengeId, String code)
  onRotate;

  @override
  State<_PubkeyRotationDialog> createState() => _PubkeyRotationDialogState();
}

class _PubkeyRotationDialogState extends State<_PubkeyRotationDialog> {
  final _codeController = TextEditingController();
  PubkeyRotationEmailChallenge? _challenge;
  _PubkeyRotationOutcome? _outcome;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final challenge = await widget.onSendCode();
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _codeController.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rotate() async {
    final challenge = _challenge;
    final code = _codeController.text.trim();
    if (_busy || challenge == null || code.length < 6) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await widget.onRotate(challenge.challengeId, code);
      if (!mounted) return;
      setState(() => _outcome = outcome);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    return AlertDialog(
      title: const Text('密钥轮换'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: outcome == null
              ? _buildForm(context)
              : _buildResult(context, outcome),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(outcome == null ? '关闭' : '完成'),
        ),
        if (outcome == null) ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : _sendCode,
            icon: _busy && _challenge == null
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.mail_outline, size: 18),
            label: Text(_challenge == null ? '发送验证码' : '重新发送'),
          ),
          FilledButton.icon(
            onPressed:
                _busy ||
                    _challenge == null ||
                    _codeController.text.trim().length < 6
                ? null
                : _rotate,
            icon: _busy && _challenge != null
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.key_outlined, size: 18),
            label: const Text('确认轮换'),
          ),
        ] else ...[
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: outcome.registration.words.join(' ')),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('新助记词已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: const Text('复制助记词'),
          ),
          if (outcome.registration.story.trim().isNotEmpty)
            FilledButton.icon(
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(text: outcome.registration.story.trim()),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('新故事已复制'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('复制故事'),
            ),
        ],
      ],
      icon: Icon(Icons.key_outlined, color: c.primary),
    );
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);
    final challenge = _challenge;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('账号：${widget.username}', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        Text(
          '轮换会生成新的 12 个名词和记忆故事；旧密钥会在云端失效。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeController,
          enabled: challenge != null && !_busy,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          decoration: InputDecoration(
            labelText: '邮箱验证码',
            helperText: challenge == null
                ? '先发送验证码'
                : '已发送至 ${challenge.delivery}',
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }

  Widget _buildResult(BuildContext context, _PubkeyRotationOutcome outcome) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final registration = outcome.registration;
    final story = registration.story.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: outcome.localPersisted
                ? c.primaryContainer.withValues(alpha: 0.35)
                : c.errorContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: outcome.localPersisted ? c.primary : c.error,
            ),
          ),
          child: Text(
            outcome.localPersisted ? '轮换完成：本机身份已切换到新密钥。' : '云端已完成轮换，但本机写入未完成。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: outcome.localPersisted ? c.onPrimaryContainer : c.error,
            ),
          ),
        ),
        if (outcome.warning != null) ...[
          const SizedBox(height: 10),
          Text(
            outcome.warning!,
            style: theme.textTheme.bodySmall?.copyWith(color: c.error),
          ),
        ],
        const SizedBox(height: 16),
        if (story.isNotEmpty)
          SelectableText(story, style: theme.textTheme.bodyLarge)
        else
          Text(
            '新故事生成暂不可用，可以直接使用下面的 12 个名词。',
            style: theme.textTheme.bodyMedium,
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
        const SizedBox(height: 12),
        Text(
          '新指纹：${_shortHash(outcome.result.newPubkeyHash)}',
          style: theme.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _StoryVerificationDialog extends StatefulWidget {
  const _StoryVerificationDialog({required this.onVerify});

  final Future<_StoryVerificationResult> Function(
    String story,
    void Function(StoryRecoveryProgress progress) onProgress,
  )
  onVerify;

  @override
  State<_StoryVerificationDialog> createState() =>
      _StoryVerificationDialogState();
}

class _StoryVerificationDialogState extends State<_StoryVerificationDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  _StoryVerificationResult? _result;
  String? _error;
  StoryRecoveryProgressStage? _phase;
  int? _attempted;
  int? _elapsedMs;
  int? _distance;
  int? _combinationId;
  List<int> _candidateRanks = const [];
  List<int> _wordIds = const [];
  List<int> _activePositions = const [];
  List<List<int>> _liveMatrix = const [];
  List<String> _liveAnchors = const [];
  int _liveCandidatesPerColumn = 0;
  bool _liveUsedLlm = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final story = _controller.text.trim();
    if (_busy || story.isEmpty) return;
    setState(() {
      _busy = true;
      _result = null;
      _error = null;
      _phase = null;
      _attempted = null;
      _elapsedMs = null;
      _distance = null;
      _combinationId = null;
      _candidateRanks = const [];
      _wordIds = const [];
      _activePositions = const [];
      _liveMatrix = const [];
      _liveAnchors = const [];
      _liveCandidatesPerColumn = 0;
      _liveUsedLlm = false;
    });
    try {
      final result = await widget.onVerify(story, (progress) {
        if (!mounted) return;
        setState(() {
          _phase = progress.stage;
          switch (progress.stage) {
            case StoryRecoveryProgressStage.aiSemanticAnalysis:
              break;
            case StoryRecoveryProgressStage.matrixReady:
              _liveMatrix = progress.columns;
              _liveAnchors = progress.anchors;
              _liveCandidatesPerColumn = progress.candidatesPerColumn;
              _liveUsedLlm = progress.usedLlm;
              break;
            case StoryRecoveryProgressStage.matrixRecovery:
              _attempted = progress.attempted;
              _elapsedMs = progress.elapsedMs;
              _distance = progress.currentHammingDistance;
              _combinationId = progress.combinationId;
              _candidateRanks = progress.candidateRanks;
              _wordIds = progress.wordIds;
              _activePositions = progress.activePositions;
              break;
          }
        });
      });
      if (!mounted) return;
      setState(() {
        _result = result;
        _attempted = result.attempted;
        _elapsedMs = result.elapsedMs;
        _distance = result.hammingDistance;
        _combinationId = result.attempted;
        _candidateRanks = const [];
        _wordIds = const [];
        _activePositions = const [];
        _liveMatrix = result.candidateMatrix;
        _liveAnchors = result.anchors;
        _liveCandidatesPerColumn = result.candidatesPerColumn;
        _liveUsedLlm = result.usedLlm;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final result = _result;
    final canVerify = !_busy && _controller.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('尝试验证故事'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                minLines: 5,
                maxLines: 9,
                enabled: !_busy,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '记忆故事或 12 个名词',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              if (_busy && _phase != null) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 10),
                Text(
                  _progressText(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.onSurfaceVariant,
                  ),
                ),
                if (_liveAnchors.isNotEmpty || _liveMatrix.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _CandidateMatrixTable(
                    matrix: _liveMatrix,
                    anchors: _liveAnchors,
                    candidatesPerColumn: _liveCandidatesPerColumn,
                    usedLlm: _liveUsedLlm,
                    hammingDistance: _distance ?? 0,
                    attempted: _attempted ?? 0,
                    elapsedMs: _elapsedMs ?? 0,
                    combinationId: _combinationId,
                    candidateRanks: _candidateRanks,
                    wordIds: _wordIds,
                    activePositions: _activePositions,
                  ),
                ],
              ],
              if (result != null) ...[
                const SizedBox(height: 16),
                _VerificationStatusBox(
                  success: result.success,
                  message: result.message,
                  attempted: result.attempted,
                  elapsedMs: result.elapsedMs,
                  hammingDistance: result.hammingDistance,
                  usedLlm: result.usedLlm,
                  score: result.score,
                  publicKeyHash: result.publicKeyHash,
                ),
                if (result.candidateMatrix.isNotEmpty ||
                    result.anchors.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _CandidateMatrixTable(
                    matrix: result.candidateMatrix,
                    anchors: result.anchors,
                    candidatesPerColumn: result.candidatesPerColumn,
                    usedLlm: result.usedLlm,
                    hammingDistance: result.hammingDistance,
                    attempted: result.attempted,
                    elapsedMs: result.elapsedMs,
                  ),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                _VerificationStatusBox(
                  success: false,
                  message: '验证失败：$_error',
                  attempted: _attempted ?? 0,
                  elapsedMs: _elapsedMs ?? 0,
                  hammingDistance: _distance ?? 0,
                  usedLlm: false,
                  score: 0,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: canVerify ? _verify : null,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.fact_check_outlined, size: 18),
          label: const Text('开始验证'),
        ),
      ],
    );
  }

  String _progressText() {
    final phase = _phase;
    if (phase == StoryRecoveryProgressStage.aiSemanticAnalysis) {
      return '正在进行AI语义分析';
    }
    if (phase == StoryRecoveryProgressStage.matrixReady) {
      final completedRows = _liveMatrix.where((row) => row.isNotEmpty).length;
      if (completedRows < _liveAnchors.length) {
        return '已提取故事锚点，正在并发生成候选词 · $completedRows/${_liveAnchors.length}';
      }
      return '候选矩阵已生成，准备开始矩阵恢复';
    }
    final parts = <String>['正在恢复'];
    final attempted = _attempted;
    final elapsedMs = _elapsedMs;
    final distance = _distance;
    if (attempted != null) parts.add('已尝试 $attempted 次');
    if (_combinationId != null) parts.add('组合 #$_combinationId');
    if (distance != null) parts.add('距离 $distance');
    if (elapsedMs != null) {
      parts.add('耗时 ${(elapsedMs / 1000).toStringAsFixed(1)} 秒');
      if (attempted != null) {
        parts.add('吞吐 ${_formatAttemptRate(attempted, elapsedMs)}');
      }
    }
    return parts.join(' · ');
  }
}

class _CandidateMatrixTable extends StatelessWidget {
  const _CandidateMatrixTable({
    required this.matrix,
    required this.anchors,
    required this.candidatesPerColumn,
    required this.usedLlm,
    required this.hammingDistance,
    required this.attempted,
    required this.elapsedMs,
    this.combinationId,
    this.candidateRanks = const [],
    this.wordIds = const [],
    this.activePositions = const [],
  });

  final List<List<int>> matrix;
  final List<String> anchors;
  final int candidatesPerColumn;
  final bool usedLlm;
  final int hammingDistance;
  final int attempted;
  final int elapsedMs;
  final int? combinationId;
  final List<int> candidateRanks;
  final List<int> wordIds;
  final List<int> activePositions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final k = candidatesPerColumn > 0
        ? candidatesPerColumn
        : (matrix.isEmpty ? 0 : matrix.first.length);
    final rows = matrix.length > anchors.length
        ? matrix.length
        : anchors.length;
    final theoretical = _boundedSearchSpace(rows, k, hammingDistance);
    final fullSpace = _boundedSearchSpace(rows, k, rows);
    final rowOrder = _matrixRowOrder(rows, candidateRanks, activePositions);
    final rankOrder = _matrixRankOrder(k, candidateRanks, rowOrder);
    final activeRows = rowOrder
        .where(
          (row) => _isActiveMatrixRow(row, candidateRanks, activePositions),
        )
        .map((row) => row + 1)
        .take(4)
        .join('、');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: c.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            usedLlm ? 'LLM 语义候选矩阵' : '确定性候选矩阵',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [
              '$rows × $k',
              'D≤$hammingDistance 理论 $theoretical',
              '全矩阵 $fullSpace',
              '实际 $attempted',
              if (combinationId != null) '组合 #$combinationId',
              if (elapsedMs > 0)
                '吞吐 ${_formatAttemptRate(attempted, elapsedMs)}',
              if (activeRows.isNotEmpty) '活跃 $activeRows',
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: c.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(color: c.outlineVariant),
              children: [
                TableRow(
                  decoration: BoxDecoration(color: c.surfaceContainerHighest),
                  children: [
                    _MatrixCell(
                      text: '#',
                      style: theme.textTheme.labelSmall,
                      isHeader: true,
                    ),
                    if (anchors.isNotEmpty)
                      _MatrixCell(
                        text: '锚点',
                        style: theme.textTheme.labelSmall,
                        isHeader: true,
                      ),
                    for (final rank in rankOrder)
                      _MatrixCell(
                        text: '候选 ${rank + 1}',
                        style: theme.textTheme.labelSmall,
                        isHeader: true,
                        isActive: _rankIsActive(rank, candidateRanks),
                      ),
                  ],
                ),
                for (final row in rowOrder)
                  TableRow(
                    children: [
                      _MatrixCell(
                        text: '${row + 1}',
                        style: theme.textTheme.bodySmall,
                        isActive: _isActiveMatrixRow(
                          row,
                          candidateRanks,
                          activePositions,
                        ),
                      ),
                      if (anchors.isNotEmpty)
                        _MatrixCell(
                          text: row < anchors.length ? anchors[row] : '-',
                          style: theme.textTheme.bodySmall,
                          isActive: _isActiveMatrixRow(
                            row,
                            candidateRanks,
                            activePositions,
                          ),
                        ),
                      for (final rank in rankOrder)
                        _MatrixCell(
                          text: row < matrix.length
                              ? _candidateLabel(matrix[row], rank)
                              : '-',
                          style: theme.textTheme.bodySmall,
                          isSelected: _isSelectedCandidate(
                            row: row,
                            rank: rank,
                            matrix: matrix,
                            candidateRanks: candidateRanks,
                            wordIds: wordIds,
                          ),
                          isActive: _isActiveMatrixRow(
                            row,
                            candidateRanks,
                            activePositions,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MatrixCell extends StatelessWidget {
  const _MatrixCell({
    required this.text,
    this.style,
    this.isHeader = false,
    this.isSelected = false,
    this.isActive = false,
  });

  final String text;
  final TextStyle? style;
  final bool isHeader;
  final bool isSelected;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final color = isSelected
        ? (isActive ? c.primaryContainer : c.secondaryContainer)
        : (isActive ? c.surfaceContainerHighest : null);
    final foreground = isSelected
        ? (isActive ? c.onPrimaryContainer : c.onSecondaryContainer)
        : null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        border: isSelected ? Border.all(color: c.primary, width: 1.2) : null,
      ),
      child: SelectableText(
        text,
        style: style?.copyWith(
          fontWeight: isHeader ? FontWeight.w700 : style?.fontWeight,
          fontFamily: isHeader ? null : 'monospace',
          color: foreground,
        ),
      ),
    );
  }
}

class _VerificationStatusBox extends StatelessWidget {
  const _VerificationStatusBox({
    required this.success,
    required this.message,
    required this.attempted,
    required this.elapsedMs,
    required this.hammingDistance,
    required this.usedLlm,
    required this.score,
    this.publicKeyHash,
  });

  final bool success;
  final String message;
  final int attempted;
  final int elapsedMs;
  final int hammingDistance;
  final bool usedLlm;
  final int score;
  final String? publicKeyHash;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final color = _memoryScoreColor(score, c);
    final hash = publicKeyHash;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.32)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '记忆准确度',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: c.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                '$score',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '/100',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: c.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: score / 100,
              minHeight: 10,
              color: color,
              backgroundColor: color.withValues(alpha: 0.14),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                success ? Icons.verified_outlined : Icons.error_outline,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            [
              _memoryScoreLabel(score),
              usedLlm ? 'LLM 语义恢复' : '确定性恢复',
              '距离 $hammingDistance',
              '尝试 $attempted 次',
              '${(elapsedMs / 1000).toStringAsFixed(1)} 秒',
              if (elapsedMs > 0) _formatAttemptRate(attempted, elapsedMs),
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: c.onSurfaceVariant,
            ),
          ),
          if (hash != null) ...[
            const SizedBox(height: 4),
            Text(
              '指纹：${_shortHash(hash)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: c.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
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

class _AgentAvatar extends StatelessWidget {
  const _AgentAvatar({required this.avatarPath, required this.isPrimary});

  final String? avatarPath;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final path = avatarPath;
    final file = path == null ? null : File(path);
    final image = file != null && file.existsSync() ? FileImage(file) : null;
    return CircleAvatar(
      radius: 20,
      backgroundImage: image,
      child: image == null
          ? Icon(isPrimary ? Icons.star : Icons.person_outline, size: 20)
          : null,
    );
  }
}

String _candidateLabel(List<int> row, int rank) {
  if (rank >= row.length) return '-';
  final id = row[rank];
  final word = wordById(id) ?? '?';
  return '$id $word';
}

List<int> _matrixRowOrder(
  int rows,
  List<int> candidateRanks,
  List<int> activePositions,
) {
  final seen = <int>{};
  final ordered = <int>[];

  void add(int row) {
    if (row < 0 || row >= rows || !seen.add(row)) return;
    ordered.add(row);
  }

  for (final row in activePositions) {
    add(row);
  }
  if (ordered.isEmpty) {
    for (var row = 0; row < candidateRanks.length && row < rows; row++) {
      if (candidateRanks[row] > 0) add(row);
    }
  }
  for (var row = 0; row < rows; row++) {
    add(row);
  }
  return ordered;
}

List<int> _matrixRankOrder(
  int k,
  List<int> candidateRanks,
  List<int> rowOrder,
) {
  final seen = <int>{};
  final ordered = <int>[];

  void add(int rank) {
    if (rank < 0 || rank >= k || !seen.add(rank)) return;
    ordered.add(rank);
  }

  for (final row in rowOrder) {
    if (row >= 0 && row < candidateRanks.length && candidateRanks[row] > 0) {
      add(candidateRanks[row]);
    }
  }
  for (var rank = 0; rank < k; rank++) {
    add(rank);
  }
  return ordered;
}

bool _isActiveMatrixRow(
  int row,
  List<int> candidateRanks,
  List<int> activePositions,
) {
  if (activePositions.contains(row)) return true;
  return row >= 0 && row < candidateRanks.length && candidateRanks[row] > 0;
}

bool _rankIsActive(int rank, List<int> candidateRanks) {
  return rank > 0 && candidateRanks.contains(rank);
}

bool _isSelectedCandidate({
  required int row,
  required int rank,
  required List<List<int>> matrix,
  required List<int> candidateRanks,
  required List<int> wordIds,
}) {
  if (row < 0 ||
      row >= matrix.length ||
      rank < 0 ||
      rank >= matrix[row].length) {
    return false;
  }
  if (row < candidateRanks.length) {
    return candidateRanks[row] == rank;
  }
  if (row < wordIds.length) {
    return matrix[row][rank] == wordIds[row];
  }
  return false;
}

String _formatAttemptRate(int attempted, int elapsedMs) {
  if (attempted <= 0 || elapsedMs <= 0) return '0 次/秒';
  final rate = attempted * 1000 / elapsedMs;
  if (rate >= 100000000) {
    return '${(rate / 100000000).toStringAsFixed(2)} 亿次/秒';
  }
  if (rate >= 10000) {
    return '${(rate / 10000).toStringAsFixed(1)} 万次/秒';
  }
  if (rate >= 1000) {
    return '${rate.toStringAsFixed(0)} 次/秒';
  }
  return '${rate.toStringAsFixed(1)} 次/秒';
}

int _boundedSearchSpace(int rows, int k, int maxDistance) {
  if (rows <= 0 || k <= 0) return 0;
  final limit = maxDistance.clamp(0, rows).toInt();
  var total = 0;
  for (var d = 0; d <= limit; d++) {
    total += _binom(rows, d) * _pow(k - 1, d);
  }
  return total;
}

int _binom(int n, int k) {
  if (k < 0 || k > n) return 0;
  if (k == 0 || k == n) return 1;
  var result = 1;
  final kk = k > n - k ? n - k : k;
  for (var i = 0; i < kk; i++) {
    result = result * (n - i) ~/ (i + 1);
  }
  return result;
}

int _pow(int base, int exp) {
  var result = 1;
  for (var i = 0; i < exp; i++) {
    result *= base;
  }
  return result;
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
