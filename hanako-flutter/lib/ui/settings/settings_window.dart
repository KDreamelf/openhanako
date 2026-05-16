import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/protocol_login_service.dart';
import '../../app/providers.dart';
import '../../core/browser_manager.dart';
import '../../core/bridge_source_manager.dart';
import '../../core/heartbeat_runtime.dart';
import '../../experience/experience.dart';
import '../../identity/identity.dart';
import '../../local_tools/local_tools.dart';
import '../../windows_ops/windows_ops.dart';
import '../onboarding/onboarding_page.dart';
import '../widgets/recovery_matrix_table.dart';
import '../widgets/status_cluster.dart';

/// SharedPreferences key（与主窗口启动读取共用）。
const String kPrefThemeMode = 'hanako.theme.mode';
const String kPrefFontScale = 'hanako.theme.fontScale';
const List<String> _codexStandardToolNames = [
  'exec_command',
  'write_stdin',
  'apply_patch',
  'request_user_input',
  'request_permissions',
  'view_image',
  'tool_search',
  'update_plan',
  'spawn_agent',
  'send_message',
  'followup_task',
  'wait_agent',
  'close_agent',
  'list_agents',
  'get_goal',
  'create_goal',
  'update_goal',
];

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
  ExperienceDhtClientConfig? _dhtClientConfig;
  List<ExperienceDhtNode> _publicDhtNodes = const [];
  Map<String, String>? _paths;
  Map<String, dynamic>? _runtime;
  HeartbeatConfig? _heartbeatConfig;
  List<Map<String, dynamic>> _cronJobs = const [];
  List<Map<String, dynamic>> _activities = const [];
  List<ExperienceListItem> _experienceItems = const [];
  List<BridgeSourceConfig> _bridgeSources = const [];
  Map<String, BridgeSourceStatus> _bridgeStatuses = const {};
  BrowserStatus? _browserStatus;
  String? _experienceRedactingId;
  String? _experienceRegeneratingId;
  String? _experienceSyncingId;
  String? _experienceSubmittingId;
  double? _experienceSubmitProgress;
  String? _experienceSubmitProgressText;
  String? _dhtError;
  bool _hasSavedIdentity = false;
  bool _identityReady = false;
  bool _accountBusy = false;
  bool _userPowBusy = false;
  String? _identityPublicKeyHash;
  UserPowStatus? _userPowStatus;
  String? _userPowError;
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

  Future<void> _showSettingsError(String title, Object error) async {
    if (!mounted) return;
    final details = _settingsErrorDetails(error);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 640,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(details.summary),
              if (details.body.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 280),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.6),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      details.body,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: '${details.summary}\n${details.body}'),
              );
            },
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: const Text('复制详情'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSettingsNotice(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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

  String _codexPermissionMode() {
    final codex = _stringKeyMap(_prefs?['codex']);
    final raw =
        (codex['permission_mode'] ??
                codex['permissionMode'] ??
                codex['permissions'])
            ?.toString()
            .trim()
            .toLowerCase();
    return switch (raw) {
      'auto_approve' || 'autoapprove' || 'full' || 'always' => 'auto_approve',
      'deny' || 'never' => 'deny',
      _ => 'prompt',
    };
  }

  Future<void> _setCodexPermissionMode(String mode) async {
    final eng = ref.read(engineProvider);
    final prefs = eng.preferences.getPreferences();
    final codex = _stringKeyMap(prefs['codex']);
    codex['permission_mode'] = mode;
    prefs['codex'] = codex;
    eng.preferences.savePreferences(prefs);
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Codex 权限模式已更新')));
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
      final experienceItems = await ExperienceStore(
        agentDir: eng.home.agentDir(eng.config.agentId),
      ).list();
      final dhtConfig = ExperienceDhtClientConfig.fromJson(
        _stringKeyMap(_stringKeyMap(cfg['experience'])['dht_client']),
      );
      List<ExperienceDhtNode> publicDhtNodes = const [];
      String? dhtError;
      try {
        publicDhtNodes = await ExperienceNetworkManagerClient()
            .fetchPublicDhtNodes();
      } catch (e) {
        dhtError = '$e';
      }
      final bridgeSources = eng.bridgeSourceManager.listSources();
      final bridgeStatuses = eng.bridgeSourceManager.statuses();
      final browserStatus = eng.browserManager.status();
      final identity = repo.current;
      final authConfig = _stringKeyMap(cfg['auth']);
      final userConfig = _stringKeyMap(cfg['user']);
      final currentPubkeyHash =
          identity?.publicKeyHash ?? _textValue(authConfig['pubkey_hash']);
      UserPowStatus? userPowStatus;
      String? userPowError;
      if (currentPubkeyHash != null) {
        try {
          userPowStatus = await eng.backendClient.fetchUserPowStatus(
            pubkeyHash: currentPubkeyHash,
          );
        } catch (e) {
          userPowError = '$e';
        }
      }
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
        _authConfig = authConfig;
        _userConfig = userConfig;
        _dhtClientConfig = dhtConfig;
        _publicDhtNodes = publicDhtNodes;
        _dhtError = dhtError;
        _heartbeatConfig = heartbeatConfig;
        _cronJobs = cronJobs;
        _activities = activities;
        _experienceItems = experienceItems;
        _bridgeSources = bridgeSources;
        _bridgeStatuses = bridgeStatuses;
        _browserStatus = browserStatus;
        _hasSavedIdentity = hasSavedIdentity;
        _identityReady = identity != null;
        _identityPublicKeyHash = identity?.publicKeyHash;
        _userPowStatus = userPowStatus;
        _userPowError = userPowError;
        _paths = paths;
        _runtime = runtime;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  void _refreshAll() {
    ref.invalidate(experienceNetworkStatusProvider);
    ref.invalidate(windowsOpsStatusProvider);
    unawaited(_refresh());
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
      await _showSettingsError('解锁失败', e);
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
      await _showSettingsError('同步失败', e);
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _completeUserPow() async {
    if (_accountBusy || _userPowBusy) return;
    final progressNotifier = ValueNotifier<UserPowProgress>(
      const UserPowProgress(
        stage: UserPowProgressStage.challenge,
        message: '准备发起账号工作量证明',
        completed: 0,
        total: 1,
        fraction: 0,
      ),
    );
    var dialogOpen = true;
    BuildContext? dialogContext;
    Object? deferredError;
    setState(() {
      _accountBusy = true;
      _userPowBusy = true;
    });
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          dialogContext = context;
          return _UserPowProgressDialog(progress: progressNotifier);
        },
      ).whenComplete(() => dialogOpen = false),
    );
    await Future<void>.delayed(Duration.zero);
    try {
      final eng = ref.read(engineProvider);
      final identity = await _loadIdentityForAccountAction();
      final status = await eng.backendClient.completeUserPowWithProgress(
        keyPair: identity.keyPair,
        onProgress: (progress) => progressNotifier.value = progress,
      );
      eng.config.writeAt(['auth', 'pow_verified'], status.powVerified);
      eng.config.writeAt(['auth', 'pow_algorithm'], status.powAlgorithm);
      eng.config.writeAt(['auth', 'pow_score'], status.powScore);
      eng.config.writeAt(['auth', 'pow_verified_at'], status.powVerifiedAt);
      if (!mounted) return;
      setState(() {
        _userPowStatus = status;
        _userPowError = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('账号工作量证明已完成：强度 ${status.powScore}')),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _userPowError = '$e');
      deferredError = e;
    } finally {
      final activeDialogContext = dialogContext;
      if (dialogOpen &&
          activeDialogContext != null &&
          activeDialogContext.mounted) {
        Navigator.of(activeDialogContext).pop();
      }
      progressNotifier.dispose();
      if (mounted) {
        setState(() {
          _accountBusy = false;
          _userPowBusy = false;
        });
      }
      if (mounted && deferredError != null) {
        await _showSettingsError('工作量证明失败', deferredError);
      }
    }
  }

  Future<void> _openProtocolLoginCodeDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _ProtocolLoginCodeDialog(onGenerate: _generateProtocolLoginCode),
    );
    await _refresh();
  }

  Future<_ProtocolLoginCodeResult> _generateProtocolLoginCode(
    String challenge,
  ) async {
    if (_accountBusy) {
      throw StateError('当前已有账号操作正在执行');
    }
    final normalized = challenge.trim();
    final detail = ProtocolLoginChallengeDetail.decode(normalized);
    if (detail.version != 1 || !detail.isSupportedPurpose) {
      throw FormatException('不支持的 PH01 登录挑战：${detail.purpose}');
    }
    if (detail.nonce.isEmpty) {
      throw const FormatException('PH01 登录挑战缺少 nonce');
    }
    if (detail.isExpired(DateTime.now())) {
      throw const FormatException('PH01 登录挑战已过期');
    }
    setState(() => _accountBusy = true);
    try {
      final eng = ref.read(engineProvider);
      final identity = await _loadIdentityForAccountAction();
      final userId = await resolveProtocolLoginUserId(eng, identity);
      final code = eng.backendClient.buildProtocolLoginCode(
        keyPair: identity.keyPair,
        userId: userId,
        challenge: normalized,
      );
      await Clipboard.setData(ClipboardData(text: code));
      return _ProtocolLoginCodeResult(
        code: code,
        detail: detail,
        userId: userId,
      );
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
      await _showSettingsError('查看助记词失败', e);
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
      await _showSettingsError('重新生成故事失败', e);
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
      await _showSettingsError('无法轮换密钥', StateError('当前配置缺少云端用户名'));
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

    String? warning = _textValue(result.gatewayRevokeWarning);
    var localPersisted = false;
    var gatewaySynced = false;
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
        gatewaySynced = true;
      } catch (e) {
        warning = warning == null
            ? '密钥已轮换，但通信通道和模型同步失败：$e'
            : '$warning；通信通道和模型同步失败：$e';
      }
    }

    return _PubkeyRotationOutcome(
      registration: replacement,
      result: result,
      localPersisted: localPersisted,
      gatewaySynced: gatewaySynced,
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
      await _showSettingsError('打开失败', e);
    }
  }

  String _defaultExperienceManagerBaseUrl() {
    return ExperienceNetworkManagerClient.defaultManagerBaseUrl;
  }

  Future<void> _syncExperienceReviewMaterials(ExperienceListItem item) async {
    if (_experienceSyncingId != null) return;
    if (item.scope != ExperienceScope.private) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('只有私有经验需要取回审核签名')));
      return;
    }
    final input = await showDialog<_ExperienceReviewSyncInput>(
      context: context,
      builder: (_) => const _ExperienceReviewSyncDialog(),
    );
    if (input == null) return;
    setState(() => _experienceSyncingId = item.experienceId);
    try {
      final eng = ref.read(engineProvider);
      final client = ExperienceNetworkManagerClient();
      final store = ExperienceStore(
        agentDir: eng.home.agentDir(eng.config.agentId),
      );
      final remoteExperienceId =
          item.reviewState?.effectiveRemoteExperienceId ?? item.experienceId;
      final materials = await client.fetchReviewMaterials(
        experienceId: remoteExperienceId,
        bearerToken: input.bearerToken,
      );
      final attached = await store.attachReviewMaterialsToPrivatePackage(
        experienceId: item.experienceId,
        reviewMaterials: materials,
      );
      if (attached.ok) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('审核签名已附加到本地包')));
        await _refresh();
        return;
      }
      if (!attached.needsFullPackage) {
        throw StateError(attached.message);
      }
      if (!mounted) return;
      final replace = await _confirmExperienceFullPackageReplace(
        item,
        attached.message,
      );
      if (replace != true) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已取消完整包覆盖')));
        return;
      }
      final packageBytes = await client.fetchPackage(
        experienceId: remoteExperienceId,
        bearerToken: input.bearerToken,
      );
      final replaced = await store.replacePrivatePackageFromNetworkPackage(
        packageBytes,
      );
      if (!replaced.ok) {
        throw StateError(replaced.message);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('完整包已覆盖本地私有副本')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      if (_reviewMaterialsNotReady(e)) {
        await _showSettingsNotice(
          '审核签名暂不可取回',
          '管理端尚未为该经验生成审核签名材料。'
              '如果它处于待审状态，这是正常结果；审核通过后再取回即可。'
              '\n\n服务端返回：${e.toString()}',
        );
        return;
      }
      await _showSettingsError('同步审核签名失败', e);
    } finally {
      if (mounted) setState(() => _experienceSyncingId = null);
    }
  }

  Future<void> _submitExperienceForReview(ExperienceListItem item) async {
    if (_experienceSubmittingId != null) return;
    if (item.scope != ExperienceScope.private) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('只有本地私有经验需要提交审核')));
      return;
    }
    final reviewState = item.reviewState;
    if (reviewState?.pendingReview == true) {
      await _showSettingsNotice(
        '经验已提交',
        '该经验已经提交审核，当前状态是“等待审核”。'
            '为避免重复入队，客户端不会再次提交同一个本地经验包。'
            '\n\n可以在审核通过后点击“取回审核签名”。',
      );
      return;
    }
    if (reviewState?.approved == true) {
      await _showSettingsNotice('经验已通过审核', '该经验已经取回审核签名或处于网络通过状态，不需要重复提交。');
      return;
    }
    if (reviewState?.rejected == true) {
      await _showSettingsNotice(
        '经验已进入管理端',
        '该经验已经提交过且审核未通过。管理端不允许重复提交同一个经验包。'
            '\n\n如需重新提交，请重新生成为一条新的经验。',
      );
      return;
    }
    final input = await showDialog<_ExperienceSubmitInput>(
      context: context,
      builder: (_) => _ExperienceSubmitDialog(title: item.title),
    );
    if (input == null) return;
    setState(() {
      _experienceSubmittingId = item.experienceId;
      _experienceSubmitProgress = 0.02;
      _experienceSubmitProgressText = '正在打包本地经验';
    });
    try {
      final eng = ref.read(engineProvider);
      final identity = await _loadIdentityForAccountAction();
      final store = ExperienceStore(
        agentDir: eng.home.agentDir(eng.config.agentId),
      );
      final package = await store.packagePrivateExperienceForReview(
        experienceId: item.experienceId,
        keyPair: identity.keyPair,
      );
      if (mounted) {
        setState(() {
          _experienceSubmitProgress = 0.08;
          _experienceSubmitProgressText = '正在向经验管理端申请静默验证码';
        });
      }
      final client = ExperienceNetworkManagerClient();
      late final ExperiencePackagePowChallenge packagePowChallenge;
      try {
        packagePowChallenge = await client.startPackagePowChallenge(
          experienceId: item.experienceId,
          packageSha256: package.packageBytesSha256,
          pubkeyHash: identity.keyPair.publicKeyHash,
        );
      } on ExperienceAlreadySubmittedException catch (e) {
        await store.recordReviewSubmission(
          experienceId: item.experienceId,
          remoteExperienceId: e.result.experienceId.isEmpty
              ? item.experienceId
              : e.result.experienceId,
          status: e.result.status.isEmpty ? 'inbox' : e.result.status,
          packageBytesSha256: package.packageBytesSha256,
          packageHash: package.packageHash,
          reviewReason: e.result.reviewReason,
        );
        if (!mounted) return;
        final statusText = e.result.approved
            ? '已通过审核'
            : e.result.rejected
            ? '审核未通过'
            : '已提交审核';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('经验已在管理端：$statusText，已同步本地状态')));
        await _refresh();
        return;
      }
      final powStatus = await eng.backendClient
          .completeDelegatedPowWithProgress(
            keyPair: identity.keyPair,
            challengeId: packagePowChallenge.challengeId,
            onProgress: (progress) {
              if (!mounted) return;
              setState(() {
                _experienceSubmitProgress = (0.08 + progress.fraction * 0.82)
                    .clamp(0.08, 0.9)
                    .toDouble();
                _experienceSubmitProgressText = progress.message;
              });
            },
          );
      if (!powStatus.verified) {
        throw StateError('经验包工作量证明未通过认证中心确认');
      }
      if (mounted) {
        setState(() {
          _experienceSubmitProgress = 0.94;
          _experienceSubmitProgressText = '正在提交经验包';
        });
      }
      final result = await client.submitPackageForReview(
        packageBytes: package.packageBytes,
        keyPair: identity.keyPair,
        packagePow: ExperiencePackagePowProof(
          challengeId: packagePowChallenge.challengeId,
          packageSha256: package.packageBytesSha256,
          pubkeyHash: identity.keyPair.publicKeyHash,
        ),
        filename: '${item.experienceId}.hxp',
      );
      await store.recordReviewSubmission(
        experienceId: item.experienceId,
        remoteExperienceId: result.experienceId.isEmpty
            ? item.experienceId
            : result.experienceId,
        status: result.status.isEmpty ? 'inbox' : result.status,
        packageBytesSha256: package.packageBytesSha256,
        packageHash: package.packageHash,
        reviewReason: result.reviewReason,
      );
      if (result.approved) {
        try {
          final materials = await client.fetchReviewMaterials(
            experienceId: result.experienceId.isEmpty
                ? item.experienceId
                : result.experienceId,
          );
          await store.attachReviewMaterialsToPrivatePackage(
            experienceId: item.experienceId,
            reviewMaterials: materials,
          );
        } catch (_) {}
      }
      if (!mounted) return;
      final message = result.alreadySubmitted
          ? result.approved
                ? '经验已在管理端通过审核，已同步本地状态'
                : result.rejected
                ? '经验已在管理端且审核未通过，已同步本地状态'
                : '经验已在管理端，已同步本地提审状态'
          : result.approved
          ? '经验已通过审核并进入网络'
          : result.pendingReview
          ? '经验已提交审核，等待主脑审核'
          : '经验已提交，当前状态：${result.status.isEmpty ? "未知" : result.status}';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      await _showSettingsError('提交审核失败', e);
    } finally {
      if (mounted) {
        setState(() {
          _experienceSubmittingId = null;
          _experienceSubmitProgress = null;
          _experienceSubmitProgressText = null;
        });
      }
    }
  }

  Future<void> _previewExperience(ExperienceListItem item) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ExperiencePreviewDialog(item: item),
    );
  }

  Future<void> _regenerateExperience(ExperienceListItem item) async {
    if (_experienceRegeneratingId != null) return;
    final meta = item.metadata;
    final sessionPath = meta?.sourceSessionPath.trim() ?? '';
    if (sessionPath.isEmpty) {
      await _showSettingsError(
        '无法重新生成经验',
        StateError('该经验没有记录原始会话路径，只能预览或重新创建。'),
      );
      return;
    }
    final eng = ref.read(engineProvider);
    final store = ExperienceStore(
      agentDir: eng.home.agentDir(eng.config.agentId),
    );
    final reviewed =
        item.scope == ExperienceScope.network ||
        await store.privateExperienceHasReviewMaterials(
          experienceId: item.experienceId,
        );
    var createNew = false;
    if (reviewed) {
      final confirmed = await _confirmRegenerateReviewedExperience(item);
      if (confirmed != true) return;
      createNew = true;
    }
    setState(() => _experienceRegeneratingId = item.experienceId);
    try {
      final title = item.title.trim();
      final brief = meta?.brief ?? '';
      final keywords = meta?.keywords ?? const <String>[];
      if (createNew) {
        await ExperienceSessionCapture.saveSessionAsPrivateExperience(
          agentDir: eng.home.agentDir(eng.config.agentId),
          sessionPath: sessionPath,
          title: title,
          brief: brief,
          keywords: keywords,
        );
      } else {
        await ExperienceSessionCapture.overwritePrivateExperienceFromSession(
          agentDir: eng.home.agentDir(eng.config.agentId),
          experienceId: item.experienceId,
          sessionPath: sessionPath,
          title: title,
          brief: brief,
          keywords: keywords,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(createNew ? '已创建重新生成的新经验' : '经验内容已重新生成')),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      await _showSettingsError('重新生成经验失败', e);
    } finally {
      if (mounted) setState(() => _experienceRegeneratingId = null);
    }
  }

  Future<bool?> _confirmRegenerateReviewedExperience(ExperienceListItem item) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('经验已审核通过'),
        content: Text(
          '“${item.title}”已经进入审核通过链路，不能直接覆盖原内容。'
          '如果继续重新生成，程序会基于原始会话创建一条新的本地私有经验。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消重新生成'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建新经验'),
          ),
        ],
      ),
    );
  }

  Future<void> _startExperienceRedactionTask(ExperienceListItem item) async {
    if (_experienceRedactingId != null) return;
    if (item.scope != ExperienceScope.private) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('只有本地私有经验需要脱敏')));
      return;
    }
    final input = await showDialog<_ExperienceRedactionInput>(
      context: context,
      builder: (_) => _ExperienceRedactionDialog(title: item.title),
    );
    if (input == null) return;
    setState(() => _experienceRedactingId = item.experienceId);
    try {
      final eng = ref.read(engineProvider);
      final agentDir = eng.home.agentDir(eng.config.agentId);
      final sourceContentDir = p.join(item.path, 'content');
      final workDir = Directory(
        p.join(
          agentDir.path,
          'experience',
          'work',
          'redaction',
          '${item.experienceId}_${DateTime.now().toUtc().millisecondsSinceEpoch}',
        ),
      );
      await workDir.create(recursive: true);
      await Directory(p.join(workDir.path, 'raw')).create(recursive: true);
      await Directory(
        p.join(workDir.path, 'tool-calls'),
      ).create(recursive: true);
      await Directory(
        p.join(workDir.path, 'attachments'),
      ).create(recursive: true);
      final title = input.title.trim().isEmpty
          ? '${item.title}（脱敏版）'
          : input.title.trim();
      final prompt =
          '''
你正在执行 PH01 经验脱敏任务。
不要把源经验一次性读入上下文，也不要在正文里输出完整脱敏稿；请使用可用文件工具分块读取、分块修改输出目录。
源经验内容目录：$sourceContentDir
输出目录：${workDir.path}

任务要求：
1. 只在输出目录中写入脱敏后的原始经验文件，不要写总结稿、教程稿或摘要。
2. 保留原始结构和过程，conversation.md 仍应像聊天记录那样分段记录。
3. 工具调用与返回请尽量整理进 raw/events.md，保持机械转录风格。
4. 如发现图片、附件或日志有敏感信息，请在保留结构的前提下做脱敏替换。
5. 输出目录根部必须写入 metadata.json，并保留 raw/、tool-calls/、attachments/ 目录。
6. metadata.json 里请写入合适的 title、brief、keywords，schema_version 使用 ph01.experience.raw.v1。
7. 完成后调用 create_experience，参数固定为：
   - source: raw_directory
   - raw_directory: ${workDir.path}
   - title: $title
8. 不要提交网络审核；只生成本地私有经验副本。

用户的脱敏要求：
${input.instructions.trim()}
''';
      await eng.sessionCoordinator.runIsolatedPrompt(
        agentId: eng.config.agentId,
        prompt: prompt,
        cwd: sourceContentDir,
        source: 'experience_redaction:${item.experienceId}',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('脱敏任务完成，已生成本地私有经验')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      await _showSettingsError('脱敏任务失败', e);
    } finally {
      if (mounted) setState(() => _experienceRedactingId = null);
    }
  }

  Future<bool?> _confirmExperienceFullPackageReplace(
    ExperienceListItem item,
    String reason,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('覆盖本地完整包？'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title),
              const SizedBox(height: 8),
              Text(reason),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.download_done_outlined, size: 18),
            label: const Text('下载并覆盖'),
          ),
        ],
      ),
    );
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
      await _showSettingsError('创建失败', e);
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
      await _showSettingsError('保存失败', e);
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
      await _showSettingsError('立即执行失败', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final networkStatusValue = ref.watch(experienceNetworkStatusProvider);
    final networkStatus = networkStatusValue.asData?.value;
    final networkStatusError = networkStatusValue.maybeWhen(
      error: (error, _) => '$error',
      orElse: () => null,
    );
    final windowsOpsStatusValue = ref.watch(windowsOpsStatusProvider);
    final windowsOpsStatus = windowsOpsStatusValue.asData?.value;
    final windowsOpsStatusError = windowsOpsStatusValue.maybeWhen(
      error: (error, _) => '$error',
      orElse: () => null,
    );
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
                      _buildCodexRuntimeSection(),
                      const SizedBox(height: 24),
                      _buildExperienceSection(),
                      const SizedBox(height: 24),
                      _buildDhtSection(),
                      const SizedBox(height: 24),
                      _buildWorkSection(),
                      const SizedBox(height: 24),
                      _buildBridgeSection(),
                      const SizedBox(height: 24),
                      _buildBrowserSection(),
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
              onRefresh: _refreshAll,
              onClose: () => Navigator.of(context).maybePop(),
              networkStatus: networkStatus,
              networkStatusLoading: networkStatusValue.isLoading,
              networkStatusError: networkStatusError,
              dhtClientConfig: _dhtClientConfig,
              windowsOpsStatus: windowsOpsStatus,
              windowsOpsStatusLoading: windowsOpsStatusValue.isLoading,
              windowsOpsStatusError: windowsOpsStatusError,
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
    final localPowVerified =
        auth['pow_verified'] == true ||
        auth['pow_verified']?.toString().toLowerCase() == 'true';
    final powVerified = _userPowStatus?.powVerified ?? localPowVerified;
    final powScore =
        _userPowStatus?.powScore ??
        int.tryParse(_textValue(auth['pow_score']) ?? '') ??
        0;
    final powAlgorithm =
        _userPowStatus?.powAlgorithm ?? _textValue(auth['pow_algorithm']) ?? '';
    final powVerifiedAt =
        _userPowStatus?.powVerifiedAt ??
        int.tryParse(_textValue(auth['pow_verified_at']) ?? '') ??
        0;
    final powSubtitle = _userPowError != null
        ? '状态查询失败：$_userPowError'
        : currentHash == null
        ? '创建或登录账号后可发起账号工作量证明'
        : powVerified
        ? [
            if (powScore > 0) '强度 $powScore',
            if (powAlgorithm.isNotEmpty) powAlgorithm,
            if (powVerifiedAt > 0)
              _formatDialogTime(
                DateTime.fromMillisecondsSinceEpoch(powVerifiedAt * 1000),
              ),
          ].join(' · ')
        : '用于初始套餐赠送与网络置信度增强；在本机计算后提交认证中心';
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
                      if (_identityReady || _hasSavedIdentity)
                        OutlinedButton.icon(
                          onPressed: _accountBusy
                              ? null
                              : _openProtocolLoginCodeDialog,
                          icon: const Icon(Icons.qr_code_2, size: 18),
                          label: const Text('网页登录授权'),
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
              leading: Icon(
                powVerified ? Icons.task_alt : Icons.memory_outlined,
                color: powVerified
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(powVerified ? '账号工作量证明：已完成' : '账号工作量证明：未完成'),
              subtitle: Text(powSubtitle.isEmpty ? '-' : powSubtitle),
              trailing: currentHash == null
                  ? null
                  : OutlinedButton.icon(
                      onPressed: (_accountBusy || _userPowBusy)
                          ? null
                          : _completeUserPow,
                      icon: Icon(
                        _userPowBusy
                            ? Icons.hourglass_empty
                            : Icons.play_circle_outline,
                        size: 18,
                      ),
                      label: Text(
                        _userPowBusy
                            ? '计算中'
                            : powVerified
                            ? '重新证明'
                            : '开始证明',
                      ),
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
          ],
        ),
      ),
    );
  }

  Widget _buildCodexRuntimeSection() {
    final mode = _codexPermissionMode();
    return _Section(
      title: 'Codex 引擎',
      subtitle: 'Agent 执行引擎、工具授权与本地权限策略。',
      child: Card(
        child: Column(
          children: [
            const ListTile(
              leading: Icon(Icons.hub_outlined),
              title: Text('底层 Agent 执行引擎'),
              subtitle: Text('工具注册、路由、并行策略和提示词组织已切到 Codex 风格运行时。'),
            ),
            const Divider(height: 0),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('权限模式', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'prompt',
                          icon: Icon(Icons.rule_outlined, size: 18),
                          label: Text('每次询问'),
                        ),
                        ButtonSegment(
                          value: 'auto_approve',
                          icon: Icon(Icons.verified_outlined, size: 18),
                          label: Text('完全授权'),
                        ),
                        ButtonSegment(
                          value: 'deny',
                          icon: Icon(Icons.block_outlined, size: 18),
                          label: Text('全部拒绝'),
                        ),
                      ],
                      selected: {mode},
                      onSelectionChanged: (selected) =>
                          _setCodexPermissionMode(selected.first),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    switch (mode) {
                      'auto_approve' => '模型请求额外权限时会自动批准，适合信任本机 Agent 的用户。',
                      'deny' => '模型请求额外权限时会自动拒绝，适合只允许默认工具能力的场景。',
                      _ => '模型请求额外权限时弹出确认框，由用户决定是否授权。',
                    },
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 0),
            _buildToolCapabilitiesTile(),
          ],
        ),
      ),
    );
  }

  Widget _buildToolCapabilitiesTile() {
    final names = {
      ...LocalToolRegistry.buildTools().map((tool) => tool.name),
      ..._codexStandardToolNames,
    }.toList(growable: false)..sort();
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

  Widget _buildExperienceSection() {
    return _Section(
      title: '经验',
      subtitle: '本地文件树、元数据与网络经验入口。',
      child: Card(
        child: Column(
          children: [
            if (_experienceItems.isEmpty)
              const ListTile(
                leading: Icon(Icons.auto_stories_outlined),
                title: Text('暂无 PH01 经验'),
                subtitle: Text('经验生成或导入后会显示 metadata.json 与文件树路径。'),
              )
            else
              for (final item in _experienceItems) _buildExperienceTile(item),
          ],
        ),
      ),
    );
  }

  Widget _buildExperienceTile(ExperienceListItem item) {
    final metadataPath = p.join(item.path, 'content', 'metadata.json');
    final meta = item.metadata;
    final reviewState = item.reviewState;
    final keywords = meta?.keywords.join(', ') ?? '';
    final syncing = _experienceSyncingId == item.experienceId;
    final submitting = _experienceSubmittingId == item.experienceId;
    final regenerating = _experienceRegeneratingId == item.experienceId;
    final subtitle = [
      item.scope.wireName,
      if (reviewState != null) '审核状态：${reviewState.displayLabel}',
      if (reviewState?.submittedAt.trim().isNotEmpty == true)
        '提交时间：${reviewState!.submittedAt}',
      if (reviewState?.remoteExperienceId.trim().isNotEmpty == true &&
          reviewState!.remoteExperienceId != item.experienceId)
        '管理端 ID：${reviewState.remoteExperienceId}',
      if (meta?.createdAt.trim().isNotEmpty == true) meta!.createdAt,
      if (keywords.isNotEmpty) keywords,
      metadataPath,
    ].join('\n');
    final progress = _experienceSubmitProgress;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(
            item.scope == ExperienceScope.network
                ? Icons.hub_outlined
                : Icons.folder_open_outlined,
          ),
          title: Text(item.title),
          subtitle: Text(subtitle),
          isThreeLine: true,
          trailing: Wrap(
            alignment: WrapAlignment.end,
            spacing: 0,
            runSpacing: 0,
            children: [
              IconButton(
                tooltip: '预览经验',
                icon: const Icon(Icons.visibility_outlined),
                onPressed: () => _previewExperience(item),
              ),
              IconButton(
                tooltip: '重新生成经验',
                icon: regenerating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_outlined),
                onPressed:
                    _experienceRegeneratingId == null &&
                        _experienceRedactingId == null &&
                        _experienceSubmittingId == null &&
                        _experienceSyncingId == null
                    ? () => _regenerateExperience(item)
                    : null,
              ),
              if (item.scope == ExperienceScope.private)
                IconButton(
                  tooltip: '启动脱敏任务',
                  icon: _experienceRedactingId == item.experienceId
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_fix_high_outlined),
                  onPressed:
                      _experienceRedactingId == null &&
                          _experienceRegeneratingId == null &&
                          _experienceSubmittingId == null &&
                          _experienceSyncingId == null
                      ? () => _startExperienceRedactionTask(item)
                      : null,
                ),
              if (item.scope == ExperienceScope.private)
                IconButton(
                  tooltip: reviewState?.pendingReview == true
                      ? '已提交审核，等待审核通过'
                      : reviewState?.approved == true
                      ? '已通过审核，不需要重复提交'
                      : reviewState?.rejected == true
                      ? '审核未通过，不能重复提交同一包'
                      : '提交审核',
                  icon: submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined),
                  onPressed:
                      _experienceSubmittingId == null &&
                          _experienceSyncingId == null &&
                          _experienceRegeneratingId == null &&
                          _experienceRedactingId == null &&
                          reviewState?.submitted != true
                      ? () => _submitExperienceForReview(item)
                      : null,
                ),
              if (item.scope == ExperienceScope.private)
                IconButton(
                  tooltip: '取回审核签名',
                  icon: syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_outlined),
                  onPressed:
                      _experienceSyncingId == null &&
                          _experienceSubmittingId == null &&
                          _experienceRegeneratingId == null &&
                          _experienceRedactingId == null
                      ? () => _syncExperienceReviewMaterials(item)
                      : null,
                ),
              IconButton(
                tooltip: '复制元数据路径',
                icon: const Icon(Icons.copy_outlined),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: metadataPath));
                  if (!mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('元数据路径已复制')));
                },
              ),
            ],
          ),
        ),
        if (submitting && progress != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0, 1).toDouble(),
                    minHeight: 6,
                  ),
                ),
                if ((_experienceSubmitProgressText ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _experienceSubmitProgressText!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  bool _hasConfiguredDhtNode(ExperienceDhtClientConfig cfg) {
    return cfg.isCustomPrivate && cfg.adminBaseUrl.trim().isNotEmpty;
  }

  Widget _buildDhtSection() {
    final cfg = _dhtClientConfig ?? const ExperienceDhtClientConfig();
    final c = Theme.of(context).colorScheme;
    final candidateEndpoints = cfg.effectiveCandidateEndpoints;
    final candidateText = candidateEndpoints
        .map(
          (endpoint) =>
              '${endpoint.network}://${endpoint.host}:${endpoint.port}',
        )
        .join(' · ');
    final hasNode = _hasConfiguredDhtNode(cfg);
    final canManageNode = hasNode && cfg.adminBaseUrl.trim().isNotEmpty;
    final managerBaseUrl = _defaultExperienceManagerBaseUrl();
    final nodeSubtitle = hasNode
        ? <String>[
            if (cfg.adminBaseUrl.trim().isNotEmpty)
              '公网访问 URL=${cfg.adminBaseUrl.trim()}',
            if (candidateText.isNotEmpty) '候选端点=$candidateText',
            '转发策略=${cfg.relayPolicy.wireName}',
            cfg.publicRegistrationEnabled ? '公开状态=已开启' : '公开状态=未开启',
            '官方经验管理端=$managerBaseUrl',
          ].join('\n')
        : '添加 DHT 节点后，客户端可用它进行连接、预探测、绑定与公开状态管理。';
    final publicListSubtitle = '公开列表来源：$managerBaseUrl';
    const emptyPublicListTitle = '暂无公开 DHT';
    const emptyPublicListSubtitle = '当前官方经验管理端没有返回可用公开节点。';
    return _Section(
      title: 'DHT 节点',
      subtitle: '添加本地节点、查看公开列表、切换公开状态。',
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(
                hasNode ? Icons.hub_outlined : Icons.add_circle_outline,
                color: hasNode ? c.primary : c.onSurfaceVariant,
              ),
              title: Text(hasNode ? '本地 DHT 节点' : '尚未添加 DHT 节点'),
              subtitle: Text(nodeSubtitle),
              isThreeLine: hasNode,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _editDhtClientConfig,
                    icon: Icon(
                      hasNode ? Icons.edit_outlined : Icons.add_outlined,
                      size: 18,
                    ),
                    label: Text(hasNode ? '编辑 DHT 节点' : '添加 DHT 节点'),
                  ),
                  if (hasNode) ...[
                    OutlinedButton.icon(
                      onPressed: canManageNode ? _bindDhtAdmin : null,
                      icon: const Icon(Icons.key_outlined, size: 18),
                      label: const Text('绑定管理公钥'),
                    ),
                    OutlinedButton.icon(
                      onPressed: canManageNode ? _syncDhtRuntimeConfig : null,
                      icon: const Icon(Icons.sync_alt_outlined, size: 18),
                      label: const Text('同步运行配置'),
                    ),
                    OutlinedButton.icon(
                      onPressed: canManageNode ? _showDhtAdminStatus : null,
                      icon: const Icon(Icons.fact_check_outlined, size: 18),
                      label: const Text('查询状态'),
                    ),
                    OutlinedButton.icon(
                      onPressed: canManageNode
                          ? () => _setDhtPublicMode(
                              !cfg.publicRegistrationEnabled,
                            )
                          : null,
                      icon: Icon(
                        cfg.publicRegistrationEnabled
                            ? Icons.public_off_outlined
                            : Icons.public_outlined,
                        size: 18,
                      ),
                      label: Text(
                        cfg.publicRegistrationEnabled ? '关闭公开' : '开启公开',
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (hasNode && cfg.publicRegistrationEnabled)
              const ListTile(
                leading: Icon(Icons.public_outlined),
                title: Text('DHT 公开状态已开启'),
                subtitle: Text('该状态来自最近一次 DHT 管理 API 操作或查询。'),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.public_outlined),
              title: const Text('公开 DHT 列表'),
              subtitle: Text(publicListSubtitle),
            ),
            if (_dhtError != null)
              ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('公开 DHT 列表读取失败'),
                subtitle: Text(_dhtError!),
              ),
            if (_publicDhtNodes.isEmpty && _dhtError == null)
              ListTile(
                leading: const Icon(Icons.view_list_outlined),
                title: Text(emptyPublicListTitle),
                subtitle: Text(emptyPublicListSubtitle),
              )
            else
              for (final node in _publicDhtNodes) _buildPublicDhtTile(node),
          ],
        ),
      ),
    );
  }

  Widget _buildPublicDhtTile(ExperienceDhtNode node) {
    final endpointText = node.endpoints
        .map(
          (endpoint) =>
              '${endpoint.network}://${endpoint.host}:${endpoint.port}',
        )
        .join(' · ');
    final subtitle = <String>[
      if (node.region.trim().isNotEmpty) 'region=${node.region.trim()}',
      if (endpointText.isNotEmpty) endpointText,
      'relay=${node.relayPolicy.wireName}',
      'health=${node.healthStatus.wireName}',
      if (node.expiresAt != null)
        'expires=${node.expiresAt!.toLocal().toIso8601String()}',
    ].join('\n');
    return ListTile(
      leading: Icon(
        node.healthStatus == ExperienceDhtHealthStatus.healthy
            ? Icons.hub_outlined
            : Icons.warning_amber_outlined,
      ),
      title: Text(node.nodeId),
      subtitle: Text(subtitle),
      isThreeLine: true,
    );
  }

  Future<void> _editDhtClientConfig() async {
    final current = _dhtClientConfig ?? const ExperienceDhtClientConfig();
    final input = await showDialog<_ExperienceDhtConfigInput>(
      context: context,
      builder: (_) => _ExperienceDhtConfigDialog(
        current: current,
        isCreating: !_hasConfiguredDhtNode(current),
      ),
    );
    if (input == null) return;
    final eng = ref.read(engineProvider);
    eng.config.writeAt(['experience', 'dht_client'], input.config.toJson());
    await _refresh();
  }

  Future<String?> _requireDhtAdminBaseUrl() async {
    final baseUrl = _dhtClientConfig?.adminBaseUrl.trim() ?? '';
    if (baseUrl.isEmpty) {
      await _showSettingsError(
        '缺少 DHT 公网访问 URL',
        StateError('请先添加 DHT 节点并填写公网访问 URL'),
      );
      return null;
    }
    return baseUrl;
  }

  ExperienceDhtRuntimeConfig _dhtRuntimeConfigFor(
    ExperienceDhtClientConfig cfg,
  ) {
    return ExperienceDhtRuntimeConfig(
      publicApiBaseUrl: cfg.adminBaseUrl,
      candidateEndpoints: cfg.effectiveCandidateEndpoints,
      relayPolicy: cfg.relayPolicy,
    );
  }

  Future<void> _bindDhtAdmin() async {
    if (_accountBusy) return;
    final baseUrl = await _requireDhtAdminBaseUrl();
    if (baseUrl == null) return;
    if (!mounted) return;
    final initPassword = await showDialog<String>(
      context: context,
      builder: (_) => const _DhtBindDialog(),
    );
    if (initPassword == null || initPassword.trim().isEmpty) return;
    setState(() => _accountBusy = true);
    try {
      final identity = await _loadIdentityForAccountAction();
      final managerBaseUrl = _defaultExperienceManagerBaseUrl();
      final state = await ExperienceDhtHttpClient(dhtBaseUrl: baseUrl)
          .bindAdmin(
            initPassword: initPassword,
            pubkeyHex: identity.keyPair.publicKeyHex,
            managerBaseUrl: managerBaseUrl,
            runtimeConfig: _dhtRuntimeConfigFor(
              _dhtClientConfig ?? const ExperienceDhtClientConfig(),
            ),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('DHT 管理公钥已绑定：${state.nodeId}')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      await _showSettingsError('DHT 绑定失败', e);
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _syncDhtRuntimeConfig() async {
    if (_accountBusy) return;
    final baseUrl = await _requireDhtAdminBaseUrl();
    if (baseUrl == null) return;
    setState(() => _accountBusy = true);
    try {
      final identity = await _loadIdentityForAccountAction();
      final current = _dhtClientConfig ?? const ExperienceDhtClientConfig();
      await ExperienceDhtHttpClient(dhtBaseUrl: baseUrl).setRuntimeConfig(
        keyPair: identity.keyPair,
        runtimeConfig: _dhtRuntimeConfigFor(current),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('DHT 运行配置已同步')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      await _showSettingsError('DHT 配置同步失败', e);
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _showDhtAdminStatus() async {
    if (_accountBusy) return;
    final baseUrl = await _requireDhtAdminBaseUrl();
    if (baseUrl == null) return;
    setState(() => _accountBusy = true);
    try {
      final identity = await _loadIdentityForAccountAction();
      final status = await ExperienceDhtHttpClient(
        dhtBaseUrl: baseUrl,
      ).fetchAdminStatus(keyPair: identity.keyPair);
      final current = _dhtClientConfig ?? const ExperienceDhtClientConfig();
      if (current.publicRegistrationEnabled != status.state.publicEnabled) {
        ref.read(engineProvider).config.writeAt(
          ['experience', 'dht_client'],
          ExperienceDhtClientConfig(
            mode: current.mode,
            candidateEndpoints: current.effectiveCandidateEndpoints,
            relayPolicy: current.relayPolicy,
            publicRegistrationEnabled: status.state.publicEnabled,
            adminBaseUrl: current.adminBaseUrl,
          ).toJson(),
        );
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _DhtStatusDialog(status: status),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      await _showSettingsError('DHT 状态查询失败', e);
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
  }

  Future<void> _setDhtPublicMode(bool enabled) async {
    if (_accountBusy) return;
    final baseUrl = await _requireDhtAdminBaseUrl();
    if (baseUrl == null) return;
    final managerBaseUrl = enabled ? _defaultExperienceManagerBaseUrl() : '';
    setState(() => _accountBusy = true);
    try {
      final identity = await _loadIdentityForAccountAction();
      final dhtClient = ExperienceDhtHttpClient(dhtBaseUrl: baseUrl);
      final current = _dhtClientConfig ?? const ExperienceDhtClientConfig();
      await dhtClient.setRuntimeConfig(
        keyPair: identity.keyPair,
        runtimeConfig: _dhtRuntimeConfigFor(current),
      );
      final result = await dhtClient.setPublicMode(
        enabled: enabled,
        keyPair: identity.keyPair,
        managerBaseUrl: managerBaseUrl,
      );
      final updated = ExperienceDhtClientConfig(
        mode: current.mode,
        candidateEndpoints: current.effectiveCandidateEndpoints,
        relayPolicy: current.relayPolicy,
        publicRegistrationEnabled: result.state.publicEnabled,
        adminBaseUrl: current.adminBaseUrl,
      );
      ref.read(engineProvider).config.writeAt([
        'experience',
        'dht_client',
      ], updated.toJson());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.state.publicEnabled ? 'DHT 已开启公开注册' : 'DHT 已关闭公开注册',
          ),
        ),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      await _showSettingsError('DHT 公开模式切换失败', e);
    } finally {
      if (mounted) setState(() => _accountBusy = false);
    }
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
      subtitle: '当前子体实现与底层引擎来源。',
      child: Card(
        child: Column(
          children: [
            const ListTile(
              leading: Icon(Icons.info_outline, size: 22),
              title: Text('幻宙01 / PH01 子体'),
              subtitle: Text('个人 AI 子体 · Flutter Desktop · PH01 重构实现'),
            ),
            const Divider(height: 0),
            const ListTile(
              title: Text('底层 Agent 执行引擎来源'),
              subtitle: SelectableText(
                'OpenAI Codex\nhttps://github.com/openai/codex',
              ),
            ),
            const Divider(height: 0),
            const ListTile(
              title: Text('许可证'),
              subtitle: SelectableText(
                'Apache License 2.0\n本客户端仅迁入 Codex Agent 执行引擎逻辑，不引入 Codex CLI/TUI、登录、配置文件体系或云端状态。',
              ),
            ),
            const Divider(height: 0),
            const ListTile(
              title: Text('实现边界'),
              subtitle: Text('界面、身份体系、经验网络、Windows 操作链和客户端业务能力均为 PH01 当前实现。'),
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
  const _SettingsHeader({
    required this.onRefresh,
    required this.onClose,
    required this.networkStatus,
    required this.networkStatusLoading,
    required this.networkStatusError,
    required this.dhtClientConfig,
    required this.windowsOpsStatus,
    required this.windowsOpsStatusLoading,
    required this.windowsOpsStatusError,
  });
  final VoidCallback onRefresh;
  final VoidCallback onClose;
  final ExperienceNetworkStatus? networkStatus;
  final bool networkStatusLoading;
  final String? networkStatusError;
  final ExperienceDhtClientConfig? dhtClientConfig;
  final WindowsOpsCapabilities? windowsOpsStatus;
  final bool windowsOpsStatusLoading;
  final String? windowsOpsStatusError;

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
        child: LayoutBuilder(
          builder: (context, box) {
            final compact = box.maxWidth < 1020;
            final title = Column(
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
            );
            final statusItems = <StatusClusterItem>[
              StatusClusterItem(
                icon: Icons.lan_outlined,
                label: _networkStatusLabel(
                  networkStatus,
                  loading: networkStatusLoading,
                  error: networkStatusError,
                ),
                color: _networkStatusColor(
                  c,
                  networkStatus,
                  loading: networkStatusLoading,
                  error: networkStatusError,
                ),
                tooltip: _networkStatusTooltip(
                  networkStatus,
                  loading: networkStatusLoading,
                  error: networkStatusError,
                ),
              ),
              StatusClusterItem(
                icon: Icons.sync_alt_outlined,
                label: _experienceRelayStatusLabel(dhtClientConfig),
                color: _experienceRelayStatusColor(c, dhtClientConfig),
                tooltip: _experienceRelayStatusTooltip(dhtClientConfig),
              ),
              StatusClusterItem(
                icon: Icons.ads_click_outlined,
                label: _windowsOpsStatusLabel(
                  windowsOpsStatus,
                  loading: windowsOpsStatusLoading,
                  error: windowsOpsStatusError,
                ),
                color: _windowsOpsStatusColor(
                  c,
                  windowsOpsStatus,
                  loading: windowsOpsStatusLoading,
                  error: windowsOpsStatusError,
                ),
                tooltip: _windowsOpsStatusTooltip(
                  windowsOpsStatus,
                  loading: windowsOpsStatusLoading,
                  error: windowsOpsStatusError,
                ),
              ),
            ];
            final status = StatusCluster(
              items: statusItems,
              expandLeft: !compact,
            );
            final leading = <Widget>[
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
            ];
            final actions = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
            );

            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ...leading,
                      Expanded(child: title),
                      const SizedBox(width: 12),
                      actions,
                    ],
                  ),
                  const SizedBox(height: 12),
                  status,
                ],
              );
            }

            return Row(
              children: [
                ...leading,
                Expanded(child: title),
                const SizedBox(width: 16),
                Flexible(
                  child: Align(alignment: Alignment.centerRight, child: status),
                ),
                const SizedBox(width: 16),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

String _networkStatusLabel(
  ExperienceNetworkStatus? status, {
  required bool loading,
  String? error,
}) {
  if (status == null) {
    return loading ? 'DHT 探测中' : 'DHT 未连接';
  }
  final parts = <String>[
    'DHT ${status.connectedDhtCount}/${status.configuredDhtCount}',
  ];
  if (status.ipv6Status == ExperienceNetworkPathStatus.direct) {
    parts.add('IPv6 可以直连');
  }
  if (status.ipv4Status == ExperienceNetworkPathStatus.holePunchable) {
    parts.add('IPv4 打洞成功');
  } else if (status.ipv4Status == ExperienceNetworkPathStatus.notPunchable) {
    parts.add('IPv4 不可打洞');
  }
  if (parts.length == 1) parts.add(status.bestModeLabel);
  return parts.join(' · ');
}

Color _networkStatusColor(
  ColorScheme c,
  ExperienceNetworkStatus? status, {
  required bool loading,
  String? error,
}) {
  if (status == null) return loading ? c.secondary : c.error;
  if (error != null || status.error != null || status.connectedDhtCount == 0) {
    return c.error;
  }
  if (status.ipv6Status == ExperienceNetworkPathStatus.direct) {
    return Colors.green.shade700;
  }
  if (status.ipv4Status == ExperienceNetworkPathStatus.holePunchable) {
    return c.primary;
  }
  if (status.ipv4Status == ExperienceNetworkPathStatus.notPunchable) {
    return c.tertiary;
  }
  return c.error;
}

String _networkStatusTooltip(
  ExperienceNetworkStatus? status, {
  required bool loading,
  String? error,
}) {
  if (status == null) {
    return error == null || error.isEmpty ? '正在探测经验网络 DHT' : error;
  }
  final lines = <String>[
    '已连接 DHT：${status.connectedDhtCount}/${status.configuredDhtCount}',
    '公开 DHT：${status.publicDhtCount}',
    'IPv6：${status.ipv6Status.label}',
    'IPv4：${status.ipv4Status.label}',
    '当前模式：${status.bestModeLabel}',
  ];
  if (status.managerBaseUrl.trim().isNotEmpty) {
    lines.add('官方经验管理端：${status.managerBaseUrl}');
  }
  for (final connection in status.connections.take(5)) {
    final state = connection.connected ? '已连接' : '未连接';
    final reason = connection.error == null ? '' : ' · ${connection.error}';
    lines.add('${connection.node.nodeId}：$state$reason');
  }
  if (error != null && error.isNotEmpty) lines.add(error);
  if (status.error != null && status.error!.isNotEmpty) {
    lines.add(status.error!);
  }
  return lines.join('\n');
}

String _experienceRelayStatusLabel(ExperienceDhtClientConfig? config) {
  if (config == null) return '经验转发待加载';
  return switch (config.relayPolicy) {
    ExperienceRelayPolicy.public => '经验转发可响应',
    ExperienceRelayPolicy.ownerOnly => '经验转发仅自己',
    ExperienceRelayPolicy.disabled => '经验转发关闭',
  };
}

Color _experienceRelayStatusColor(
  ColorScheme c,
  ExperienceDhtClientConfig? config,
) {
  if (config == null) return c.secondary;
  return switch (config.relayPolicy) {
    ExperienceRelayPolicy.public => Colors.green.shade700,
    ExperienceRelayPolicy.ownerOnly => c.primary,
    ExperienceRelayPolicy.disabled => c.tertiary,
  };
}

String _experienceRelayStatusTooltip(ExperienceDhtClientConfig? config) {
  if (config == null) return '正在读取 DHT 客户端配置';
  final publicUrl = config.adminBaseUrl.trim().isEmpty
      ? '未配置'
      : config.adminBaseUrl.trim();
  const managerUrl = ExperienceNetworkManagerClient.defaultManagerBaseUrl;
  return [
    '经验转发与交互',
    '转发策略：${config.relayPolicy.wireName}',
    '公网访问 URL：$publicUrl',
    '管理端：$managerUrl',
    '公开状态：${config.publicRegistrationEnabled ? "已开启" : "未开启"}',
  ].join('\n');
}

String _windowsOpsStatusLabel(
  WindowsOpsCapabilities? status, {
  required bool loading,
  String? error,
}) {
  if (status == null) {
    return loading ? '界面模型加载中' : '界面操作未就绪';
  }
  if (!status.sidecar) return '界面操作不可用';
  final ready = <String>[];
  if (status.inputMouse && status.inputKeyboard) ready.add('输入');
  if (status.uiParsing) ready.add('界面模型');
  if (status.ocr) ready.add('OCR');
  if (ready.isEmpty) return error == null ? '界面操作待准备' : '界面操作异常';
  return ready.join(' · ');
}

Color _windowsOpsStatusColor(
  ColorScheme c,
  WindowsOpsCapabilities? status, {
  required bool loading,
  String? error,
}) {
  if (status == null) return loading ? c.secondary : c.error;
  if (error != null || !status.sidecar) return c.error;
  if (status.inputMouse &&
      status.inputKeyboard &&
      status.uiParsing &&
      status.ocr) {
    return Colors.green.shade700;
  }
  if (status.inputMouse || status.inputKeyboard || status.uiaTree) {
    return c.primary;
  }
  return c.tertiary;
}

String _windowsOpsStatusTooltip(
  WindowsOpsCapabilities? status, {
  required bool loading,
  String? error,
}) {
  if (status == null) {
    return error == null || error.isEmpty ? '正在检查 Windows 操作链' : error;
  }
  final lines = <String>[
    'Windows 操作链',
    '边车：${status.sidecar ? "已启动" : "不可用"}',
    '截图：${status.screenCapture ? "可用" : "不可用"}',
    '鼠标输入：${status.inputMouse ? "可用" : "不可用"}',
    '键盘输入：${status.inputKeyboard ? "可用" : "不可用"}',
    'UIA 控件树：${status.uiaTree ? "可用" : "不可用"}',
    'UIA Invoke：${status.uiaInvoke ? "可用" : "不可用"}',
    'OCR：${status.ocr ? "可用" : "不可用"}',
    '界面识别模型：${status.uiParsing ? "可用" : "不可用"}',
  ];
  if (error != null && error.isNotEmpty) lines.add(error);
  if (status.unavailableReasons.isNotEmpty) {
    for (final entry in status.unavailableReasons.entries.take(6)) {
      lines.add('${entry.key}：${entry.value}');
    }
  }
  return lines.join('\n');
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

class _SettingsErrorDetails {
  const _SettingsErrorDetails({required this.summary, this.body = ''});

  final String summary;
  final String body;
}

_SettingsErrorDetails _settingsErrorDetails(Object error) {
  if (error is ExperienceNetworkRequestException) {
    final body = <String>[
      if (error.statusCode != null) 'HTTP 状态：${error.statusCode}',
      if (error.errorCode.trim().isNotEmpty) '错误代码：${error.errorCode}',
      '错误信息：${error.message}',
      if (error.rawBody.trim().isNotEmpty) ...[
        '',
        '服务端返回：',
        error.rawBody.trim(),
      ],
    ].join('\n');
    return _SettingsErrorDetails(summary: error.toString(), body: body);
  }
  return _SettingsErrorDetails(summary: error.toString());
}

bool _reviewMaterialsNotReady(Object error) {
  if (error is! ExperienceNetworkRequestException) return false;
  if (error.statusCode != 404) return false;
  final code = error.errorCode.trim().toLowerCase();
  return code.isEmpty || code == 'not_found';
}

class _ExperiencePreviewData {
  const _ExperiencePreviewData({
    required this.contentPath,
    required this.messages,
    required this.eventsText,
    required this.toolFiles,
  });

  final String contentPath;
  final List<_ExperiencePreviewMessage> messages;
  final String eventsText;
  final List<_ExperiencePreviewToolFile> toolFiles;
}

class _ExperiencePreviewMessage {
  const _ExperiencePreviewMessage({required this.role, required this.text});

  final String role;
  final String text;
}

class _ExperiencePreviewToolFile {
  const _ExperiencePreviewToolFile({
    required this.relativePath,
    required this.content,
  });

  final String relativePath;
  final String content;
}

Future<_ExperiencePreviewData> _loadExperiencePreviewData(
  ExperienceListItem item,
) async {
  final contentPath = p.join(item.path, 'content');
  final conversation = await _readOptionalText(
    p.join(contentPath, 'raw', 'conversation.md'),
  );
  final eventsText = await _readOptionalText(
    p.join(contentPath, 'raw', 'events.md'),
  );
  return _ExperiencePreviewData(
    contentPath: contentPath,
    messages: _parseExperienceConversation(conversation),
    eventsText: eventsText.trimRight(),
    toolFiles: await _readExperienceToolFiles(contentPath),
  );
}

Future<String> _readOptionalText(String path) async {
  final file = File(path);
  if (!await file.exists()) return '';
  return file.readAsString();
}

Future<List<_ExperiencePreviewToolFile>> _readExperienceToolFiles(
  String contentPath,
) async {
  final toolDir = Directory(p.join(contentPath, 'tool-calls'));
  if (!await toolDir.exists()) return const [];
  final out = <_ExperiencePreviewToolFile>[];
  await for (final entity in toolDir.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final relative = p
        .relative(entity.path, from: toolDir.path)
        .split(p.separator)
        .join('/');
    final stat = await entity.stat();
    if (stat.size > 512 * 1024) {
      out.add(
        _ExperiencePreviewToolFile(
          relativePath: relative,
          content: '文件过大，预览已省略（${stat.size} bytes）',
        ),
      );
      continue;
    }
    out.add(
      _ExperiencePreviewToolFile(
        relativePath: relative,
        content: await entity.readAsString().catchError((_) => '无法读取该工具记录'),
      ),
    );
  }
  out.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return out;
}

List<_ExperiencePreviewMessage> _parseExperienceConversation(String text) {
  final messages = <_ExperiencePreviewMessage>[];
  String? role;
  final buffer = StringBuffer();
  final heading = RegExp(r'^##\s+\d+\.\s*(.+?)\s*$');

  void flush() {
    final body = buffer.toString().trim();
    if (role != null && body.isNotEmpty) {
      messages.add(_ExperiencePreviewMessage(role: role, text: body));
    }
    buffer.clear();
  }

  for (final line in text.split(RegExp(r'\r?\n'))) {
    final match = heading.firstMatch(line);
    if (match != null) {
      flush();
      role = match.group(1)?.trim();
      continue;
    }
    if (role == null) continue;
    buffer.writeln(line);
  }
  flush();
  if (messages.isEmpty && text.trim().isNotEmpty) {
    messages.add(
      _ExperiencePreviewMessage(role: '原始对话', text: text.trimRight()),
    );
  }
  return messages;
}

bool _isUserPreviewRole(String role) {
  final lower = role.trim().toLowerCase();
  return lower.contains('用户') ||
      lower.contains('user') ||
      lower.contains('human');
}

Widget _buildExperiencePreviewBubble(
  BuildContext context,
  _ExperiencePreviewMessage message,
) {
  final theme = Theme.of(context);
  final c = theme.colorScheme;
  final isUser = _isUserPreviewRole(message.role);
  final background = isUser ? c.primaryContainer : c.surfaceContainerHighest;
  final foreground = isUser ? c.onPrimaryContainer : c.onSurfaceVariant;
  return Align(
    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.outlineVariant.withValues(alpha: 0.55)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.role,
              style: theme.textTheme.labelMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              message.text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: foreground,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ExperienceReviewSyncInput {
  const _ExperienceReviewSyncInput({this.bearerToken});

  final String? bearerToken;
}

class _ExperienceSubmitInput {
  const _ExperienceSubmitInput();
}

class _ExperienceRedactionInput {
  const _ExperienceRedactionInput({
    required this.title,
    required this.instructions,
  });

  final String title;
  final String instructions;
}

class _ExperienceRedactionDialog extends StatefulWidget {
  const _ExperienceRedactionDialog({required this.title});

  final String title;

  @override
  State<_ExperienceRedactionDialog> createState() =>
      _ExperienceRedactionDialogState();
}

class _ExperienceRedactionDialogState
    extends State<_ExperienceRedactionDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _instructionsCtrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: '${widget.title}（脱敏版）');
    _instructionsCtrl = TextEditingController(
      text:
          '保留原始结构和过程，不要写成摘要或教程。隐藏姓名、账号、电话、邮箱、地址、密钥和其他敏感标识；如果附件或图片含敏感信息，也要由 AI 判断后做脱敏处理。先分块读取源目录，再写出独立暂存目录，最后导入为本地私有经验。',
    );
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _instructionsCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _titleCtrl.text.trim();
    final instructions = _instructionsCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '请填写输出标题');
      return;
    }
    if (instructions.isEmpty) {
      setState(() => _error = '请填写脱敏要求');
      return;
    }
    Navigator.pop(
      context,
      _ExperienceRedactionInput(title: title, instructions: instructions),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('启动脱敏任务'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '这会在独立会话里读取源经验目录，AI 自己生成脱敏副本，然后再导入为新的本地私有经验；不会把整份经验一次性塞进上下文。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: '输出标题',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _instructionsCtrl,
              minLines: 5,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '脱敏要求',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
          label: const Text('开始脱敏'),
        ),
      ],
    );
  }
}

class _ExperiencePreviewDialog extends StatefulWidget {
  const _ExperiencePreviewDialog({required this.item});

  final ExperienceListItem item;

  @override
  State<_ExperiencePreviewDialog> createState() =>
      _ExperiencePreviewDialogState();
}

class _ExperiencePreviewDialogState extends State<_ExperiencePreviewDialog> {
  late final Future<_ExperiencePreviewData> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadExperiencePreviewData(widget.item);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width - 96).clamp(420.0, 900.0).toDouble();
    final dialogHeight = (size.height - 120).clamp(420.0, 760.0).toDouble();
    return AlertDialog(
      title: const Text('经验预览'),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: FutureBuilder<_ExperiencePreviewData>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  '加载经验失败：${snapshot.error}',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              );
            }
            final data = snapshot.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.item.title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  '内容目录：${data.contentPath}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: [
                      if (data.messages.isEmpty)
                        const ListTile(
                          leading: Icon(Icons.chat_outlined),
                          title: Text('暂无可显示的对话内容'),
                        )
                      else
                        for (final message in data.messages)
                          _buildExperiencePreviewBubble(context, message),
                      const SizedBox(height: 8),
                      ExpansionTile(
                        initiallyExpanded: true,
                        tilePadding: EdgeInsets.zero,
                        title: Text(
                          data.toolFiles.isEmpty
                              ? '工具调用与返回'
                              : '工具调用与返回（${data.toolFiles.length} 个文件）',
                        ),
                        children: [
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant
                                    .withValues(alpha: 0.55),
                              ),
                            ),
                            child: SelectableText(
                              data.eventsText.isEmpty
                                  ? '暂无工具事件'
                                  : data.eventsText,
                              style: theme.textTheme.bodySmall?.copyWith(
                                height: 1.5,
                              ),
                            ),
                          ),
                          for (final file in data.toolFiles)
                            Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant
                                      .withValues(alpha: 0.55),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    file.relativePath,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 8),
                                  SelectableText(
                                    file.content.trimRight().isEmpty
                                        ? '空文件'
                                        : file.content.trimRight(),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontFamily: 'monospace',
                                      height: 1.45,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _ExperienceSubmitDialog extends StatefulWidget {
  const _ExperienceSubmitDialog({required this.title});

  final String title;

  @override
  State<_ExperienceSubmitDialog> createState() =>
      _ExperienceSubmitDialogState();
}

class _ExperienceSubmitDialogState extends State<_ExperienceSubmitDialog> {
  void _submit() {
    Navigator.pop(context, const _ExperienceSubmitInput());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('提交经验审核'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            const Text(
              '本操作会提交当前本地经验包。需要脱敏时，请先启动脱敏任务生成本地副本，并预览确认后提交；客户端不会用规则改写或脱敏包内容。',
            ),
            const SizedBox(height: 12),
            Text(
              '提交目标：${ExperienceNetworkManagerClient.defaultManagerBaseUrl}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.cloud_upload_outlined, size: 18),
          label: const Text('提交审核'),
        ),
      ],
    );
  }
}

class _ExperienceReviewSyncDialog extends StatefulWidget {
  const _ExperienceReviewSyncDialog();

  @override
  State<_ExperienceReviewSyncDialog> createState() =>
      _ExperienceReviewSyncDialogState();
}

class _ExperienceReviewSyncDialogState
    extends State<_ExperienceReviewSyncDialog> {
  final _tokenCtrl = TextEditingController();

  @override
  void dispose() {
    _tokenCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final token = _textValue(_tokenCtrl.text);
    Navigator.pop(context, _ExperienceReviewSyncInput(bearerToken: token));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('取回审核签名'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _tokenCtrl,
              decoration: const InputDecoration(
                labelText: 'Bearer Token（可选）',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '来源：${ExperienceNetworkManagerClient.defaultManagerBaseUrl}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.verified_outlined, size: 18),
          label: const Text('开始'),
        ),
      ],
    );
  }
}

class _DhtBindDialog extends StatefulWidget {
  const _DhtBindDialog();

  @override
  State<_DhtBindDialog> createState() => _DhtBindDialogState();
}

class _DhtBindDialogState extends State<_DhtBindDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('绑定 DHT 管理公钥'),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _controller,
          decoration: const InputDecoration(
            labelText: '初始化密码',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.key_outlined, size: 18),
          label: const Text('绑定'),
        ),
      ],
    );
  }
}

class _DhtStatusDialog extends StatelessWidget {
  const _DhtStatusDialog({required this.status});

  final ExperienceDhtAdminStatus status;

  @override
  Widget build(BuildContext context) {
    final state = status.state;
    final publicNode = status.publicConfig?.nodeId ?? '';
    return AlertDialog(
      title: const Text('DHT 管理状态'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DhtStatusRow(label: '节点', value: state.nodeId),
            _DhtStatusRow(label: '绑定', value: state.bound ? '已绑定' : '未绑定'),
            if (status.boundHash.trim().isNotEmpty)
              _DhtStatusRow(label: '公钥指纹', value: status.boundHash),
            _DhtStatusRow(
              label: '公开模式',
              value: state.publicEnabled ? '开启' : '关闭',
            ),
            _DhtStatusRow(
              label: '注册状态',
              value: state.publicRegistered ? '已注册' : '未注册',
            ),
            if (state.publicManagerBaseUrl.trim().isNotEmpty)
              _DhtStatusRow(label: '管理端', value: state.publicManagerBaseUrl),
            if (state.bootstrapManagerBaseUrl.trim().isNotEmpty)
              _DhtStatusRow(
                label: '发现管理端',
                value: state.bootstrapManagerBaseUrl,
              ),
            if (publicNode.isNotEmpty)
              _DhtStatusRow(label: '公共节点', value: publicNode),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _DhtStatusRow extends StatelessWidget {
  const _DhtStatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value.isEmpty ? '-' : value)),
        ],
      ),
    );
  }
}

class _ExperienceDhtConfigInput {
  const _ExperienceDhtConfigInput({required this.config});

  final ExperienceDhtClientConfig config;
}

class _ExperienceDhtConfigDialog extends StatefulWidget {
  const _ExperienceDhtConfigDialog({
    required this.current,
    required this.isCreating,
  });

  final ExperienceDhtClientConfig current;
  final bool isCreating;

  @override
  State<_ExperienceDhtConfigDialog> createState() =>
      _ExperienceDhtConfigDialogState();
}

class _ExperienceDhtConfigDialogState
    extends State<_ExperienceDhtConfigDialog> {
  late final TextEditingController _adminCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _udpPortCtrl;
  late final TextEditingController _quicPortCtrl;
  late String _relayPolicy;
  late bool _udpEnabled;
  late bool _quicEnabled;
  String? _error;

  @override
  void initState() {
    super.initState();
    final current = widget.current;
    final endpoints = current.effectiveCandidateEndpoints;
    final udpEndpoints = endpoints.where((endpoint) => endpoint.isUdpCandidate);
    final quicEndpoints = endpoints.where((endpoint) => endpoint.isQuic);
    final udpEndpoint = udpEndpoints.isEmpty ? null : udpEndpoints.first;
    final quicEndpoint = quicEndpoints.isEmpty ? null : quicEndpoints.first;
    final firstEndpoint = endpoints.isEmpty ? null : endpoints.first;
    _adminCtrl = TextEditingController(text: current.adminBaseUrl);
    _hostCtrl = TextEditingController(text: firstEndpoint?.host ?? '');
    _udpPortCtrl = TextEditingController(
      text: udpEndpoint?.port.toString() ?? '41001',
    );
    _quicPortCtrl = TextEditingController(
      text: quicEndpoint?.port.toString() ?? '41002',
    );
    _udpEnabled = udpEndpoint != null || endpoints.isEmpty;
    _quicEnabled = quicEndpoint != null || endpoints.isEmpty;
    _relayPolicy = switch (current.relayPolicy) {
      ExperienceRelayPolicy.public => 'public',
      ExperienceRelayPolicy.disabled => 'disabled',
      ExperienceRelayPolicy.ownerOnly => 'owner_only',
    };
  }

  @override
  void dispose() {
    _adminCtrl.dispose();
    _hostCtrl.dispose();
    _udpPortCtrl.dispose();
    _quicPortCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final adminBaseUrl = _normalizeHttpUrlInput(_adminCtrl.text);
    if (adminBaseUrl.isEmpty) {
      setState(() => _error = '添加 DHT 节点需要填写公网访问 URL');
      return;
    }
    final parsedAdminBaseUrl = Uri.tryParse(adminBaseUrl);
    if (parsedAdminBaseUrl == null ||
        parsedAdminBaseUrl.host.isEmpty ||
        (parsedAdminBaseUrl.scheme != 'http' &&
            parsedAdminBaseUrl.scheme != 'https')) {
      setState(() => _error = 'DHT 公网访问 URL 必须是 http 或 https URL');
      return;
    }

    final host = _hostCtrl.text.trim().isNotEmpty
        ? _hostCtrl.text.trim()
        : parsedAdminBaseUrl.host;
    if (host.isEmpty) {
      setState(() => _error = '候选端点 Host 不能为空');
      return;
    }
    final candidateEndpoints = <ExperienceNetworkEndpoint>[];
    if (_quicEnabled) {
      final port = int.tryParse(_quicPortCtrl.text.trim()) ?? 0;
      if (port <= 0 || port > 65535) {
        setState(() => _error = 'QUIC 端口必须在 1-65535');
        return;
      }
      candidateEndpoints.add(
        ExperienceNetworkEndpoint(network: 'quic', host: host, port: port),
      );
    }
    if (_udpEnabled) {
      final port = int.tryParse(_udpPortCtrl.text.trim()) ?? 0;
      if (port <= 0 || port > 65535) {
        setState(() => _error = 'UDP 端口必须在 1-65535');
        return;
      }
      candidateEndpoints.add(
        ExperienceNetworkEndpoint(
          network: _networkNameForHost(host),
          host: host,
          port: port,
          requiresHolePunch: true,
        ),
      );
    }

    Navigator.pop(
      context,
      _ExperienceDhtConfigInput(
        config: ExperienceDhtClientConfig(
          mode: 'custom_private',
          candidateEndpoints: candidateEndpoints,
          relayPolicy: ExperienceRelayPolicy.fromWire(_relayPolicy),
          publicRegistrationEnabled: widget.current.publicRegistrationEnabled,
          adminBaseUrl: adminBaseUrl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    return AlertDialog(
      title: Text(widget.isCreating ? '添加 DHT 节点' : '编辑 DHT 节点'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '公网访问 URL 用于客户端连接、绑定、状态查询和公开开关；候选端点用于预探测与打洞。经验管理端使用客户端内置官方地址。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: c.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _adminCtrl,
                decoration: const InputDecoration(
                  labelText: 'DHT 公网访问 URL（http://IP:端口）',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _relayPolicy,
                decoration: const InputDecoration(
                  labelText: '转发策略',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'public', child: Text('public')),
                  DropdownMenuItem(
                    value: 'owner_only',
                    child: Text('owner_only'),
                  ),
                  DropdownMenuItem(value: 'disabled', child: Text('disabled')),
                ],
                onChanged: (value) =>
                    setState(() => _relayPolicy = value ?? 'owner_only'),
              ),
              const SizedBox(height: 16),
              Text(
                '候选端点',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: c.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Host 留空时使用公网访问 URL 的主机名。QUIC 优先尝试，传统 UDP 用于打洞探测，HTTP API 始终作为控制面和 relay 兜底。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: c.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _hostCtrl,
                decoration: const InputDecoration(
                  labelText: '候选端点 Host',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _quicEnabled,
                onChanged: (value) =>
                    setState(() => _quicEnabled = value ?? true),
                title: const Text('QUIC 候选端点'),
                subtitle: const Text(
                  '优先连接；基于 UDP，带加密握手和可靠传输能力，可能被部分企业网络或防火墙阻断。',
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              TextField(
                controller: _quicPortCtrl,
                enabled: _quicEnabled,
                decoration: const InputDecoration(
                  labelText: 'QUIC 端口',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _udpEnabled,
                onChanged: (value) =>
                    setState(() => _udpEnabled = value ?? true),
                title: const Text('传统 UDP 候选端点'),
                subtitle: const Text(
                  '用于 NAT 打洞和轻量探测；QUIC 协商失败时降级尝试，仍受 UDP 封锁影响。',
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              TextField(
                controller: _udpPortCtrl,
                enabled: _udpEnabled,
                decoration: const InputDecoration(
                  labelText: 'UDP 端口',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(
            widget.isCreating ? Icons.add_outlined : Icons.save_outlined,
            size: 18,
          ),
          label: Text(widget.isCreating ? '添加' : '保存'),
        ),
      ],
    );
  }
}

class _ProtocolLoginCodeResult {
  const _ProtocolLoginCodeResult({
    required this.code,
    required this.detail,
    required this.userId,
  });

  final String code;
  final ProtocolLoginChallengeDetail detail;
  final int userId;
}

class _ProtocolLoginCodeDialog extends StatefulWidget {
  const _ProtocolLoginCodeDialog({required this.onGenerate});

  final Future<_ProtocolLoginCodeResult> Function(String challenge) onGenerate;

  @override
  State<_ProtocolLoginCodeDialog> createState() =>
      _ProtocolLoginCodeDialogState();
}

class _ProtocolLoginCodeDialogState extends State<_ProtocolLoginCodeDialog> {
  final _controller = TextEditingController();
  _ProtocolLoginCodeResult? _result;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final challenge = _controller.text.trim();
    if (_busy || challenge.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final result = await widget.onGenerate(challenge);
      if (!mounted) return;
      setState(() => _result = result);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('登录授权 JSON 已复制')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    return AlertDialog(
      title: const Text('网页登录授权'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                minLines: 4,
                maxLines: 7,
                decoration: const InputDecoration(
                  labelText: '网页挑战码',
                  border: OutlineInputBorder(),
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              if (result != null) ...[
                const SizedBox(height: 16),
                _ProtocolLoginInfoRow(
                  label: '登录目标',
                  value: result.detail.serviceLabel,
                ),
                _ProtocolLoginInfoRow(
                  label: '用户 ID',
                  value: result.userId.toString(),
                ),
                _ProtocolLoginInfoRow(
                  label: '挑战 ID',
                  value: result.detail.challengeId,
                ),
                _ProtocolLoginInfoRow(
                  label: '过期时间',
                  value: _formatDialogTime(result.detail.expiresAtTime),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  result.code,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _generate,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.copy),
          label: const Text('生成并复制'),
        ),
      ],
    );
  }
}

class _ProtocolLoginInfoRow extends StatelessWidget {
  const _ProtocolLoginInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value.isEmpty ? '-' : value)),
        ],
      ),
    );
  }
}

String _formatDialogTime(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String _normalizeHttpUrlInput(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.contains('://')) return trimmed;
  return 'http://$trimmed';
}

String _networkNameForHost(String host) {
  final parsed = InternetAddress.tryParse(host.trim());
  if (parsed?.type == InternetAddressType.IPv6) return 'udp6';
  if (parsed?.type == InternetAddressType.IPv4) return 'udp4';
  return 'udp';
}

class _UserPowProgressDialog extends StatelessWidget {
  const _UserPowProgressDialog({required this.progress});

  final ValueListenable<UserPowProgress> progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('账号工作量证明'),
      content: SizedBox(
        width: 440,
        child: ValueListenableBuilder<UserPowProgress>(
          valueListenable: progress,
          builder: (context, value, _) {
            final fraction = value.fraction.clamp(0, 1).toDouble();
            final percent = (fraction * 100).clamp(0, 100).round();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: fraction),
                const SizedBox(height: 12),
                Text(
                  '$percent% · ${value.message}',
                  style: theme.textTheme.bodyMedium,
                ),
                if (value.stage == UserPowProgressStage.compute &&
                    value.total > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '已完成 ${value.completed}/${value.total} 个工作单位',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  '这个步骤用于防止黑灰产无限量刷号。正常用户只需要等待一次本机计算，未来难度提高时通常也应在几十秒到一分钟内完成；批量刷号者则需要为每个账号重复承担计算成本。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '计算在独立任务中进行，界面可以持续显示进度。请不要关闭窗口。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PubkeyRotationOutcome {
  const _PubkeyRotationOutcome({
    required this.registration,
    required this.result,
    required this.localPersisted,
    required this.gatewaySynced,
    this.warning,
  });

  final IdentityRegistration registration;
  final PubkeyRotationResult result;
  final bool localPersisted;
  final bool gatewaySynced;
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
            outcome.localPersisted
                ? (outcome.gatewaySynced
                      ? '轮换完成：本机身份已切换到新密钥，并已刷新通信通道。'
                      : '轮换完成：本机身份已切换到新密钥，通信通道待重连。')
                : '云端已完成轮换，但本机写入未完成。',
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
                  RecoveryCandidateMatrixTable(
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
                  RecoveryCandidateMatrixTable(
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
        parts.add('吞吐 ${formatRecoveryAttemptRate(attempted, elapsedMs)}');
      }
    }
    return parts.join(' · ');
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
              if (elapsedMs > 0)
                formatRecoveryAttemptRate(attempted, elapsedMs),
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
