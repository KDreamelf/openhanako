import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/window_factory.dart';
import '../core/engine.dart';
import '../llm/provider.dart';
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
  final List<Message> history;
  final String currentText;
  final String currentThinking;
  final List<ToolCallView> currentToolCalls;
  final bool streaming;
  final String? error;

  const ChatState({
    this.history = const [],
    this.currentText = '',
    this.currentThinking = '',
    this.currentToolCalls = const [],
    this.streaming = false,
    this.error,
  });

  ChatState copyWith({
    List<Message>? history,
    String? currentText,
    String? currentThinking,
    List<ToolCallView>? currentToolCalls,
    bool? streaming,
    Object? error = _sentinel,
  }) => ChatState(
    history: history ?? this.history,
    currentText: currentText ?? this.currentText,
    currentThinking: currentThinking ?? this.currentThinking,
    currentToolCalls: currentToolCalls ?? this.currentToolCalls,
    streaming: streaming ?? this.streaming,
    error: identical(error, _sentinel) ? this.error : error as String?,
  );

  static const _sentinel = Object();
}

class ChatNotifier extends StateNotifier<ChatState> {
  ChatNotifier(this._ref) : super(const ChatState());
  final Ref _ref;

  Future<void> send(String text) async {
    if (state.streaming) return;

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

    final newMessages = [
      ...state.history,
      Message(role: 'user', content: text),
    ];
    state = ChatState(history: newMessages, streaming: true);

    await _consumeStream(eng.sessionCoordinator.prompt(text), newMessages);
  }

  /// 删除指定索引的消息。如果是流中状态，禁止删除。
  void removeAt(int index) {
    if (state.streaming) return;
    if (index < 0 || index >= state.history.length) return;
    final next = [...state.history]..removeAt(index);
    state = state.copyWith(history: next);
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
    final userText = state.history[userIdx].content;
    // 截断到 user 之前（不含 user 自己——send 会重新加）
    final truncated = state.history.sublist(0, userIdx);
    state = ChatState(history: truncated);
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
    await send(trimmed);
  }

  /// 清空整个会话历史。
  void clear() {
    if (state.streaming) return;
    state = const ChatState();
  }

  Future<void> _consumeStream(
    Stream<LlmEvent> events,
    List<Message> baseMessages,
  ) async {
    final assistantText = StringBuffer();
    final assistantThink = StringBuffer();
    final toolCalls = <String, ToolCallView>{};

    try {
      await for (final ev in events) {
        switch (ev) {
          case TextDelta(:final text):
            assistantText.write(text);
            state = state.copyWith(currentText: assistantText.toString());
          case ThinkingDelta(:final text):
            assistantThink.write(text);
            state = state.copyWith(currentThinking: assistantThink.toString());
          case ToolCallStart(:final id, :final name):
            toolCalls[id] = ToolCallView(id: id, name: name);
            state = state.copyWith(currentToolCalls: toolCalls.values.toList());
          case ToolCallArgsDelta(:final id, :final argsJson):
            final old = toolCalls[id];
            if (old != null) {
              toolCalls[id] = ToolCallView(
                id: id,
                name: old.name,
                args: old.args + argsJson,
              );
              state = state.copyWith(
                currentToolCalls: toolCalls.values.toList(),
              );
            }
          case ToolCallEnd():
            break;
          case MessageDone():
            final assistantMsg = Message(
              role: 'assistant',
              content: assistantText.toString(),
            );
            state = ChatState(
              history: [...baseMessages, assistantMsg],
              streaming: false,
            );
            return;
          case LlmError(:final message):
            state = state.copyWith(streaming: false, error: message);
            return;
        }
      }
      if (assistantText.isNotEmpty) {
        final assistantMsg = Message(
          role: 'assistant',
          content: assistantText.toString(),
        );
        state = ChatState(
          history: [...baseMessages, assistantMsg],
          streaming: false,
        );
      } else {
        state = state.copyWith(streaming: false);
      }
    } catch (e) {
      state = state.copyWith(streaming: false, error: e.toString());
    }
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>(
  ChatNotifier.new,
);

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
    final identity = ref.watch(identityRepositoryProvider).current;
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

    final canSend =
        !state.streaming &&
        activeAgent != null &&
        identity != null &&
        selectedModel != null;

    return Scaffold(
      drawer: const SessionDrawer(),
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
                  onOpenMemory: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const MemoryPage())),
                  onOpenSkills: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const SkillsPage())),
                  onOpenSettings: () => WindowFactory.openSettings(),
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
                              role: state.history[i].role,
                              text: state.history[i].content,
                              streaming: state.streaming,
                            ),
                          if (state.streaming)
                            StreamingMessage(
                              text: state.currentText,
                              thinking: state.currentThinking,
                              toolCalls: state.currentToolCalls,
                              streaming: true,
                            ),
                          if (state.error != null)
                            _ErrorBanner(message: state.error!),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _ComposerPanel(
                controller: _input,
                canSend: canSend,
                activeAgent: activeAgent,
                identityReady: identity != null,
                selectedModel: selectedModel,
                onSend: _send,
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
    ref.read(chatProvider.notifier).send(text);
  }

  Future<void> _chooseModel() async {
    final eng = ref.read(engineProvider);
    final identity = ref.read(identityRepositoryProvider).current;
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
    required this.onOpenMemory,
    required this.onOpenSkills,
    required this.onOpenSettings,
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
  final VoidCallback onOpenMemory;
  final VoidCallback onOpenSkills;
  final VoidCallback onOpenSettings;
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
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(72)),
      ),
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
  }
}

class _ComposerPanel extends StatelessWidget {
  const _ComposerPanel({
    required this.controller,
    required this.canSend,
    required this.activeAgent,
    required this.identityReady,
    required this.selectedModel,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool canSend;
  final String? activeAgent;
  final bool identityReady;
  final String? selectedModel;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final hintText = activeAgent == null
        ? '请先创建或选择 Agent'
        : !identityReady
        ? '请先创建或解锁子体身份'
        : selectedModel == null
        ? '请先选择模型'
        : '输入消息，Enter 发送';

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
                        controller: controller,
                        enabled: canSend,
                        minLines: 1,
                        maxLines: 6,
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
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => onSend(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: canSend ? onSend : null,
                      icon: const Icon(Icons.send, size: 18),
                      label: const Text('发送'),
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
  const _ErrorBanner({required this.message});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Material(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Error: $message',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends ConsumerStatefulWidget {
  final int index;
  final String role;
  final String text;
  final bool streaming;
  const _MessageBubble({
    required this.index,
    required this.role,
    required this.text,
    required this.streaming,
  });

  @override
  ConsumerState<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<_MessageBubble> {
  bool _hover = false;

  Future<void> _editUserMessage() async {
    final ctrl = TextEditingController(text: widget.text);
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
    final isUser = widget.role == 'user';
    final c = Theme.of(context).colorScheme;
    final actions = <Widget>[
      IconButton(
        icon: const Icon(Icons.copy, size: 16),
        tooltip: '复制',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        padding: EdgeInsets.zero,
        onPressed: () {
          Clipboard.setData(ClipboardData(text: widget.text));
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
                        widget.text,
                        style: TextStyle(
                          color: c.onPrimaryContainer,
                          fontSize: 16,
                          height: 1.6,
                        ),
                      )
                    : MarkdownBody(
                        data: widget.text,
                        selectable: true,
                        styleSheet:
                            MarkdownStyleSheet.fromTheme(
                              Theme.of(context),
                            ).copyWith(
                              p: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontSize: 16,
                                    height: 1.6,
                                    color: c.onSurface,
                                  ),
                            ),
                      ),
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
