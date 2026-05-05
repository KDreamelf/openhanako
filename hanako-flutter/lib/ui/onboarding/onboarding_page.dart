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
//   step 1: 子体名字 + 用户名（沿用原项目 Hanako/User 默认值）
//   step 2: 新账号验证邮箱 / 既有账号恢复登录
//   step 3: 生成账号——展示 12 个中文名词 + 占位故事，要求用户保存
//   step 4: 用户勾选"已保存"→ 落地写入身份与 agent，完成
//
// 规避 BUG-5：每一步右上角永远显示「跳过」。跳过后不创建身份，
// 仅创建匿名 agent；用户可在设置里再走"创建账号"流程。

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../identity/identity.dart';

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

  /// step 1 → step 2：先向认证中心核验用户名。
  ///
  /// 用户名可用则进入新账号注册；已存在则进入既有账号恢复登录。
  Future<void> _resolveUsernameAndContinue() async {
    if (_busy || !_canNext()) return;
    final username = _userName.trim();
    setState(() {
      _busy = true;
      _error = null;
      _loginAttempted = null;
      _loginElapsedMs = null;
      _loginDistance = null;
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
    if (_busy) return;
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
    });
    try {
      final eng = ref.read(engineProvider);
      final challenge = await eng.backendClient.startRegistrationEmail(
        username: username,
        email: email,
      );
      if (!mounted) return;
      setState(() {
        _emailChallenge = challenge;
        _emailCode = '';
        _error = '验证码已发送至 ${challenge.delivery}。';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '发送验证码失败：${_formatBackendError(e)}';
        _busy = false;
      });
    }
  }

  /// step 2：生成密钥 + 助记词 + 故事，并携邮箱验证码提交注册。
  Future<void> _generateIdentityAndRegister() async {
    if (_busy || !_canNext()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(identityRepositoryProvider);
    IdentityRegistration? reg;
    try {
      final eng = ref.read(engineProvider);
      reg = await repo.registerNew();
      final auth = await eng.backendClient.register(
        keyPair: reg.identity.keyPair,
        username: _userName.trim(),
        nickname: _agentName.trim(),
        email: _email.trim(),
        emailChallengeId: _emailChallenge!.challengeId,
        emailCode: _emailCode.trim(),
      );
      if (!mounted) return;
      setState(() {
        _registration = reg;
        _authResult = auth;
        _step = 3;
        _busy = false;
      });
    } catch (e) {
      if (reg != null) {
        try {
          await repo.logout();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
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
      _loginAttempted = null;
      _loginElapsedMs = null;
      _loginDistance = null;
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
        softDeadline: const Duration(seconds: 30),
        hardDeadline: const Duration(seconds: 30),
        onProgress: (attempted, elapsedMs, currentHammingDistance) {
          if (!mounted) return;
          setState(() {
            _loginAttempted = attempted;
            _loginElapsedMs = elapsedMs;
            _loginDistance = currentHammingDistance;
          });
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
      if (status == 409) {
        return '用户名已被占用，请返回上一步重新核验或更换用户名。';
      }
      if (status == 401) {
        return '身份验证失败，请确认用户名与助记词是否匹配。';
      }
      if (data is Map) {
        final message = data['message'];
        final code = data['error'];
        if (message is String && message.trim().isNotEmpty) {
          return message;
        }
        if (code is String && code.trim().isNotEmpty) {
          return code;
        }
      }
      if (status != null) return '认证中心返回 HTTP $status';
      return '无法连接认证中心';
    }
    return '$error';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('欢迎使用 PH01 子体 · ${_step + 1}/$_totalSteps'),
        actions: [
          TextButton(onPressed: _busy ? null : _skip, child: const Text('跳过')),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildStep(),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                _buildButtons(),
              ],
            ),
          ),
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
          }),
        );
      case 2:
        if (_accountFlow == _OnboardingAccountFlow.login) {
          return _StepExistingLogin(
            userName: _userName.trim(),
            recoveryText: _recoveryText,
            attempted: _loginAttempted,
            elapsedMs: _loginElapsedMs,
            distance: _loginDistance,
            onRecoveryTextChanged: (v) => setState(() => _recoveryText = v),
          );
        }
        return _StepRegistrationEmail(
          email: _email,
          code: _emailCode,
          challenge: _emailChallenge,
          busy: _busy,
          onEmailChanged: (v) => setState(() {
            _email = v;
            _emailChallenge = null;
            _emailCode = '';
          }),
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
//  step 0 · 欢迎
// ===========================================================================
class _StepWelcome extends StatelessWidget {
  const _StepWelcome();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Icon(Icons.auto_awesome, size: 80),
        const SizedBox(height: 16),
        Text('欢迎使用 PH01 子体', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          '你的私人 AI 子体，带有本地身份、长期记忆与桌面工作流。',
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
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
    final usernameTooLong = userName.trim().length > 32;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('你和你的子体', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: agentName,
          decoration: const InputDecoration(
            labelText: '子体名称',
            helperText: '它是你的私有 AI 助手，将以这个名字与你对话',
            border: OutlineInputBorder(),
          ),
          onChanged: onAgentNameChanged,
        ),
        const SizedBox(height: 12),
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
    required this.onEmailChanged,
    required this.onCodeChanged,
    required this.onSendCode,
  });

  final String email;
  final String code;
  final RegistrationEmailChallenge? challenge;
  final bool busy;
  final ValueChanged<String> onEmailChanged;
  final ValueChanged<String> onCodeChanged;
  final VoidCallback onSendCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final emailReady = email.trim().isNotEmpty && email.contains('@');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('验证邮箱', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          '邮箱用于注册确认与后续恢复二次校验。验证码通过后，本机会生成私钥和助记词，再提交公钥完成注册。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
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
        const SizedBox(height: 12),
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
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: busy || !emailReady ? null : onSendCode,
              child: Text(challenge == null ? '发送验证码' : '重新发送'),
            ),
          ],
        ),
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
    required this.attempted,
    required this.elapsedMs,
    required this.distance,
    required this.onRecoveryTextChanged,
  });

  final String userName;
  final String recoveryText;
  final int? attempted;
  final int? elapsedMs;
  final int? distance;
  final ValueChanged<String> onRecoveryTextChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progressText = attempted == null
        ? null
        : '已尝试 $attempted 次'
              '${distance == null ? '' : '，距离 $distance'}'
              '${elapsedMs == null ? '' : '，耗时 ${(elapsedMs! / 1000).toStringAsFixed(1)} 秒'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('登录已有账号', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          '用户名 $userName 已存在。请输入这个账号保存的 12 个名词或记忆故事。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: recoveryText,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: '12 个名词或记忆故事',
            helperText: '直接粘贴 12 个名词时不依赖 AI 网关',
            border: OutlineInputBorder(),
          ),
          onChanged: onRecoveryTextChanged,
        ),
        if (progressText != null) ...[
          const SizedBox(height: 12),
          Text(progressText, style: theme.textTheme.bodySmall),
        ],
      ],
    );
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
    if (registration == null) {
      // 还没生成；这里显示一个提示让用户回上一步点"生成账号"。
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: Text('点击下方按钮生成账号…')),
      );
    }
    final reg = registration!;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('你的账号已生成', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          '请把下面的 12 个名词与故事保存好（截图、抄写或打印均可）。'
          '丢失它们将无法在新设备登录此账号。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.list_alt, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('12 个名词（有序）', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    IconButton(
                      tooltip: '复制名词',
                      icon: const Icon(Icons.copy),
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
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < reg.words.length; i++)
                      Chip(label: Text('${i + 1}. ${reg.words[i]}')),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          color: theme.colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.menu_book, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('记忆故事', style: theme.textTheme.titleSmall),
                  ],
                ),
                const SizedBox(height: 8),
                if (reg.fallback)
                  Text(
                    '当前未配置 LLM，故事尚未生成。'
                    '进入主界面后可让子体随时帮你编一段。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  )
                else
                  Text(reg.story, style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        SelectableText(
          '公钥指纹：${reg.identity.publicKeyHash.substring(0, 16)}…',
          style: theme.textTheme.bodySmall,
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
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('确认保存', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        Text(
          '一旦点击「完成」，引导页将关闭。'
          '请再次确认你已经妥善保管以下信息：',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _line('• 12 个名词（按顺序）'),
                _line(registration.fallback ? '• （故事尚未生成，仅靠名词记忆）' : '• 记忆故事'),
                _line('• 本机身份 vault（由 Windows 当前用户保护）'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        CheckboxListTile(
          title: const Text('我已经把名词与故事保存到了安全的地方'),
          value: confirmed,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (v) => onChanged(v ?? false),
        ),
      ],
    );
  }

  Widget _line(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(text),
  );
}
