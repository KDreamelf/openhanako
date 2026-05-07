import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/window_factory.dart';
import '../core/engine.dart';
import '../core/runtime_session_store.dart';
import '../llm/provider.dart';
import 'desk/desk_page.dart';
import 'memory/memory_page.dart';
import 'onboarding/onboarding_page.dart';
import 'perf/perf_hud.dart';
import 'skills/skills_page.dart';
import 'widgets/session_drawer.dart';
import 'widgets/streaming_message.dart';

// =====================================================================
// State
// =====================================================================

class ChatState {
  final List<RuntimeDisplayMessage> history;
  final List<RuntimeDisplayBlock> currentBlocks;
  final bool streaming;
  final ChatRetryNotice? retrying;
  final String? error;
  final String? errorDetails;
  final int? errorStatusCode;

  const ChatState({
    this.history = const [],
    this.currentBlocks = const [],
    this.streaming = false,
    this.retrying,
    this.error,
    this.errorDetails,
    this.errorStatusCode,
  });

  ChatState copyWith({
    List<RuntimeDisplayMessage>? history,
    List<RuntimeDisplayBlock>? currentBlocks,
    bool? streaming,
    Object? retrying = _sentinel,
    Object? error = _sentinel,
    Object? errorDetails = _sentinel,
    Object? errorStatusCode = _sentinel,
  }) => ChatState(
    history: history ?? this.history,
    currentBlocks: currentBlocks ?? this.currentBlocks,
    streaming: streaming ?? this.streaming,
    retrying: identical(retrying, _sentinel)
        ? this.retrying
        : retrying as ChatRetryNotice?,
    error: identical(error, _sentinel) ? this.error : error as String?,
    errorDetails: identical(errorDetails, _sentinel)
        ? this.errorDetails
        : errorDetails as String?,
    errorStatusCode: identical(errorStatusCode, _sentinel)
        ? this.errorStatusCode
        : errorStatusCode as int?,
  );

  static const _sentinel = Object();
}

class ChatRetryNotice {
  const ChatRetryNotice({
    required this.message,
    required this.retryIndex,
    required this.maxRetries,
    required this.waiting,
    this.delay,
    this.statusCode,
    this.details,
  });

  final String message;
  final int retryIndex;
  final int maxRetries;
  final bool waiting;
  final Duration? delay;
  final int? statusCode;
  final String? details;

  String get title {
    final prefix = '第 $retryIndex/$maxRetries 次重试';
    if (waiting && delay != null) {
      return '$prefix 将在 ${delay!.inSeconds} 秒后开始';
    }
    return '$prefix 正在进行';
  }
}

class ChatNotifier extends StateNotifier<ChatState> {
  ChatNotifier(this._ref) : super(const ChatState());
  final Ref _ref;
  bool _restored = false;
  int _sendGeneration = 0;
  bool _stopRetrying = false;
  CancelToken? _activeCancelToken;
  Completer<void>? _retryDelayCompleter;

  static const int _maxRetries = 5;

  Future<void> restoreLastSession({bool force = false}) async {
    if (state.streaming) return;
    if (_restored && !force) return;
    try {
      final eng = _ref.read(engineProvider);
      final session = await eng.sessionCoordinator.restoreLastSession();
      final messages = session == null
          ? const <RuntimeDisplayMessage>[]
          : eng.sessionCoordinator.currentDisplayMessages();
      _restored = true;
      state = ChatState(history: messages);
    } catch (e) {
      _restored = false;
      state = state.copyWith(
        streaming: false,
        error: '恢复会话失败',
        errorDetails: e.toString(),
      );
    }
  }

  Future<void> createSession() async {
    if (state.streaming) return;
    final eng = _ref.read(engineProvider);
    await eng.sessionCoordinator.createSession();
    _restored = true;
    state = const ChatState();
    _ref.invalidate(sessionListProvider);
  }

  Future<void> switchSession(String sessionPath) async {
    if (state.streaming) return;
    final eng = _ref.read(engineProvider);
    await eng.sessionCoordinator.switchSession(sessionPath);
    _restored = true;
    state = ChatState(history: eng.sessionCoordinator.currentDisplayMessages());
    _ref.invalidate(sessionListProvider);
  }

  Future<void> send(String text) async {
    if (state.streaming) return;
    if (!_restored) {
      await restoreLastSession();
    }

    final eng = _ref.read(engineProvider);
    final agentId = eng.agentManager.activeAgentId;
    final identity = _ref.read(identityRepositoryProvider).current;
    final modelId = selectedChatModelId(eng);

    if (agentId == null) {
      state = state.copyWith(streaming: false, error: '请先创建 agent');
      return;
    }
    if (identity == null) {
      state = state.copyWith(streaming: false, error: '请先创建或解锁子体身份');
      return;
    }
    if (modelId == null) {
      state = state.copyWith(streaming: false, error: '请先选择模型');
      return;
    }

    final committedMessages = [...state.history];
    final inFlightMessages = [
      ...committedMessages,
      RuntimeDisplayMessage.userText(text),
    ];
    final generation = ++_sendGeneration;
    _stopRetrying = false;
    _activeCancelToken = null;
    state = ChatState(history: inFlightMessages, streaming: true);

    await _sendWithRetries(
      text,
      committedMessages: committedMessages,
      inFlightMessages: inFlightMessages,
      generation: generation,
    );
  }

  Future<void> interruptWith(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      stopRetrying();
      return;
    }
    if (!state.streaming) {
      await send(trimmed);
      return;
    }

    if (!_restored) {
      await restoreLastSession();
    }
    final eng = _ref.read(engineProvider);
    final committedMessages = eng.sessionCoordinator.currentDisplayMessages();
    final inFlightMessages = [
      ...committedMessages,
      RuntimeDisplayMessage.userText(trimmed),
    ];
    final generation = ++_sendGeneration;
    _cancelActiveTurn('用户插话');
    _stopRetrying = false;
    state = ChatState(history: inFlightMessages, streaming: true);

    await _sendWithRetries(
      trimmed,
      committedMessages: committedMessages,
      inFlightMessages: inFlightMessages,
      generation: generation,
    );
  }

  void stopRetrying() {
    if (!state.streaming) return;
    ++_sendGeneration;
    _cancelActiveTurn('用户停止当前回复');
    final eng = _ref.read(engineProvider);
    state = ChatState(
      history: eng.sessionCoordinator.currentDisplayMessages(),
      streaming: false,
    );
  }

  /// 删除指定索引的消息。如果是流中状态，禁止删除。
  void removeAt(int index) {
    if (state.streaming) return;
    if (index < 0 || index >= state.history.length) return;
    final next = [...state.history]..removeAt(index);
    state = state.copyWith(history: next);
    _replaceCurrentHistory(next);
  }

  /// 重新生成指定索引的 assistant 消息：截断到这条之前（不含），
  /// 然后基于前一条 user 消息再发一次。
  Future<void> regenerateAt(int index) async {
    if (state.streaming) return;
    if (index < 0 || index >= state.history.length) return;
    final target = state.history[index];
    if (target.role != 'assistant') return;
    // 找到这条 assistant 之前最后一条 user
    var userIdx = index - 1;
    while (userIdx >= 0 && state.history[userIdx].role != 'user') {
      userIdx--;
    }
    if (userIdx < 0) return;
    final userText = state.history[userIdx].visibleText;
    // 截断到 user 之前（不含 user 自己——send 会重新加）
    final truncated = state.history.sublist(0, userIdx);
    state = ChatState(history: truncated);
    _replaceCurrentHistory(truncated);
    await send(userText);
  }

  /// 编辑指定索引的 user 消息：替换内容、截断之后所有消息、重新发送。
  Future<void> editUserAt(int index, String newText) async {
    if (state.streaming) return;
    if (index < 0 || index >= state.history.length) return;
    final target = state.history[index];
    if (target.role != 'user') return;
    final trimmed = newText.trim();
    if (trimmed.isEmpty) return;
    final truncated = state.history.sublist(0, index);
    state = ChatState(history: truncated);
    _replaceCurrentHistory(truncated);
    await send(trimmed);
  }

  /// 清空整个会话历史。
  void clear() {
    if (state.streaming) return;
    state = const ChatState();
    _replaceCurrentHistory(const []);
  }

  Future<void> _sendWithRetries(
    String text, {
    required List<RuntimeDisplayMessage> committedMessages,
    required List<RuntimeDisplayMessage> inFlightMessages,
    required int generation,
  }) async {
    var retryCount = 0;
    _LlmFailure? lastFailure;

    while (generation == _sendGeneration) {
      if (retryCount > 0) {
        state = ChatState(
          history: _ref
              .read(engineProvider)
              .sessionCoordinator
              .currentDisplayMessages(),
          streaming: true,
          retrying: _retryNotice(lastFailure!, retryCount, waiting: false),
        );
      }

      final token = CancelToken();
      _activeCancelToken = token;
      final stream = retryCount == 0
          ? _ref
                .read(engineProvider)
                .sessionCoordinator
                .prompt(text, cancelToken: token)
          : _ref
                .read(engineProvider)
                .sessionCoordinator
                .retryCurrentTurn(cancelToken: token);
      final result = await _consumeStream(
        stream,
        committedMessages: committedMessages,
        inFlightMessages: inFlightMessages,
        generation: generation,
      );
      if (_activeCancelToken == token) {
        _activeCancelToken = null;
      }
      if (generation != _sendGeneration) return;
      if (result.success) return;

      final failure = _stopRetrying && lastFailure != null
          ? lastFailure
          : result.failure!;
      lastFailure = failure;
      if (result.hadProgress) {
        retryCount = 0;
      }

      if (_stopRetrying ||
          !_shouldRetry(failure) ||
          retryCount >= _maxRetries) {
        _showFinalFailure(failure);
        return;
      }

      retryCount++;
      final delay = _retryDelay(retryCount);
      state = ChatState(
        history: _ref
            .read(engineProvider)
            .sessionCoordinator
            .currentDisplayMessages(),
        streaming: true,
        retrying: _retryNotice(
          failure,
          retryCount,
          waiting: true,
          delay: delay,
        ),
      );
      final stopped = await _waitForRetryDelay(delay);
      if (generation != _sendGeneration) return;
      if (stopped) {
        _showFinalFailure(failure);
        return;
      }
    }
  }

  Future<_StreamConsumeResult> _consumeStream(
    Stream<LlmEvent> events, {
    required List<RuntimeDisplayMessage> committedMessages,
    required List<RuntimeDisplayMessage> inFlightMessages,
    required int generation,
  }) async {
    final currentBlocks = <RuntimeDisplayBlock>[];
    final toolCallIndices = <String, int>{};
    var hadProgress = false;

    void updateBlocks() {
      if (generation != _sendGeneration) return;
      state = state.copyWith(
        currentBlocks: List<RuntimeDisplayBlock>.from(currentBlocks),
        retrying: null,
        error: null,
        errorDetails: null,
        errorStatusCode: null,
      );
    }

    void appendText(String text) {
      if (text.isEmpty) return;
      hadProgress = true;
      if (currentBlocks.isNotEmpty &&
          currentBlocks.last is RuntimeDisplayTextBlock) {
        final last = currentBlocks.removeLast() as RuntimeDisplayTextBlock;
        currentBlocks.add(RuntimeDisplayTextBlock('${last.text}$text'));
      } else {
        currentBlocks.add(RuntimeDisplayTextBlock(text));
      }
      updateBlocks();
    }

    void appendThinking(String text) {
      if (text.isEmpty) return;
      hadProgress = true;
      if (currentBlocks.isNotEmpty &&
          currentBlocks.last is RuntimeDisplayThinkingBlock) {
        final last = currentBlocks.removeLast() as RuntimeDisplayThinkingBlock;
        currentBlocks.add(RuntimeDisplayThinkingBlock('${last.text}$text'));
      } else {
        currentBlocks.add(RuntimeDisplayThinkingBlock(text));
      }
      updateBlocks();
    }

    void upsertToolCall(String id, String name, {String argsDelta = ''}) {
      hadProgress = true;
      final index = toolCallIndices[id];
      if (index == null || index >= currentBlocks.length) {
        toolCallIndices[id] = currentBlocks.length;
        currentBlocks.add(
          RuntimeDisplayToolCallBlock(id: id, name: name, argsJson: argsDelta),
        );
      } else {
        final old = currentBlocks[index];
        if (old is RuntimeDisplayToolCallBlock) {
          currentBlocks[index] = RuntimeDisplayToolCallBlock(
            id: id,
            name: name.isNotEmpty ? name : old.name,
            argsJson: '${old.argsJson}$argsDelta',
          );
        }
      }
      updateBlocks();
    }

    try {
      await for (final ev in events) {
        switch (ev) {
          case TextDelta(:final text):
            appendText(text);
          case ThinkingDelta(:final text):
            appendThinking(text);
          case ToolCallStart(:final id, :final name):
            upsertToolCall(id, name);
          case ToolCallArgsDelta(:final id, :final argsJson):
            upsertToolCall(id, '', argsDelta: argsJson);
          case ToolCallEnd():
            break;
          case MessageDone():
            if (generation != _sendGeneration) {
              return const _StreamConsumeResult.success();
            }
            final eng = _ref.read(engineProvider);
            state = ChatState(
              history: eng.sessionCoordinator.currentDisplayMessages(),
              streaming: false,
            );
            return const _StreamConsumeResult.success();
          case LlmError(:final message, :final statusCode, :final details):
            if (generation != _sendGeneration) {
              return _StreamConsumeResult.failure(
                _LlmFailure(
                  message: message,
                  statusCode: statusCode,
                  details: details,
                ),
                hadProgress: hadProgress,
              );
            }
            final eng = _ref.read(engineProvider);
            state = state.copyWith(
              history: eng.sessionCoordinator.currentDisplayMessages(),
              currentBlocks: const [],
            );
            return _StreamConsumeResult.failure(
              _LlmFailure(
                message: message,
                statusCode: statusCode,
                details: details,
              ),
              hadProgress: hadProgress,
            );
        }
      }
      if (currentBlocks.isNotEmpty) {
        if (generation != _sendGeneration) {
          return const _StreamConsumeResult.success();
        }
        state = ChatState(
          history: [
            ...inFlightMessages,
            RuntimeDisplayMessage(
              role: 'assistant',
              blocks: List<RuntimeDisplayBlock>.from(currentBlocks),
            ),
          ],
          streaming: false,
        );
        return const _StreamConsumeResult.success();
      } else {
        if (generation != _sendGeneration) {
          return const _StreamConsumeResult.success();
        }
        state = ChatState(history: committedMessages, streaming: false);
        return const _StreamConsumeResult.success();
      }
    } catch (e) {
      return _StreamConsumeResult.failure(
        _LlmFailure(message: '发送对话失败：客户端处理异常', details: e.toString()),
        hadProgress: hadProgress,
      );
    }
  }

  bool _shouldRetry(_LlmFailure failure) {
    final status = failure.statusCode;
    if (status == null) return true;
    if (status == 429) return true;
    return status >= 500;
  }

  Duration _retryDelay(int retryIndex) {
    final seconds = 1 << (retryIndex - 1);
    return Duration(seconds: seconds);
  }

  ChatRetryNotice _retryNotice(
    _LlmFailure failure,
    int retryIndex, {
    required bool waiting,
    Duration? delay,
  }) {
    return ChatRetryNotice(
      message: failure.message,
      statusCode: failure.statusCode,
      details: failure.details,
      retryIndex: retryIndex,
      maxRetries: _maxRetries,
      waiting: waiting,
      delay: delay,
    );
  }

  Future<bool> _waitForRetryDelay(Duration delay) async {
    final completer = Completer<void>();
    _retryDelayCompleter = completer;
    final timer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      await completer.future;
      return _stopRetrying;
    } finally {
      timer.cancel();
      if (_retryDelayCompleter == completer) {
        _retryDelayCompleter = null;
      }
    }
  }

  void _cancelActiveTurn(String reason) {
    _stopRetrying = true;
    _activeCancelToken?.cancel(reason);
    final delayCompleter = _retryDelayCompleter;
    if (delayCompleter != null && !delayCompleter.isCompleted) {
      delayCompleter.complete();
    }
  }

  void _showFinalFailure(_LlmFailure failure) {
    state = ChatState(
      history: _ref
          .read(engineProvider)
          .sessionCoordinator
          .currentDisplayMessages(),
      streaming: false,
      error: failure.message,
      errorDetails: failure.details,
      errorStatusCode: failure.statusCode,
    );
  }

  void _replaceCurrentHistory(List<RuntimeDisplayMessage> messages) {
    final eng = _ref.read(engineProvider);
    eng.sessionCoordinator.replaceCurrentMessages(
      messages.map((message) => message.toVisibleMessage()).toList(),
    );
    _ref.invalidate(sessionListProvider);
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>(
  ChatNotifier.new,
);

class _StreamConsumeResult {
  const _StreamConsumeResult._({
    required this.success,
    this.failure,
    this.hadProgress = false,
  });

  const _StreamConsumeResult.success() : this._(success: true, failure: null);

  const _StreamConsumeResult.failure(
    _LlmFailure failure, {
    bool hadProgress = false,
  }) : this._(success: false, failure: failure, hadProgress: hadProgress);

  final bool success;
  final _LlmFailure? failure;
  final bool hadProgress;
}

class _LlmFailure {
  const _LlmFailure({required this.message, this.statusCode, this.details});

  final String message;
  final int? statusCode;
  final String? details;
}

String? selectedChatModelId(HanaEngine engine) {
  final cfg = engine.config.read();
  final models = cfg['models'] as Map?;
  final configured = (models?['chat'] as String?)?.trim();
  if (configured != null && configured.isNotEmpty) return configured;
  return engine.modelManager.currentModelId;
}

// =====================================================================
// UI
// =====================================================================

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _onboardingShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(chatProvider.notifier).restoreLastSession());
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeShowOnboarding();
  }

  Future<void> _maybeShowOnboarding() async {
    if (_onboardingShown) return;
    final eng = ref.read(engineProvider);
    final list = await eng.agentManager.listAgents();
    if (list.isEmpty && mounted) {
      _onboardingShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Navigator.of(
          context,
        ).push<bool>(MaterialPageRoute(builder: (_) => const OnboardingPage()));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatProvider);
    final activeAgent = ref.watch(activeAgentIdProvider);
    final eng = ref.watch(engineProvider);
    final identity = ref.watch(currentIdentityProvider);
    final selectedModel = selectedChatModelId(eng);

    ref.listen<ChatState>(chatProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
          );
        }
      });
    });

    final canUseComposer =
        activeAgent != null && identity != null && selectedModel != null;

    return Scaffold(
      drawer: SessionDrawer(
        onNewSession: () => ref.read(chatProvider.notifier).createSession(),
        onSwitchSession: (entry) =>
            ref.read(chatProvider.notifier).switchSession(entry.path),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Builder(
                builder: (shellContext) => _ChatHeader(
                  activeAgent: activeAgent,
                  identityReady: identity != null,
                  selectedModel: selectedModel,
                  messageCount: state.history.length,
                  streaming: state.streaming,
                  canClear: state.history.isNotEmpty && !state.streaming,
                  onOpenSessions: () => Scaffold.of(shellContext).openDrawer(),
                  onClear: () => ref.read(chatProvider.notifier).clear(),
                  onOpenDesk: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const DeskPage())),
                  onOpenMemory: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const MemoryPage())),
                  onOpenSkills: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const SkillsPage())),
                  onOpenSettings: () => WindowFactory.openSettings(context),
                  onUnlockIdentity: identity == null ? _unlockIdentity : null,
                  onChooseModel: state.streaming ? null : _chooseModel,
                ),
              ),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                  ),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1040),
                      child: ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                        children: [
                          if (state.history.isEmpty && !state.streaming)
                            _EmptyHint(
                              activeAgent: activeAgent,
                              identityReady: identity != null,
                              selectedModel: selectedModel,
                            ),
                          for (var i = 0; i < state.history.length; i++)
                            _MessageBubble(
                              index: i,
                              message: state.history[i],
                              streaming: state.streaming,
                            ),
                          if (state.streaming)
                            StreamingMessage(
                              blocks: state.currentBlocks,
                              streaming: true,
                            ),
                          if (state.retrying != null)
                            _RetryBanner(
                              notice: state.retrying!,
                              onStop: () => ref
                                  .read(chatProvider.notifier)
                                  .stopRetrying(),
                            ),
                          if (state.error != null)
                            _ErrorBanner(
                              message: state.error!,
                              details: state.errorDetails,
                              statusCode: state.errorStatusCode,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _ComposerPanel(
                controller: _input,
                canSend: canUseComposer,
                streaming: state.streaming,
                activeAgent: activeAgent,
                identityReady: identity != null,
                selectedModel: selectedModel,
                onSend: _send,
                onStop: () => ref.read(chatProvider.notifier).stopRetrying(),
              ),
            ],
          ),
          const Positioned(top: 12, right: 12, child: PerfHud()),
        ],
      ),
    );
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final notifier = ref.read(chatProvider.notifier);
    if (ref.read(chatProvider).streaming) {
      unawaited(notifier.interruptWith(text));
      return;
    }
    unawaited(notifier.send(text));
  }

  Future<void> _unlockIdentity() async {
    try {
      final repo = ref.read(identityRepositoryProvider);
      await repo.unlock();
      ref.read(identityRevisionProvider.notifier).state++;
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本机身份已解锁')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('解锁身份失败：$e')));
    }
  }

  Future<void> _chooseModel() async {
    final eng = ref.read(engineProvider);
    final identity = ref.read(currentIdentityProvider);
    final preferred = selectedChatModelId(eng);

    if (identity != null) {
      try {
        await eng.syncGatewayModels(identity, preferredModelId: preferred);
      } catch (e) {
        if (mounted && eng.modelManager.availableModels.isEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('同步模型列表失败：$e')));
        }
      }
    }

    final models = eng.modelManager.availableModels;
    if (!mounted) return;
    if (models.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无可用模型，请先完成身份登录并同步模型列表')));
      return;
    }

    final current = selectedChatModelId(eng);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择模型'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final model in models)
                ListTile(
                  title: Text(model.name),
                  selected: model.id == current,
                  trailing: model.id == current
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => Navigator.pop(ctx, model.id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await eng.modelManager.selectModel(result);
    eng.config.writeAt(['models', 'chat'], result);
    if (mounted) setState(() {});
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.activeAgent,
    required this.identityReady,
    required this.selectedModel,
    required this.messageCount,
    required this.streaming,
    required this.canClear,
    required this.onOpenSessions,
    required this.onClear,
    required this.onOpenDesk,
    required this.onOpenMemory,
    required this.onOpenSkills,
    required this.onOpenSettings,
    required this.onUnlockIdentity,
    required this.onChooseModel,
  });

  final String? activeAgent;
  final bool identityReady;
  final String? selectedModel;
  final int messageCount;
  final bool streaming;
  final bool canClear;
  final VoidCallback onOpenSessions;
  final VoidCallback onClear;
  final VoidCallback onOpenDesk;
  final VoidCallback onOpenMemory;
  final VoidCallback onOpenSkills;
  final VoidCallback onOpenSettings;
  final VoidCallback? onUnlockIdentity;
  final VoidCallback? onChooseModel;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _HeaderAction(
          icon: Icons.cleaning_services_outlined,
          tooltip: '清空当前会话',
          onPressed: canClear ? onClear : null,
        ),
        _HeaderAction(
          icon: Icons.psychology_outlined,
          tooltip: '记忆',
          onPressed: onOpenMemory,
        ),
        _HeaderAction(
          icon: Icons.folder_outlined,
          tooltip: '书桌',
          onPressed: onOpenDesk,
        ),
        _HeaderAction(
          icon: Icons.extension_outlined,
          tooltip: '技能',
          onPressed: onOpenSkills,
        ),
        _HeaderAction(
          icon: Icons.tune,
          tooltip: '设置',
          onPressed: onOpenSettings,
        ),
        OutlinedButton.icon(
          onPressed: onChooseModel,
          icon: const Icon(Icons.hub_outlined, size: 18),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              selectedModel ?? '选择模型',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.outlineVariant)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: LayoutBuilder(
            builder: (context, box) {
              final compact = box.maxWidth < 820;
              final title = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '子体控制台',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    activeAgent == null
                        ? '尚未选择 Agent'
                        : '$activeAgent · ${streaming ? "响应中" : "就绪"} · $messageCount 条消息',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              );
              final status = Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StatusPill(
                    icon: Icons.account_tree_outlined,
                    label: activeAgent == null ? '未选 Agent' : 'Agent 已连接',
                    color: activeAgent == null ? c.error : c.primary,
                  ),
                  _StatusPill(
                    icon: Icons.key_outlined,
                    label: identityReady ? '身份已解锁' : '身份未解锁',
                    color: identityReady ? c.primary : c.error,
                    tooltip: identityReady ? null : '尝试解锁本机身份',
                    onPressed: onUnlockIdentity,
                  ),
                  _StatusPill(
                    icon: Icons.memory_outlined,
                    label: selectedModel == null ? '未选模型' : '模型已选择',
                    color: selectedModel == null ? c.tertiary : c.primary,
                  ),
                ],
              );

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _HeaderAction(
                          icon: Icons.menu,
                          tooltip: '会话',
                          onPressed: onOpenSessions,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: title),
                      ],
                    ),
                    const SizedBox(height: 12),
                    status,
                    const SizedBox(height: 12),
                    actions,
                  ],
                );
              }

              return Row(
                children: [
                  _HeaderAction(
                    icon: Icons.menu,
                    tooltip: '会话',
                    onPressed: onOpenSessions,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: title),
                  status,
                  const SizedBox(width: 16),
                  actions,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size(40, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.color,
    this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final String? tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final child = Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    final pill = Material(
      color: color.withAlpha(28),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: color.withAlpha(72)),
      ),
      child: onPressed == null
          ? child
          : InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(8),
              child: child,
            ),
    );
    final wrapped = onPressed == null
        ? pill
        : MouseRegion(cursor: SystemMouseCursors.click, child: pill);
    final text = tooltip;
    if (text == null || text.isEmpty) return wrapped;
    return Tooltip(message: text, child: wrapped);
  }
}

class _ComposerPanel extends StatefulWidget {
  const _ComposerPanel({
    required this.controller,
    required this.canSend,
    required this.activeAgent,
    required this.identityReady,
    required this.selectedModel,
    required this.onSend,
    required this.onStop,
    required this.streaming,
  });

  final TextEditingController controller;
  final bool canSend;
  final bool streaming;
  final String? activeAgent;
  final bool identityReady;
  final String? selectedModel;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  State<_ComposerPanel> createState() => _ComposerPanelState();
}

class _ComposerPanelState extends State<_ComposerPanel> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'chat-composer');
    _focusNode.onKeyEvent = _handleKeyEvent;
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant _ComposerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onTextChanged);
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final hintText = widget.activeAgent == null
        ? '请先创建或选择 Agent'
        : !widget.identityReady
        ? '请先创建或解锁子体身份'
        : widget.selectedModel == null
        ? '请先选择模型'
        : widget.streaming
        ? '输入插话，或留空停止当前回复'
        : '输入消息，Enter 发送，Shift+Enter 换行';
    final hasText = widget.controller.text.trim().isNotEmpty;
    final stopOnly = widget.streaming && !hasText;
    final buttonEnabled = widget.canSend && (hasText || stopOnly);
    final buttonIcon = stopOnly ? Icons.stop : Icons.send;
    final buttonLabel = stopOnly ? '停止' : '发送';
    final buttonAction = stopOnly ? widget.onStop : widget.onSend;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: c.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: c.outlineVariant),
                      ),
                      child: TextField(
                        focusNode: _focusNode,
                        controller: widget.controller,
                        enabled: widget.canSend,
                        minLines: 1,
                        maxLines: 6,
                        keyboardType: TextInputType.multiline,
                        decoration: InputDecoration(
                          hintText: hintText,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                        style: const TextStyle(fontSize: 16, height: 1.5),
                        textInputAction: TextInputAction.newline,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: buttonEnabled ? buttonAction : null,
                      icon: Icon(buttonIcon, size: 18),
                      label: Text(buttonLabel),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !widget.canSend) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;

    if (HardwareKeyboard.instance.isShiftPressed) {
      _insertNewline();
    } else if (widget.streaming && widget.controller.text.trim().isEmpty) {
      widget.onStop();
    } else {
      widget.onSend();
    }
    return KeyEventResult.handled;
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _insertNewline() {
    final value = widget.controller.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final nextText = text.replaceRange(start, end, '\n');
    final caret = start + 1;
    widget.controller.value = value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: caret),
      composing: TextRange.empty,
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String? activeAgent;
  final bool identityReady;
  final String? selectedModel;
  const _EmptyHint({
    this.activeAgent,
    required this.identityReady,
    required this.selectedModel,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: const EdgeInsets.symmetric(vertical: 56),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: c.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: c.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.forum_outlined,
                    color: c.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    '开始一次子体会话',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '这里保留普通对话客户端的直接性，同时把身份、模型和本地记忆这些子体状态放到第一层。',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                height: 1.6,
                color: c.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusPill(
                  icon: Icons.account_tree_outlined,
                  label: activeAgent == null
                      ? '等待 Agent'
                      : 'Agent: $activeAgent',
                  color: activeAgent == null ? c.error : c.primary,
                ),
                _StatusPill(
                  icon: Icons.key_outlined,
                  label: identityReady ? '身份可用' : '身份待解锁',
                  color: identityReady ? c.primary : c.error,
                ),
                _StatusPill(
                  icon: Icons.memory_outlined,
                  label: selectedModel == null ? '模型待选择' : '模型可用',
                  color: selectedModel == null ? c.tertiary : c.primary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final String? details;
  final int? statusCode;
  const _ErrorBanner({required this.message, this.details, this.statusCode});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final hasDetails = details != null && details!.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Material(
        color: c.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, color: c.onErrorContainer, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message,
                      style: TextStyle(
                        color: c.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (statusCode != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'HTTP $statusCode',
                        style: TextStyle(
                          color: c.onErrorContainer.withAlpha(190),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (hasDetails)
                TextButton(
                  onPressed: () => _showDetails(context),
                  child: const Text('查看详情'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('错误详情'),
        content: SizedBox(
          width: 640,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(
              child: SelectableText(
                details ?? '',
                style: const TextStyle(fontFamily: 'monospace', height: 1.45),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: details ?? ''));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('详情已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: const Text('复制详情'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _RetryBanner extends StatelessWidget {
  const _RetryBanner({required this.notice, required this.onStop});

  final ChatRetryNotice notice;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xfffff2c2);
    const foreground = Color(0xff4b3510);
    final hasDetails =
        notice.details != null && notice.details!.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.autorenew, color: foreground, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notice.title,
                      style: const TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      notice.message,
                      style: const TextStyle(color: foreground),
                    ),
                    if (notice.statusCode != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'HTTP ${notice.statusCode}',
                        style: TextStyle(
                          color: foreground.withAlpha(190),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (hasDetails)
                TextButton(
                  onPressed: () => _showDetails(context),
                  child: const Text('查看详情'),
                ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: onStop, child: const Text('停止')),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重试前错误详情'),
        content: SizedBox(
          width: 640,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(
              child: SelectableText(
                notice.details ?? '',
                style: const TextStyle(fontFamily: 'monospace', height: 1.45),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: notice.details ?? ''));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('详情已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: const Text('复制详情'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends ConsumerStatefulWidget {
  final int index;
  final RuntimeDisplayMessage message;
  final bool streaming;
  const _MessageBubble({
    required this.index,
    required this.message,
    required this.streaming,
  });

  @override
  ConsumerState<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<_MessageBubble> {
  bool _hover = false;

  Future<void> _editUserMessage() async {
    final ctrl = TextEditingController(text: widget.message.visibleText);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存并重新生成'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    await ref.read(chatProvider.notifier).editUserAt(widget.index, result);
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.role == 'user';
    final copyText = widget.message.copyText;
    final c = Theme.of(context).colorScheme;
    final actions = <Widget>[
      IconButton(
        icon: const Icon(Icons.copy, size: 16),
        tooltip: '复制',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        padding: EdgeInsets.zero,
        onPressed: () {
          Clipboard.setData(ClipboardData(text: copyText));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制'),
              duration: Duration(seconds: 1),
            ),
          );
        },
      ),
      if (isUser)
        IconButton(
          icon: const Icon(Icons.edit, size: 16),
          tooltip: '编辑并重新生成',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          onPressed: widget.streaming ? null : _editUserMessage,
        )
      else
        IconButton(
          icon: const Icon(Icons.refresh, size: 16),
          tooltip: '重新生成',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          onPressed: widget.streaming
              ? null
              : () =>
                    ref.read(chatProvider.notifier).regenerateAt(widget.index),
        ),
      IconButton(
        icon: const Icon(Icons.delete_outline, size: 16),
        tooltip: '删除',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        padding: EdgeInsets.zero,
        onPressed: widget.streaming
            ? null
            : () => ref.read(chatProvider.notifier).removeAt(widget.index),
      ),
    ];

    return RepaintBoundary(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: isUser
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  isUser ? '你' : '子体',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: c.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                margin: const EdgeInsets.only(bottom: 2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.72,
                ),
                decoration: BoxDecoration(
                  color: isUser ? c.primaryContainer : c.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isUser ? c.primary.withAlpha(64) : c.outlineVariant,
                  ),
                ),
                child: isUser
                    ? SelectableText(
                        widget.message.visibleText,
                        style: TextStyle(
                          color: c.onPrimaryContainer,
                          fontSize: 16,
                          height: 1.6,
                        ),
                      )
                    : MessageBlocksView(blocks: widget.message.blocks),
              ),
              AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, left: 12),
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
