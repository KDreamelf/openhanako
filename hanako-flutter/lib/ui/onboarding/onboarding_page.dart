// lib/ui/onboarding/onboarding_page.dart
//
// 子体首次启动引导（重写版）。
//
// 与原版（Provider + API Key 5 步）的区别：
//   - 砍掉"选 Provider / 填 API Key"步骤；过渡期 LLM 调用先走环境变量，
//     未来由用户登录 Hanako 账号后通过私有 AI 网关接管；
//   - 新增"生成账号 + 助记词 + 故事"流程：用户记忆故事即可下次登录，
//     不再需要传统密码或验证码。
//
// 步骤：
//   step 0: 欢迎，介绍子体定位
//   step 1: 账户昵称 + 用户名（沿用原项目 Hanako/User 默认值）
//   step 2: 新账号验证邮箱 / 既有账号恢复登录
//   step 3: 生成账号——展示 12 个中文名词 + 故事（LLM 未配置时使用 fallback 文案，让 UI 继续可用），要求用户保存
//   step 4: 用户勾选"已保存"→ 创建 agent，完成
//
// 规避 BUG-5：每一步右上角永远显示「跳过」。跳过后不创建身份，
// 仅创建匿名 agent；用户可在设置里再走"创建账号"流程。

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../identity/identity.dart';
import '../design/design.dart';
import '../widgets/recovery_matrix_table.dart';

enum _OnboardingAccountFlow { unknown, register, login }

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  // ---- 表单状态 -----------------------------------------------------------
  int _step = 0;
  String _agentName = 'Hanako';
  String _userName = 'User';
  String _email = '';
  String _emailCode = '';
  RegistrationEmailChallenge? _emailChallenge;
  static const String _defaultYuan = 'hanako';
  _OnboardingAccountFlow _accountFlow = _OnboardingAccountFlow.unknown;
  String _recoveryText = '';
  bool _confirmedSaved = false;

  // ---- 异步状态 -----------------------------------------------------------
  bool _busy = false;
  String? _error;

  /// 注册成功后的产物（供 step 3 / 4 显示）。
  IdentityRegistration? _registration;
  RegisterResult? _authResult;

  // 注册：0 欢迎 / 1 命名 / 2 邮箱验证 / 3 展示账号 / 4 确认保存
  // 登录：0 欢迎 / 1 命名 / 2 助记词恢复
  int get _totalSteps => _accountFlow == _OnboardingAccountFlow.login ? 3 : 5;

  int? _loginAttempted;
  int? _loginElapsedMs;
  int? _loginDistance;
  int? _loginCombinationId;
  StoryRecoveryProgressStage? _loginRecoveryPhase;
  List<List<int>> _loginMatrix = const [];
  List<String> _loginAnchors = const [];
  int _loginCandidatesPerColumn = 0;
  bool _loginUsedLlm = false;
  List<int> _loginCandidateRanks = const [];
  List<int> _loginWordIds = const [];
  List<int> _loginActivePositions = const [];
  Timer? _emailCooldownTimer;
  int _emailCooldownRemaining = 0;

  bool _canNext() {
    switch (_step) {
      case 0:
        return true;
      case 1:
        return _agentName.trim().isNotEmpty &&
            _userName.trim().isNotEmpty &&
            _userName.trim().length <= 32;
      case 2:
        if (_accountFlow == _OnboardingAccountFlow.login) {
          return _recoveryText.trim().isNotEmpty;
        }
        return _email.trim().isNotEmpty &&
            _email.contains('@') &&
            _emailChallenge != null &&
            _emailCode.trim().length >= 6;
      case 3:
        return _registration != null;
      case 4:
        return _confirmedSaved;
      default:
        return true;
    }
  }

  void _clearLoginRecoveryProgress() {
    _loginAttempted = null;
    _loginElapsedMs = null;
    _loginDistance = null;
    _loginCombinationId = null;
    _loginRecoveryPhase = null;
    _loginMatrix = const [];
    _loginAnchors = const [];
    _loginCandidatesPerColumn = 0;
    _loginUsedLlm = false;
    _loginCandidateRanks = const [];
    _loginWordIds = const [];
    _loginActivePositions = const [];
  }

  void _applyLoginRecoveryProgress(StoryRecoveryProgress progress) {
    _loginRecoveryPhase = progress.stage;
    switch (progress.stage) {
      case StoryRecoveryProgressStage.aiSemanticAnalysis:
        break;
      case StoryRecoveryProgressStage.matrixReady:
        _loginMatrix = progress.columns;
        _loginAnchors = progress.anchors;
        _loginCandidatesPerColumn = progress.candidatesPerColumn;
        _loginUsedLlm = progress.usedLlm;
        break;
      case StoryRecoveryProgressStage.matrixRecovery:
        _loginAttempted = progress.attempted;
        _loginElapsedMs = progress.elapsedMs;
        _loginDistance = progress.currentHammingDistance;
        _loginCombinationId = progress.combinationId;
        _loginCandidateRanks = progress.candidateRanks;
        _loginWordIds = progress.wordIds;
        _loginActivePositions = progress.activePositions;
        break;
    }
  }

  /// step 1 → step 2：先向认证中心核验用户名。
  ///
  /// 用户名可用则进入新账号注册；已存在则进入既有账号恢复登录。
  Future<void> _resolveUsernameAndContinue() async {
    if (_busy || !_canNext()) return;
    final username = _userName.trim();
    setState(() {
      _busy = true;
      _error = null;
      _clearLoginRecoveryProgress();
      _emailChallenge = null;
      _emailCode = '';
      _registration = null;
      _authResult = null;
      _confirmedSaved = false;
    });
    try {
      final eng = ref.read(engineProvider);
      final availability = await eng.backendClient.checkUsernameAvailability(
        username,
      );
      if (!mounted) return;
      setState(() {
        _accountFlow = availability.available
            ? _OnboardingAccountFlow.register
            : _OnboardingAccountFlow.login;
        _step = 2;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '无法核验用户名：${_formatBackendError(e)}';
        _busy = false;
      });
    }
  }

  /// 注册流程：发送邮箱验证码。
  Future<void> _sendRegistrationEmailCode() async {
    if (_busy || _emailCooldownRemaining > 0) return;
    final username = _userName.trim();
    final email = _email.trim();
    if (username.isEmpty || email.isEmpty || !email.contains('@')) {
      setState(() => _error = '请输入有效邮箱。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _emailChallenge = null;
      _registration = null;
      _authResult = null;
      _confirmedSaved = false;
    });
    try {
      final eng = ref.read(engineProvider);
      final challenge = await eng.backendClient.startRegistrationEmail(
        username: username,
        email: email,
      );
      if (!mounted) return;
      _startEmailCooldown(challenge.cooldownSeconds);
      setState(() {
        _emailChallenge = challenge;
        _emailCode = '';
        _error = '验证码已发送至 ${challenge.delivery}。';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      final retryAfter = _retryAfterSeconds(e);
      if (retryAfter > 0) {
        _startEmailCooldown(retryAfter);
      }
      setState(() {
        _error = '发送验证码失败：${_formatBackendError(e)}';
        _busy = false;
      });
    }
  }

  void _handleRegistrationEmailChanged(String value) {
    _stopEmailCooldown();
    setState(() {
      _email = value;
      _emailChallenge = null;
      _emailCode = '';
      _registration = null;
      _authResult = null;
      _confirmedSaved = false;
    });
  }

  void _startEmailCooldown(int seconds) {
    final normalized = seconds <= 0 ? 60 : seconds;
    _emailCooldownTimer?.cancel();
    if (!mounted) return;
    setState(() => _emailCooldownRemaining = normalized);
    _emailCooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_emailCooldownRemaining <= 1) {
        timer.cancel();
        setState(() => _emailCooldownRemaining = 0);
        return;
      }
      setState(() => _emailCooldownRemaining--);
    });
  }

  void _stopEmailCooldown() {
    _emailCooldownTimer?.cancel();
    _emailCooldownTimer = null;
    if (mounted && _emailCooldownRemaining != 0) {
      setState(() => _emailCooldownRemaining = 0);
    } else {
      _emailCooldownRemaining = 0;
    }
  }

  /// step 2：生成未落盘身份，并携邮箱验证码提交注册；成功后再写本机 vault。
  Future<void> _generateIdentityAndRegister() async {
    if (_busy || !_canNext()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(identityRepositoryProvider);
    try {
      final eng = ref.read(engineProvider);
      final reg = await repo.generateRegistrationPreview();
      final auth = await eng.backendClient.register(
        keyPair: reg.identity.keyPair,
        username: _userName.trim(),
        nickname: _agentName.trim(),
        email: _email.trim(),
        emailChallengeId: _emailChallenge!.challengeId,
        emailCode: _emailCode.trim(),
      );
      await repo.replaceCurrentIdentity(reg.identity);
      if (!mounted) return;
      setState(() {
        _registration = reg;
        _authResult = auth;
        _step = 3;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _registration = null;
        _authResult = null;
        _confirmedSaved = false;
        _error = '生成账号失败：${_formatBackendError(e)}';
        _busy = false;
      });
    }
  }

  /// 完成：写 agent + config，把已注册公钥与 agent 绑定。
  Future<void> _finish() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final reg = _registration!;
      final auth = _authResult!;
      await _activateAgentWithIdentity(identity: reg.identity, auth: auth);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '完成失败：${_formatBackendError(e)}';
        _busy = false;
      });
    }
  }

  /// 既有用户名：用助记词 / 记忆故事恢复本地私钥，然后向认证中心确认身份。
  Future<void> _loginExistingIdentity() async {
    if (_busy || !_canNext()) return;
    setState(() {
      _busy = true;
      _error = null;
      _clearLoginRecoveryProgress();
    });
    try {
      final eng = ref.read(engineProvider);
      final repo = ref.read(identityRepositoryProvider);
      final username = _userName.trim();
      final hashes = await eng.backendClient.fetchRecoveryCandidates(username);
      if (hashes.isEmpty) {
        throw StateError('认证中心未返回该用户名的可恢复公钥');
      }

      final outcome = await repo.loginWithStory(
        storyOrWords: _recoveryText.trim(),
        targetPublicKeyHashes: hashes.toSet(),
        softDeadline: const Duration(minutes: 5),
        hardDeadline: const Duration(minutes: 10),
        onRecoveryProgress: (progress) {
          if (!mounted) return;
          setState(() => _applyLoginRecoveryProgress(progress));
        },
      );
      if (!outcome.success) {
        if (!mounted) return;
        setState(() {
          _error = outcome.malformed
              ? '无法解析助记词或故事；可直接粘贴 12 个名词。'
              : outcome.timedOut
              ? '恢复超时，请确认用户名和 12 个名词是否匹配。'
              : '未能恢复该账号，请确认用户名和助记词顺序。';
          _busy = false;
          _loginAttempted = outcome.attempted;
          _loginElapsedMs = outcome.elapsedMs;
          _loginDistance = outcome.hammingDistance;
          _loginCombinationId = outcome.attempted;
          _loginMatrix = outcome.parsedColumns;
          _loginAnchors = outcome.anchors;
          _loginCandidatesPerColumn = outcome.candidatesPerColumn;
          _loginUsedLlm = outcome.usedLlm;
          _loginCandidateRanks = const [];
          _loginWordIds = const [];
          _loginActivePositions = const [];
        });
        return;
      }

      final identity = outcome.identity!;
      final auth = await eng.backendClient.login(
        keyPair: identity.keyPair,
        username: username,
      );
      await _activateAgentWithIdentity(identity: identity, auth: auth);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '登录失败：${_formatBackendError(e)}';
        _busy = false;
      });
    }
  }

  Future<void> _activateAgentWithIdentity({
    required HanakoIdentity identity,
    required RegisterResult auth,
  }) async {
    final eng = ref.read(engineProvider);

    final agent = await eng.agentManager.createAgent(
      name: _agentName.trim(),
      yuan: _defaultYuan,
    );
    await eng.agentManager.switchAgent(agent.id);
    eng.config.retarget(agent.id);
    eng.preferences.savePrimaryAgent(agent.id);

    eng.config.writeAt(['user', 'name'], _userName.trim());
    eng.config.writeAt(['identity', 'public_key'], identity.publicKeyHex);
    eng.config.writeAt(['identity', 'public_key_hash'], identity.publicKeyHash);
    eng.config.writeAt(['auth', 'user_id'], auth.userId);
    eng.config.writeAt(['auth', 'username'], auth.username);
    eng.config.writeAt(['auth', 'tier'], auth.tier);
    eng.config.writeAt(['auth', 'pubkey_hash'], auth.pubkeyHash);
    ref.read(identityRevisionProvider.notifier).state++;

    // 非阻塞同步 AI 网关授权模型列表；服务器未部署时不阻断引导完成。
    try {
      await eng.syncGatewayModels(identity);
    } catch (_) {}

    ref.read(activeAgentIdProvider.notifier).state = agent.id;
    ref.invalidate(agentListProvider);

    if (mounted) Navigator.of(context).pop(true);
  }

  /// 跳过：不创建身份，只创建一个匿名 agent，让用户能进入主界面。
  /// 之后可在设置里手动走"创建账号"。
  Future<void> _skip() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final eng = ref.read(engineProvider);
      final agent = await eng.agentManager.createAgent(
        name: _agentName.trim().isEmpty ? 'Hanako' : _agentName.trim(),
        yuan: _defaultYuan,
      );
      await eng.agentManager.switchAgent(agent.id);
      eng.config.retarget(agent.id);
      eng.preferences.savePrimaryAgent(agent.id);
      ref.read(activeAgentIdProvider.notifier).state = agent.id;
      ref.invalidate(agentListProvider);
    } catch (_) {
      // 跳过流程中若失败也不挡用户——直接关掉引导。
    }
    if (mounted) Navigator.of(context).pop(false);
  }

  void _goBack() {
    if (_step == 2) {
      _stopEmailCooldown();
    }
    setState(() {
      if (_step == 2) {
        _accountFlow = _OnboardingAccountFlow.unknown;
      }
      _error = null;
      _step--;
    });
  }

  String _formatBackendError(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      final data = error.response?.data;
      if (status == 429) {
        final retryAfter = _retryAfterSeconds(error);
        if (retryAfter > 0) {
          return '操作太频繁，请 $retryAfter 秒后再试。';
        }
        return '操作太频繁，请稍后再试。';
      }
      if (data is Map) {
        final message = data['message'];
        final code = data['error'];
        if (code == 'email_taken') {
          return '该邮箱已绑定其他账号，请更换邮箱或登录原账号。';
        }
        if (code == 'username_taken') {
          return '用户名已被占用，请返回上一步重新核验或更换用户名。';
        }
        if (message is String && message.trim().isNotEmpty) {
          return message;
        }
        if (code is String && code.trim().isNotEmpty) {
          return code;
        }
      }
      if (status == 409) {
        return '用户名或邮箱已被占用，请返回上一步检查后重试。';
      }
      if (status == 401) {
        return '身份验证失败，请确认用户名与助记词是否匹配。';
      }
      if (status != null) return '认证中心返回 HTTP $status';
      return '无法连接认证中心';
    }
    return '$error';
  }

  int _retryAfterSeconds(Object error) {
    if (error is! DioException) return 0;
    final data = error.response?.data;
    if (data is Map) {
      final value = data['retry_after'];
      if (value is num && value > 0) return value.ceil();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    final header = error.response?.headers.value('retry-after');
    final parsed = int.tryParse((header ?? '').trim());
    if (parsed != null && parsed > 0) return parsed;
    return 0;
  }

  @override
  void dispose() {
    _emailCooldownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: Column(
          children: [
            _OnboardingHeader(
              currentStep: _step,
              totalSteps: _totalSteps,
              busy: _busy,
              onSkip: _busy ? null : _skip,
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth:
                        _step == 2 && _accountFlow == _OnboardingAccountFlow.login
                            ? 880
                            : 620,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      DS.s24,
                      DS.s24,
                      DS.s24,
                      DS.s24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildStep(),
                        if (_error != null) ...[
                          const SizedBox(height: DS.s14),
                          HanaBanner(
                            icon: Icons.error_outline_rounded,
                            title: '出错了',
                            subtitle: _error!,
                            color: palette.accentCrimson,
                          ),
                        ],
                        const SizedBox(height: DS.s24),
                        _buildButtons(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return const _StepWelcome();
      case 1:
        return _StepNames(
          agentName: _agentName,
          userName: _userName,
          onAgentNameChanged: (v) => setState(() => _agentName = v),
          onUserNameChanged: (v) => setState(() {
            _userName = v;
            _accountFlow = _OnboardingAccountFlow.unknown;
            _emailChallenge = null;
            _emailCode = '';
            _clearLoginRecoveryProgress();
          }),
        );
      case 2:
        if (_accountFlow == _OnboardingAccountFlow.login) {
          return _StepExistingLogin(
            userName: _userName.trim(),
            recoveryText: _recoveryText,
            busy: _busy,
            phase: _loginRecoveryPhase,
            attempted: _loginAttempted,
            elapsedMs: _loginElapsedMs,
            distance: _loginDistance,
            combinationId: _loginCombinationId,
            matrix: _loginMatrix,
            anchors: _loginAnchors,
            candidatesPerColumn: _loginCandidatesPerColumn,
            usedLlm: _loginUsedLlm,
            candidateRanks: _loginCandidateRanks,
            wordIds: _loginWordIds,
            activePositions: _loginActivePositions,
            onRecoveryTextChanged: (v) => setState(() {
              _recoveryText = v;
              _error = null;
              _clearLoginRecoveryProgress();
            }),
          );
        }
        return _StepRegistrationEmail(
          email: _email,
          code: _emailCode,
          challenge: _emailChallenge,
          busy: _busy,
          cooldownRemaining: _emailCooldownRemaining,
          onEmailChanged: _handleRegistrationEmailChanged,
          onCodeChanged: (v) => setState(() => _emailCode = v),
          onSendCode: _sendRegistrationEmailCode,
        );
      case 3:
        return _StepShowAccount(registration: _registration);
      case 4:
        return _StepConfirmSaved(
          registration: _registration!,
          confirmed: _confirmedSaved,
          onChanged: (v) => setState(() => _confirmedSaved = v),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildButtons() {
    return Row(
      children: [
        if (_step > 0 &&
            !(_step == 3 && _accountFlow == _OnboardingAccountFlow.register))
          // 在"展示账号"步骤不允许回退（因为后退会丢掉已生成的助记词）
          OutlinedButton(
            onPressed: _busy ? null : _goBack,
            child: const Text('上一步'),
          ),
        const Spacer(),
        if (_step == 1)
          FilledButton.icon(
            onPressed: _busy || !_canNext()
                ? null
                : _resolveUsernameAndContinue,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.manage_accounts),
            label: const Text('继续'),
          )
        else if (_step == 2 && _accountFlow == _OnboardingAccountFlow.login)
          FilledButton.icon(
            onPressed: _busy || !_canNext() ? null : _loginExistingIdentity,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: const Text('登录'),
          )
        else if (_step == 2 && _accountFlow == _OnboardingAccountFlow.register)
          FilledButton.icon(
            onPressed: _busy || !_canNext()
                ? null
                : _generateIdentityAndRegister,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.vpn_key),
            label: const Text('生成账号'),
          )
        else if (_step < _totalSteps - 1)
          FilledButton(
            onPressed: _busy || !_canNext()
                ? null
                : () => setState(() => _step++),
            child: const Text('下一步'),
          )
        else
          FilledButton.icon(
            onPressed: _busy || !_canNext() ? null : _finish,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: const Text('完成'),
          ),
      ],
    );
  }
}

// ===========================================================================
//  Header
// ===========================================================================
class _OnboardingHeader extends StatelessWidget {
  const _OnboardingHeader({
    required this.currentStep,
    required this.totalSteps,
    required this.busy,
    required this.onSkip,
  });

  final int currentStep;
  final int totalSteps;
  final bool busy;
  final VoidCallback? onSkip;

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
          padding: const EdgeInsets.fromLTRB(DS.s20, DS.s14, DS.s20, DS.s12),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          palette.accentEmerald,
                          palette.accentCyan,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(DS.r8),
                      boxShadow: [
                        BoxShadow(
                          color: palette.accentEmerald.withValues(alpha: 0.42),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.auto_awesome_rounded,
                      size: 18,
                      color: palette.isDark
                          ? const Color(0xFF06120A)
                          : Colors.white,
                    ),
                  ),
                  const SizedBox(width: DS.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              'PH01 SUBBODY',
                              style: TextStyle(
                                color: palette.textTertiary,
                                fontSize: DS.t10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.6,
                              ),
                            ),
                            const SizedBox(width: DS.s10),
                            Text(
                              'STEP ${currentStep + 1} / $totalSteps',
                              style: TextStyle(
                                color: palette.accentEmerald,
                                fontSize: DS.t10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '欢迎使用 PH01 子体',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t18,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                      ],
                    ),
                  ),
                  GlassButton(
                    label: '跳过',
                    icon: Icons.skip_next_rounded,
                    dense: true,
                    onPressed: onSkip,
                  ),
                ],
              ),
              const SizedBox(height: DS.s12),
              _OnboardingProgressBar(
                currentStep: currentStep,
                totalSteps: totalSteps,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingProgressBar extends StatelessWidget {
  const _OnboardingProgressBar({
    required this.currentStep,
    required this.totalSteps,
  });

  final int currentStep;
  final int totalSteps;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        for (var i = 0; i < totalSteps; i++)
          Expanded(
            child: Container(
              margin: EdgeInsets.only(right: i < totalSteps - 1 ? 4 : 0),
              height: 3,
              decoration: BoxDecoration(
                color: i <= currentStep
                    ? palette.accentEmerald
                    : palette.divider,
                borderRadius: BorderRadius.circular(2),
                boxShadow: i <= currentStep
                    ? [
                        BoxShadow(
                          color: palette.accentEmerald.withValues(alpha: 0.36),
                          blurRadius: 6,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

// ===========================================================================
//  step 0 · 欢迎
// ===========================================================================
class _StepWelcome extends StatelessWidget {
  const _StepWelcome();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                palette.accentEmerald,
                palette.accentCyan,
                palette.accentLavender,
              ],
            ),
            borderRadius: BorderRadius.circular(DS.r20),
            boxShadow: [
              BoxShadow(
                color: palette.accentEmerald.withValues(alpha: 0.42),
                blurRadius: 24,
                spreadRadius: 2,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Icon(
            Icons.auto_awesome_rounded,
            size: 40,
            color: palette.isDark ? const Color(0xFF06120A) : Colors.white,
          ),
        ),
        const SizedBox(height: DS.s20),
        Text(
          '欢迎使用 PH01 子体',
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: DS.t26,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: DS.s10),
        Text(
          '你的私人 AI 子体，带有本地身份、长期记忆与桌面工作流。',
          style: TextStyle(
            color: palette.textSecondary,
            fontSize: DS.t14,
            height: 1.6,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: DS.s24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('账号说明', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Text(
                  '我们不使用传统密码——你将获得 12 个中文名词组成的助记词，'
                  '以及一段帮你记忆的小故事。记住故事，就能在任何设备上找回身份。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '接下来会先确认用户名；新用户名验证邮箱后创建账号，已有用户名进入登录恢复。',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ===========================================================================
//  step 1 · 命名
// ===========================================================================
class _StepNames extends StatelessWidget {
  const _StepNames({
    required this.agentName,
    required this.userName,
    required this.onAgentNameChanged,
    required this.onUserNameChanged,
  });

  final String agentName;
  final String userName;
  final ValueChanged<String> onAgentNameChanged;
  final ValueChanged<String> onUserNameChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final usernameTooLong = userName.trim().length > 32;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepHeading(
          icon: Icons.account_circle_outlined,
          title: '你的账号',
          subtitle: '为子体取一个名字；用户名是云端账号的唯一标识。',
          accent: palette.accentEmerald,
        ),
        const SizedBox(height: DS.s16),
        TextFormField(
          initialValue: agentName,
          decoration: const InputDecoration(
            labelText: '账户昵称',
            helperText: '用于认证中心显示；当前也会作为本机默认 Agent 名称',
            border: OutlineInputBorder(),
          ),
          onChanged: onAgentNameChanged,
        ),
        const SizedBox(height: DS.s12),
        TextFormField(
          initialValue: userName,
          decoration: InputDecoration(
            labelText: '用户名',
            helperText: '用于账号登录与恢复，需全局唯一；已存在时会进入登录流程',
            border: const OutlineInputBorder(),
            errorText: usernameTooLong ? '用户名最多 32 个字符' : null,
          ),
          onChanged: onUserNameChanged,
        ),
      ],
    );
  }
}

// ===========================================================================
//  step 2 · 注册邮箱验证
// ===========================================================================
class _StepRegistrationEmail extends StatelessWidget {
  const _StepRegistrationEmail({
    required this.email,
    required this.code,
    required this.challenge,
    required this.busy,
    required this.cooldownRemaining,
    required this.onEmailChanged,
    required this.onCodeChanged,
    required this.onSendCode,
  });

  final String email;
  final String code;
  final RegistrationEmailChallenge? challenge;
  final bool busy;
  final int cooldownRemaining;
  final ValueChanged<String> onEmailChanged;
  final ValueChanged<String> onCodeChanged;
  final VoidCallback onSendCode;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final emailReady = email.trim().isNotEmpty && email.contains('@');
    final canSend = !busy && emailReady && cooldownRemaining <= 0;
    final sendLabel = cooldownRemaining > 0
        ? '$cooldownRemaining 秒后重发'
        : challenge == null
        ? '发送验证码'
        : '重新发送';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepHeading(
          icon: Icons.mark_email_unread_outlined,
          title: '验证邮箱',
          subtitle: '邮箱用于注册确认与后续恢复二次校验。验证码通过后，本机会生成私钥和助记词，再提交公钥完成注册。',
          accent: palette.accentCyan,
        ),
        const SizedBox(height: DS.s16),
        TextFormField(
          initialValue: email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: '邮箱',
            helperText: '请填写你能长期访问的邮箱',
            border: OutlineInputBorder(),
          ),
          onChanged: onEmailChanged,
        ),
        const SizedBox(height: DS.s12),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey(challenge?.challengeId ?? 'registration-code'),
                initialValue: code,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: InputDecoration(
                  labelText: '邮箱验证码',
                  helperText: challenge == null
                      ? '先发送验证码'
                      : '已发送至 ${challenge!.delivery}',
                  border: const OutlineInputBorder(),
                ),
                onChanged: onCodeChanged,
              ),
            ),
            const SizedBox(width: DS.s12),
            OutlinedButton.icon(
              onPressed: canSend ? onSendCode : null,
              icon: Icon(
                cooldownRemaining > 0
                    ? Icons.hourglass_top_rounded
                    : challenge == null
                        ? Icons.send_rounded
                        : Icons.refresh_rounded,
                size: 16,
              ),
              label: Text(sendLabel),
            ),
          ],
        ),
        if (challenge != null) ...[
          const SizedBox(height: DS.s12),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: DS.s12,
              vertical: DS.s10,
            ),
            decoration: BoxDecoration(
              color:
                  palette.accentEmerald.withValues(alpha: palette.isDark ? 0.10 : 0.08),
              borderRadius: BorderRadius.circular(DS.r8),
              border: Border.all(
                color: palette.accentEmerald.withValues(alpha: 0.30),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.mark_email_read_outlined,
                  size: 14,
                  color: palette.accentEmerald,
                ),
                const SizedBox(width: DS.s8),
                Expanded(
                  child: Text(
                    '已发送至 ${challenge!.delivery}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Color.lerp(
                        palette.textSecondary,
                        palette.accentEmerald,
                        0.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ===========================================================================
//  step 2 · 既有账号登录
// ===========================================================================
class _StepExistingLogin extends StatelessWidget {
  const _StepExistingLogin({
    required this.userName,
    required this.recoveryText,
    required this.busy,
    required this.phase,
    required this.attempted,
    required this.elapsedMs,
    required this.distance,
    required this.combinationId,
    required this.matrix,
    required this.anchors,
    required this.candidatesPerColumn,
    required this.usedLlm,
    required this.candidateRanks,
    required this.wordIds,
    required this.activePositions,
    required this.onRecoveryTextChanged,
  });

  final String userName;
  final String recoveryText;
  final bool busy;
  final StoryRecoveryProgressStage? phase;
  final int? attempted;
  final int? elapsedMs;
  final int? distance;
  final int? combinationId;
  final List<List<int>> matrix;
  final List<String> anchors;
  final int candidatesPerColumn;
  final bool usedLlm;
  final List<int> candidateRanks;
  final List<int> wordIds;
  final List<int> activePositions;
  final ValueChanged<String> onRecoveryTextChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final showProgress =
        phase != null ||
        attempted != null ||
        matrix.isNotEmpty ||
        anchors.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepHeading(
          icon: Icons.key_outlined,
          title: '登录已有账号',
          subtitle: '用户名 $userName 已存在。请输入这个账号保存的 12 个名词或记忆故事。',
          accent: palette.accentLavender,
        ),
        const SizedBox(height: DS.s16),
        TextFormField(
          initialValue: recoveryText,
          minLines: 3,
          maxLines: 6,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: '12 个名词或记忆故事',
            helperText: '直接粘贴 12 个名词时不依赖 AI 网关',
            border: OutlineInputBorder(),
          ),
          onChanged: onRecoveryTextChanged,
        ),
        if (showProgress) ...[
          const SizedBox(height: DS.s12),
          if (busy) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                minHeight: 3,
                color: palette.accentLavender,
                backgroundColor: palette.divider,
              ),
            ),
            const SizedBox(height: DS.s10),
          ],
          Text(
            _loginRecoveryProgressText(),
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.textSecondary,
            ),
          ),
          if (matrix.isNotEmpty || anchors.isNotEmpty) ...[
            const SizedBox(height: DS.s12),
            RecoveryCandidateMatrixTable(
              matrix: matrix,
              anchors: anchors,
              candidatesPerColumn: candidatesPerColumn,
              usedLlm: usedLlm,
              hammingDistance: distance ?? 0,
              attempted: attempted ?? 0,
              elapsedMs: elapsedMs ?? 0,
              combinationId: combinationId,
              candidateRanks: candidateRanks,
              wordIds: wordIds,
              activePositions: activePositions,
            ),
          ],
        ],
      ],
    );
  }

  String _loginRecoveryProgressText() {
    if (phase == StoryRecoveryProgressStage.aiSemanticAnalysis) {
      return '正在进行AI语义分析';
    }
    if (phase == StoryRecoveryProgressStage.matrixReady) {
      final completedRows = matrix.where((row) => row.isNotEmpty).length;
      if (completedRows < anchors.length) {
        return '已提取故事锚点，正在并发生成候选词 · $completedRows/${anchors.length}';
      }
      return '候选矩阵已生成，准备开始矩阵恢复';
    }
    final parts = <String>[busy ? '正在恢复' : '恢复结束'];
    final currentAttempted = attempted;
    final currentElapsedMs = elapsedMs;
    final currentDistance = distance;
    if (currentAttempted != null) parts.add('已尝试 $currentAttempted 次');
    if (combinationId != null) parts.add('组合 #$combinationId');
    if (currentDistance != null) parts.add('距离 $currentDistance');
    if (currentElapsedMs != null) {
      parts.add('耗时 ${(currentElapsedMs / 1000).toStringAsFixed(1)} 秒');
      if (currentAttempted != null) {
        parts.add(
          '吞吐 ${formatRecoveryAttemptRate(currentAttempted, currentElapsedMs)}',
        );
      }
    }
    return parts.join(' · ');
  }
}

// ===========================================================================
//  step 3 · 展示账号
// ===========================================================================
class _StepShowAccount extends StatelessWidget {
  const _StepShowAccount({required this.registration});

  final IdentityRegistration? registration;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (registration == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: DS.s40),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_fix_high_outlined,
                size: 36,
                color: palette.textTertiary,
              ),
              const SizedBox(height: DS.s10),
              Text(
                '点击下方按钮生成账号…',
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: DS.t13,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final reg = registration!;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepHeading(
          icon: Icons.check_circle_outline_rounded,
          title: '你的账号已生成',
          subtitle: '请把下面的 12 个名词与故事保存好（截图、抄写或打印均可）。'
              '丢失它们将无法在新设备登录此账号。',
          accent: palette.accentEmerald,
        ),
        const SizedBox(height: DS.s16),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                palette.bgFloating.withValues(alpha: palette.isDark ? 0.55 : 0.94),
                palette.bgRaised.withValues(alpha: palette.isDark ? 0.45 : 0.86),
              ],
            ),
            borderRadius: BorderRadius.circular(DS.r12),
            border: Border.all(
              color: palette.accentEmerald.withValues(alpha: 0.30),
            ),
            boxShadow: [
              BoxShadow(
                color: palette.accentEmerald.withValues(alpha: 0.12),
                blurRadius: 24,
                spreadRadius: -8,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.all(DS.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.list_alt_rounded,
                    size: 18,
                    color: palette.accentEmerald,
                  ),
                  const SizedBox(width: DS.s8),
                  Text(
                    '12 个名词（有序）',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: DS.t14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const Spacer(),
                  GlassIconButton(
                    icon: Icons.copy_rounded,
                    tooltip: '复制名词',
                    size: 30,
                    iconSize: 15,
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: reg.words.join(' ')),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('名词已复制到剪贴板')),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: DS.s10),
              Wrap(
                spacing: DS.s8,
                runSpacing: DS.s8,
                children: [
                  for (var i = 0; i < reg.words.length; i++)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: DS.s10,
                        vertical: DS.s6,
                      ),
                      decoration: BoxDecoration(
                        color: palette.accentEmerald
                            .withValues(alpha: palette.isDark ? 0.12 : 0.10),
                        borderRadius: BorderRadius.circular(DS.r8),
                        border: Border.all(
                          color: palette.accentEmerald.withValues(alpha: 0.30),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${i + 1}',
                            style: TextStyle(
                              color: palette.accentEmerald
                                  .withValues(alpha: 0.75),
                              fontSize: DS.t10,
                              fontWeight: FontWeight.w700,
                              fontFamilyFallback: DS.monoFallback,
                            ),
                          ),
                          const SizedBox(width: DS.s8),
                          Text(
                            reg.words[i],
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: DS.t13,
                              fontWeight: FontWeight.w600,
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
        const SizedBox(height: DS.s14),
        Container(
          decoration: BoxDecoration(
            color: palette.accentLavender
                .withValues(alpha: palette.isDark ? 0.08 : 0.06),
            borderRadius: BorderRadius.circular(DS.r12),
            border: Border.all(
              color: palette.accentLavender.withValues(alpha: 0.28),
            ),
          ),
          padding: const EdgeInsets.all(DS.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.menu_book_rounded,
                    size: 18,
                    color: palette.accentLavender,
                  ),
                  const SizedBox(width: DS.s8),
                  Text(
                    '记忆故事',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: DS.t14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: DS.s10),
              if (reg.fallback)
                Text(
                  '当前未配置 LLM，故事尚未生成。'
                  '进入主界面后可让子体随时帮你编一段。',
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: DS.t13,
                    fontStyle: FontStyle.italic,
                    height: 1.55,
                  ),
                )
              else
                SelectableText(
                  reg.story,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: DS.t14,
                    height: 1.65,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: DS.s12),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: DS.s10,
            vertical: DS.s8,
          ),
          decoration: BoxDecoration(
            color: palette.bgDeep.withValues(alpha: palette.isDark ? 0.5 : 0.40),
            borderRadius: BorderRadius.circular(DS.r8),
            border: Border.all(color: palette.divider),
          ),
          child: Row(
            children: [
              Icon(
                Icons.fingerprint_rounded,
                size: 14,
                color: palette.textTertiary,
              ),
              const SizedBox(width: DS.s8),
              Expanded(
                child: SelectableText(
                  '公钥指纹：${reg.identity.publicKeyHash.substring(0, 16)}…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.textSecondary,
                    fontFamilyFallback: DS.monoFallback,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
//  step 4 · 确认已保存
// ===========================================================================
class _StepConfirmSaved extends StatelessWidget {
  const _StepConfirmSaved({
    required this.registration,
    required this.confirmed,
    required this.onChanged,
  });

  final IdentityRegistration registration;
  final bool confirmed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepHeading(
          icon: Icons.task_alt_rounded,
          title: '确认保存',
          subtitle: '一旦点击「完成」，引导页将关闭。请再次确认你已经妥善保管以下信息：',
          accent: palette.accentAmber,
        ),
        const SizedBox(height: DS.s12),
        Container(
          decoration: BoxDecoration(
            color: palette.bgRaised
                .withValues(alpha: palette.isDark ? 0.66 : 0.90),
            borderRadius: BorderRadius.circular(DS.r10),
            border: Border.all(color: palette.divider),
          ),
          padding: const EdgeInsets.all(DS.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ChecklistLine(text: '12 个名词（按顺序）', color: palette.accentEmerald),
              _ChecklistLine(
                text: registration.fallback
                    ? '故事尚未生成，仅靠名词记忆'
                    : '记忆故事',
                color: palette.accentLavender,
              ),
              _ChecklistLine(
                text: '本机身份 vault（由 Windows 当前用户保护）',
                color: palette.accentCyan,
              ),
            ],
          ),
        ),
        const SizedBox(height: DS.s16),
        Material(
          color: confirmed
              ? palette.accentEmerald
                  .withValues(alpha: palette.isDark ? 0.12 : 0.10)
              : palette.glassFill,
          borderRadius: BorderRadius.circular(DS.r10),
          child: InkWell(
            borderRadius: BorderRadius.circular(DS.r10),
            onTap: () => onChanged(!confirmed),
            child: Padding(
              padding: const EdgeInsets.all(DS.s12),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: DS.dFast,
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: confirmed
                          ? palette.accentEmerald
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(DS.r4),
                      border: Border.all(
                        color: confirmed
                            ? palette.accentEmerald
                            : palette.textTertiary,
                        width: 1.4,
                      ),
                    ),
                    child: confirmed
                        ? Icon(
                            Icons.check_rounded,
                            size: 14,
                            color: palette.isDark
                                ? const Color(0xFF06120A)
                                : Colors.white,
                          )
                        : null,
                  ),
                  const SizedBox(width: DS.s10),
                  Expanded(
                    child: Text(
                      '我已经把名词与故事保存到了安全的地方',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: DS.t14,
                        fontWeight: confirmed
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChecklistLine extends StatelessWidget {
  const _ChecklistLine({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.6),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
          const SizedBox(width: DS.s10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: DS.t13,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用步骤标题：渐变左指示条 + 图标 + 标题 + 副标题。
class _StepHeading extends StatelessWidget {
  const _StepHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: palette.isDark ? 0.18 : 0.14),
            borderRadius: BorderRadius.circular(DS.r10),
            border: Border.all(color: accent.withValues(alpha: 0.36)),
          ),
          child: Icon(icon, size: 20, color: accent),
        ),
        const SizedBox(width: DS.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: DS.t20,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: DS.t13,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
