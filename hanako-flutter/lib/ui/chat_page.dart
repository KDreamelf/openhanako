import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/window_factory.dart';
import '../core/agent_runtime.dart';
import '../core/codex_agent_runtime.dart';
import '../core/engine.dart';
import '../core/runtime_session_store.dart';
import '../experience/experience.dart';
import '../llm/provider.dart';
import '../windows_ops/windows_ops.dart';
import 'design/design.dart';
import 'desk/desk_page.dart';
import 'memory/memory_page.dart';
import 'onboarding/onboarding_page.dart';
import 'skills/skills_page.dart';
import 'widgets/persistent_sidebar.dart';
import 'widgets/session_drawer.dart';
import 'widgets/status_cluster.dart';
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
    await sendBlocks(<RuntimeContentBlock>[RuntimeTextBlock(text)]);
  }

  Future<void> sendBlocks(List<RuntimeContentBlock> blocks) async {
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
      RuntimeDisplayMessage.userBlocks(blocks),
    ];
    final generation = ++_sendGeneration;
    _stopRetrying = false;
    _activeCancelToken = null;
    state = ChatState(history: inFlightMessages, streaming: true);

    await _sendWithRetries(
      blocks,
      committedMessages: committedMessages,
      inFlightMessages: inFlightMessages,
      generation: generation,
    );
  }

  Future<void> interruptWith(String text) async {
    await interruptWithBlocks(<RuntimeContentBlock>[RuntimeTextBlock(text)]);
  }

  Future<void> interruptWithBlocks(List<RuntimeContentBlock> blocks) async {
    final text = _blocksVisibleText(blocks);
    final trimmed = text.trim();
    if (trimmed.isEmpty && !_blocksHaveImage(blocks)) {
      stopRetrying();
      return;
    }
    if (!state.streaming) {
      await sendBlocks(blocks);
      return;
    }

    if (!_restored) {
      await restoreLastSession();
    }
    final eng = _ref.read(engineProvider);
    final committedMessages = eng.sessionCoordinator.currentDisplayMessages();
    final inFlightMessages = [
      ...committedMessages,
      RuntimeDisplayMessage.userBlocks(blocks),
    ];
    final generation = ++_sendGeneration;
    _cancelActiveTurn('用户插话');
    _stopRetrying = false;
    state = ChatState(history: inFlightMessages, streaming: true);

    await _sendWithRetries(
      blocks,
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
    List<RuntimeContentBlock> blocks, {
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
                .promptBlocks(blocks, cancelToken: token)
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

    void upsertToolResult(
      String id,
      String name,
      String content, {
      required bool isError,
      Map<String, dynamic>? details,
    }) {
      hadProgress = true;
      final index = toolCallIndices[id];
      if (index == null || index >= currentBlocks.length) {
        toolCallIndices[id] = currentBlocks.length;
        currentBlocks.add(
          RuntimeDisplayToolCallBlock(
            id: id,
            name: name.trim().isEmpty ? 'unknown_tool' : name,
            argsJson: '{}',
            resultContent: content,
            resultIsError: isError,
            resultDetails: details,
          ),
        );
      } else {
        final old = currentBlocks[index];
        if (old is RuntimeDisplayToolCallBlock) {
          currentBlocks[index] = RuntimeDisplayToolCallBlock(
            id: id,
            name: name.trim().isNotEmpty ? name : old.name,
            argsJson: old.argsJson,
            resultContent: content,
            resultIsError: isError,
            resultDetails: details,
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
          case ToolCallResult(
            :final id,
            :final name,
            :final content,
            :final isError,
            :final details,
          ):
            upsertToolResult(
              id,
              name,
              content,
              isError: isError,
              details: details,
            );
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

String _prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

String _blocksVisibleText(List<RuntimeContentBlock> blocks) {
  return blocks
      .whereType<RuntimeTextBlock>()
      .map((block) => block.text)
      .join()
      .trim();
}

bool _blocksHaveImage(List<RuntimeContentBlock> blocks) =>
    blocks.any((block) => block is RuntimeImageBlock);

class ComposerImageAttachment {
  const ComposerImageAttachment({
    required this.dataUrl,
    required this.mimeType,
    required this.label,
    this.path,
  });

  final String dataUrl;
  final String mimeType;
  final String label;
  final String? path;

  RuntimeImageBlock toRuntimeBlock() => RuntimeImageBlock(
    dataUrl: dataUrl,
    mimeType: mimeType,
    label: label,
    path: path,
  );
}

class ImageComposerController extends TextEditingController {
  static const imageToken = '\uFFFC';
  final _images = <ComposerImageAttachment>[];

  bool get hasComposedContent =>
      text.replaceAll(imageToken, '').trim().isNotEmpty || _images.isNotEmpty;

  void insertImage(ComposerImageAttachment image) {
    final current = value;
    final selection = current.selection;
    final start = selection.start < 0 ? current.text.length : selection.start;
    final end = selection.end < 0 ? current.text.length : selection.end;
    final imageIndex = _imageIndexBeforeOffset(current.text, start);
    _images.insert(imageIndex.clamp(0, _images.length), image);
    final nextText = current.text.replaceRange(start, end, imageToken);
    final caret = start + imageToken.length;
    value = current.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: caret),
      composing: TextRange.empty,
    );
  }

  List<RuntimeContentBlock> toRuntimeBlocks() {
    final blocks = <RuntimeContentBlock>[];
    final buffer = StringBuffer();
    var imageIndex = 0;

    void flushText() {
      if (buffer.isEmpty) return;
      blocks.add(RuntimeTextBlock(buffer.toString()));
      buffer.clear();
    }

    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == imageToken) {
        flushText();
        if (imageIndex < _images.length) {
          blocks.add(_images[imageIndex].toRuntimeBlock());
        }
        imageIndex++;
      } else {
        buffer.write(char);
      }
    }
    flushText();
    return blocks;
  }

  void clearComposed() {
    clear();
    _images.clear();
  }

  @override
  set value(TextEditingValue newValue) {
    super.value = newValue;
    _syncImagesToText();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();
    var imageIndex = 0;

    void flushText() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(text: buffer.toString(), style: style));
      buffer.clear();
    }

    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == imageToken) {
        flushText();
        final image = imageIndex < _images.length ? _images[imageIndex] : null;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _ComposerImageChip(label: image?.label ?? '图片'),
          ),
        );
        imageIndex++;
      } else {
        buffer.write(char);
      }
    }
    flushText();
    return TextSpan(style: style, children: spans);
  }

  void _syncImagesToText() {
    final count = _imageTokenCount(text);
    while (_images.length > count) {
      _images.removeLast();
    }
  }
}

class _ComposerImageChip extends StatelessWidget {
  const _ComposerImageChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = palette.accentEmerald;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: DS.s8, vertical: 3),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: palette.isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(DS.rPill),
        border: Border.all(color: accent.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_outlined, size: 13, color: accent),
          const SizedBox(width: DS.s4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent,
                fontSize: DS.t11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

int _imageTokenCount(String text) => imageTokenMatches(text).length;

Iterable<RegExpMatch> imageTokenMatches(String text) =>
    RegExp(ImageComposerController.imageToken).allMatches(text);

int _imageIndexBeforeOffset(String text, int offset) {
  final safeOffset = offset.clamp(0, text.length);
  return _imageTokenCount(text.substring(0, safeOffset));
}

Future<ComposerImageAttachment?> _readClipboardImage() async {
  if (!Platform.isWindows) return null;
  final tempDir = await Directory.systemTemp.createTemp('ph01_clipboard_');
  final imagePath =
      '${tempDir.path}${Platform.pathSeparator}clipboard_${DateTime.now().millisecondsSinceEpoch}.png';
  final escapedPath = imagePath.replaceAll("'", "''");
  final script =
      '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
  \$image = [System.Windows.Forms.Clipboard]::GetImage()
  \$image.Save('$escapedPath', [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Output '$escapedPath'
}
''';
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-STA',
      '-Command',
      script,
    ], runInShell: false).timeout(const Duration(seconds: 2));
    if (result.exitCode != 0) return null;
    final file = File(imagePath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return ComposerImageAttachment(
      dataUrl: 'data:image/png;base64,${base64Encode(bytes)}',
      mimeType: 'image/png',
      label: '剪贴板图片',
      path: imagePath,
    );
  } catch (_) {
    return null;
  }
}

String _mimeTypeForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  return 'image/png';
}

String _fileName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
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
  final _input = ImageComposerController();
  final _scroll = ScrollController();
  bool _onboardingShown = false;

  /// Codex 待授权请求 — 弹出底部横条而不是 modal dialog，让对话能保持
  /// 在视野里。当用户做出决定后通过 [_pendingPermissionCompleter] 完成 future。
  CodexPermissionRequest? _pendingPermissionRequest;
  Completer<CodexPermissionDecision?>? _pendingPermissionCompleter;

  void _resolvePendingPermission(CodexPermissionDecision? decision) {
    final completer = _pendingPermissionCompleter;
    if (completer == null) return;
    if (!completer.isCompleted) completer.complete(decision);
    if (mounted) {
      setState(() {
        _pendingPermissionRequest = null;
        _pendingPermissionCompleter = null;
      });
    } else {
      _pendingPermissionRequest = null;
      _pendingPermissionCompleter = null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(engineProvider)
          .sessionCoordinator
          .setCodexPermissionPrompt(_showCodexPermissionDialog);
      ref
          .read(engineProvider)
          .sessionCoordinator
          .setCodexUserInputPrompt(_showCodexUserInputDialog);
      unawaited(ref.read(chatProvider.notifier).restoreLastSession());
    });
  }

  @override
  void dispose() {
    ref.read(engineProvider).sessionCoordinator.setCodexPermissionPrompt(null);
    ref.read(engineProvider).sessionCoordinator.setCodexUserInputPrompt(null);
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

  Future<CodexPermissionDecision?> _showCodexPermissionDialog(
    CodexPermissionRequest request,
  ) async {
    if (!mounted) return null;
    // 已经有一个待处理请求时，先拒绝旧的让后到的覆盖。
    if (_pendingPermissionCompleter != null) {
      _resolvePendingPermission(null);
    }
    final completer = Completer<CodexPermissionDecision?>();
    setState(() {
      _pendingPermissionRequest = request;
      _pendingPermissionCompleter = completer;
    });
    return completer.future;
  }

  Future<void> _showPermissionDetailsDialog() async {
    final request = _pendingPermissionRequest;
    if (request == null || !mounted) return;
    final palette = context.palette;
    final decision = await showDialog<CodexPermissionDecision>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final permissionsText = _prettyJson(request.permissions);
        return AlertDialog(
          icon: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: palette.accentAmber.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(DS.r8),
              border: Border.all(
                color: palette.accentAmber.withValues(alpha: 0.42),
              ),
            ),
            child: Icon(
              Icons.policy_outlined,
              color: palette.accentAmber,
              size: 18,
            ),
          ),
          title: const Text('Codex 工具授权'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.reason?.trim().isNotEmpty == true
                      ? request.reason!.trim()
                      : '模型请求临时提升本地工具权限。',
                  style: TextStyle(color: palette.textPrimary, height: 1.5),
                ),
                const SizedBox(height: DS.s12),
                Text(
                  '请求权限',
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: DS.t12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: DS.s6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  decoration: BoxDecoration(
                    color: palette.bgRaised,
                    borderRadius: BorderRadius.circular(DS.r8),
                    border: Border.all(color: palette.divider),
                  ),
                  padding: const EdgeInsets.all(DS.s12),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      permissionsText,
                      style: TextStyle(
                        fontFamilyFallback: DS.monoFallback,
                        fontSize: DS.t12,
                        height: 1.45,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: DS.s10),
                Text(
                  '可以在设置页把 Codex 权限模式改为“完全授权”，后续将自动批准。',
                  style: TextStyle(
                    color: palette.textTertiary,
                    fontSize: DS.t12,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(
                const CodexPermissionDecision(
                  approved: false,
                  scope: 'none',
                  message: '用户拒绝授权。',
                ),
              ),
              child: const Text('拒绝'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(
                CodexPermissionDecision(
                  approved: true,
                  scope: 'turn',
                  permissions: request.permissions,
                  message: '用户批准本次授权。',
                ),
              ),
              child: const Text('允许本次'),
            ),
          ],
        );
      },
    );
    if (decision != null) {
      _resolvePendingPermission(decision);
    }
  }

  Future<CodexUserInputResponse?> _showCodexUserInputDialog(
    CodexUserInputRequest request,
  ) async {
    if (!mounted) return null;
    final selections = <String, String>{
      for (final question in request.questions)
        question.id: question.options.first.label,
    };
    final otherControllers = <String, TextEditingController>{
      for (final question in request.questions)
        question.id: TextEditingController(),
    };
    try {
      return await showDialog<CodexUserInputResponse>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('需要你的选择'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final question in request.questions) ...[
                        Text(
                          question.header,
                          style: Theme.of(ctx).textTheme.labelLarge,
                        ),
                        const SizedBox(height: DS.s4),
                        Text(question.question),
                        const SizedBox(height: DS.s8),
                        for (final option in question.options)
                          _ChoiceRow(
                            selected: selections[question.id] == option.label,
                            title: option.label,
                            subtitle: option.description,
                            onTap: () => setDialogState(
                              () => selections[question.id] = option.label,
                            ),
                          ),
                        _ChoiceRow(
                          selected: selections[question.id] == '__other__',
                          title: '其他',
                          onTap: () => setDialogState(
                            () => selections[question.id] = '__other__',
                          ),
                        ),
                        if (selections[question.id] == '__other__')
                          TextField(
                            controller: otherControllers[question.id],
                            autofocus: true,
                            decoration: const InputDecoration(
                              labelText: '输入自定义答案',
                            ),
                          ),
                        const SizedBox(height: DS.s14),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(
                    const CodexUserInputResponse(
                      answers: <String, String>{},
                      cancelled: true,
                    ),
                  ),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final answers = <String, String>{};
                    for (final question in request.questions) {
                      final selected = selections[question.id];
                      if (selected == '__other__') {
                        answers[question.id] =
                            otherControllers[question.id]?.text.trim() ?? '';
                      } else if (selected != null) {
                        answers[question.id] = selected;
                      }
                    }
                    Navigator.of(
                      ctx,
                    ).pop(CodexUserInputResponse(answers: answers));
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      for (final controller in otherControllers.values) {
        controller.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatProvider);
    final activeAgent = ref.watch(activeAgentIdProvider);
    final eng = ref.watch(engineProvider);
    final identity = ref.watch(currentIdentityProvider);
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
    final selectedModel = selectedChatModelId(eng);

    final cfg = eng.config.read();
    final authCfg = cfg['auth'] is Map ? cfg['auth'] as Map : const {};
    final userCfg = cfg['user'] is Map ? cfg['user'] as Map : const {};
    String? readStr(Object? v) {
      if (v is! String && v is! num) return null;
      final t = '$v'.trim();
      return t.isEmpty ? null : t;
    }

    final ownerName = readStr(authCfg['username']) ?? readStr(userCfg['name']);
    final ownerId = readStr(authCfg['user_id']);

    ref.listen<ChatState>(chatProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: DS.dBase,
            curve: DS.cStandard,
          );
        }
      });
    });

    final canUseComposer =
        activeAgent != null && identity != null && selectedModel != null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: SessionDrawer(
        onNewSession: () => ref.read(chatProvider.notifier).createSession(),
        onSwitchSession: (entry) =>
            ref.read(chatProvider.notifier).switchSession(entry.path),
      ),
      body: AmbientBackground(
        child: LayoutBuilder(
          builder: (layoutCtx, box) {
            final wide = box.maxWidth >= 1100;
            final palette = context.palette;
            final mainColumn = Column(
              children: [
                Builder(
                  builder: (shellContext) => _ChatHeader(
                    activeAgent: activeAgent,
                    identityReady: identity != null,
                    selectedModel: selectedModel,
                    networkStatus: networkStatus,
                    networkStatusLoading: networkStatusValue.isLoading,
                    networkStatusError: networkStatusError,
                    windowsOpsStatus: windowsOpsStatus,
                    windowsOpsStatusLoading: windowsOpsStatusValue.isLoading,
                    windowsOpsStatusError: windowsOpsStatusError,
                    messageCount: state.history.length,
                    streaming: state.streaming,
                    canClear: state.history.isNotEmpty && !state.streaming,
                    ownerName: ownerName,
                    ownerId: ownerId,
                    hideSessionsButton: wide,
                    onOpenSessions: () =>
                        Scaffold.of(shellContext).openDrawer(),
                    onClear: () => ref.read(chatProvider.notifier).clear(),
                    onOpenDesk: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const DeskPage())),
                    onOpenMemory: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const MemoryPage()),
                    ),
                    onOpenSkills: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SkillsPage()),
                    ),
                    onOpenSettings: () => WindowFactory.openSettings(context),
                    onUnlockIdentity: identity == null ? _unlockIdentity : null,
                    onChooseModel: state.streaming ? null : _chooseModel,
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: DS.workspaceWidth,
                      ),
                      child: ScrollConfiguration(
                        behavior: const _DesktopScrollBehavior(),
                        child: ListView(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(
                            DS.s24,
                            DS.s20,
                            DS.s24,
                            DS.s32,
                          ),
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
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: DS.s8,
                                ),
                                child: HanaBanner(
                                  icon: Icons.autorenew,
                                  leadingLabel: 'RETRYING',
                                  title: state.retrying!.title,
                                  subtitle: state.retrying!.message,
                                  color: context.palette.accentAmber,
                                  trailing: GlassButton(
                                    label: '停止',
                                    icon: Icons.stop_circle_outlined,
                                    onPressed: () => ref
                                        .read(chatProvider.notifier)
                                        .stopRetrying(),
                                    dense: true,
                                  ),
                                ),
                              ),
                            if (state.error != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: DS.s8,
                                ),
                                child: _ErrorBanner(
                                  message: state.error!,
                                  details: state.errorDetails,
                                  statusCode: state.errorStatusCode,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (_pendingPermissionRequest != null)
                  _PendingPermissionBanner(
                    request: _pendingPermissionRequest!,
                    onDeny: () => _resolvePendingPermission(
                      const CodexPermissionDecision(
                        approved: false,
                        scope: 'none',
                        message: '用户拒绝授权。',
                      ),
                    ),
                    onApprove: () => _resolvePendingPermission(
                      CodexPermissionDecision(
                        approved: true,
                        scope: 'turn',
                        permissions: _pendingPermissionRequest!.permissions,
                        message: '用户批准本次授权。',
                      ),
                    ),
                    onShowDetails: _showPermissionDetailsDialog,
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
            );

            if (!wide) return mainColumn;

            return Row(
              children: [
                PersistentSidebar(
                  onNewSession: () =>
                      ref.read(chatProvider.notifier).createSession(),
                  onSwitchSession: (entry) =>
                      ref.read(chatProvider.notifier).switchSession(entry.path),
                ),
                Container(width: DS.hairline, color: palette.divider),
                Expanded(child: mainColumn),
              ],
            );
          },
        ),
      ),
    );
  }

  void _send() {
    final blocks = _input.toRuntimeBlocks();
    if (!_blocksHaveImage(blocks) && _blocksVisibleText(blocks).isEmpty) {
      return;
    }
    _input.clearComposed();
    final notifier = ref.read(chatProvider.notifier);
    if (ref.read(chatProvider).streaming) {
      unawaited(notifier.interruptWithBlocks(blocks));
      return;
    }
    unawaited(notifier.sendBlocks(blocks));
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
    final palette = context.palette;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                palette.accentEmerald.withValues(alpha: 0.32),
                palette.accentCyan.withValues(alpha: 0.20),
              ],
            ),
            borderRadius: BorderRadius.circular(DS.r8),
            border: Border.all(
              color: palette.accentEmerald.withValues(alpha: 0.42),
            ),
          ),
          child: Icon(
            Icons.hub_outlined,
            color: palette.accentEmerald,
            size: 18,
          ),
        ),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('选择模型'),
            const SizedBox(height: 4),
            Text(
              '共 ${models.length} 个可用',
              style: TextStyle(
                color: palette.textTertiary,
                fontSize: DS.t11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: models.length,
              itemBuilder: (_, i) {
                final model = models[i];
                final selected = model.id == current;
                return _ModelChoiceTile(
                  model: model,
                  selected: selected,
                  onTap: () => Navigator.pop(ctx, model.id),
                );
              },
            ),
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

class _ModelChoiceTile extends StatefulWidget {
  const _ModelChoiceTile({
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final dynamic model; // ModelDescriptor — keep dynamic to avoid cross-import
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ModelChoiceTile> createState() => _ModelChoiceTileState();
}

class _ModelChoiceTileState extends State<_ModelChoiceTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final selected = widget.selected;
    final accent = palette.accentEmerald;
    final bgColor = selected
        ? accent.withValues(alpha: palette.isDark ? 0.14 : 0.10)
        : _hover
        ? palette.glassFill
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DS.dFast,
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(DS.r10),
          border: selected
              ? Border.all(color: accent.withValues(alpha: 0.42))
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(DS.r10),
          child: InkWell(
            borderRadius: BorderRadius.circular(DS.r10),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DS.s12,
                vertical: DS.s10,
              ),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: selected
                          ? accent.withValues(alpha: 0.22)
                          : palette.glassFill,
                      borderRadius: BorderRadius.circular(DS.r6),
                      border: Border.all(
                        color: selected
                            ? accent.withValues(alpha: 0.45)
                            : palette.glassBorder,
                      ),
                    ),
                    child: Icon(
                      Icons.hub_outlined,
                      size: 14,
                      color: selected ? accent : palette.textSecondary,
                    ),
                  ),
                  const SizedBox(width: DS.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.model.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t14,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.model.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textTertiary,
                            fontSize: DS.t11,
                            fontFamilyFallback: DS.monoFallback,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: DS.s8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: DS.s8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(DS.rPill),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.42),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_rounded, size: 12, color: accent),
                          const SizedBox(width: 4),
                          Text(
                            'CURRENT',
                            style: TextStyle(
                              color: accent,
                              fontSize: DS.t10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopScrollBehavior extends ScrollBehavior {
  const _DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: false,
      trackVisibility: false,
      thickness: 6,
      radius: const Radius.circular(DS.r8),
      child: child,
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.selected,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final bool selected;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: DS.s4),
      child: Material(
        color: selected
            ? palette.accentEmerald.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(DS.r8),
        child: InkWell(
          borderRadius: BorderRadius.circular(DS.r8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DS.s10,
              vertical: DS.s10,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected
                      ? palette.accentEmerald
                      : palette.textTertiary,
                ),
                const SizedBox(width: DS.s10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      if (subtitle?.trim().isNotEmpty == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitle!.trim(),
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: DS.t12,
                              height: 1.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// Header
// =====================================================================

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.activeAgent,
    required this.identityReady,
    required this.selectedModel,
    required this.networkStatus,
    required this.networkStatusLoading,
    required this.networkStatusError,
    required this.windowsOpsStatus,
    required this.windowsOpsStatusLoading,
    required this.windowsOpsStatusError,
    required this.messageCount,
    required this.streaming,
    required this.canClear,
    required this.ownerName,
    required this.ownerId,
    required this.hideSessionsButton,
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
  final ExperienceNetworkStatus? networkStatus;
  final bool networkStatusLoading;
  final String? networkStatusError;
  final WindowsOpsCapabilities? windowsOpsStatus;
  final bool windowsOpsStatusLoading;
  final String? windowsOpsStatusError;
  final int messageCount;
  final bool streaming;
  final bool canClear;
  final String? ownerName;
  final String? ownerId;

  /// 宽屏（常驻 sidebar 已显示）时设为 true，会话/菜单按钮就不再出现，
  /// 避免与左侧 sidebar 重复。
  final bool hideSessionsButton;

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
    final palette = context.palette;
    final subtitleText = activeAgent == null
        ? '尚未选择 Agent · ${streaming ? "响应中" : "就绪"} · $messageCount 条消息'
        : '$activeAgent · ${streaming ? "响应中" : "就绪"} · $messageCount 条消息';

    final statusItems = <StatusClusterItem>[
      StatusClusterItem(
        icon: Icons.account_tree_outlined,
        label: activeAgent == null ? '未选 Agent' : 'Agent 已连接',
        color: activeAgent == null
            ? palette.accentCrimson
            : palette.accentEmerald,
      ),
      StatusClusterItem(
        icon: Icons.key_outlined,
        label: identityReady ? '身份已解锁' : '身份未解锁',
        color: identityReady ? palette.accentEmerald : palette.accentCrimson,
        tooltip: identityReady ? null : '尝试解锁本机身份',
        onPressed: onUnlockIdentity,
      ),
      StatusClusterItem(
        icon: Icons.lan_outlined,
        label: _networkStatusLabel(
          networkStatus,
          loading: networkStatusLoading,
          error: networkStatusError,
        ),
        color: _networkStatusColor(
          palette,
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
        icon: Icons.ads_click_outlined,
        label: _windowsOpsStatusLabel(
          windowsOpsStatus,
          loading: windowsOpsStatusLoading,
          error: windowsOpsStatusError,
        ),
        color: _windowsOpsStatusColor(
          palette,
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
      StatusClusterItem(
        icon: Icons.memory_outlined,
        label: selectedModel == null ? '未选模型' : '模型已选择',
        color: selectedModel == null
            ? palette.accentAmber
            : palette.accentEmerald,
      ),
    ];

    final actions = Wrap(
      spacing: DS.s4,
      runSpacing: DS.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        GlassIconButton(
          icon: Icons.cleaning_services_outlined,
          tooltip: '清空当前会话',
          onPressed: canClear ? onClear : null,
        ),
        GlassIconButton(
          icon: Icons.psychology_outlined,
          tooltip: '记忆',
          onPressed: onOpenMemory,
        ),
        GlassIconButton(
          icon: Icons.folder_outlined,
          tooltip: '书桌',
          onPressed: onOpenDesk,
        ),
        GlassIconButton(
          icon: Icons.extension_outlined,
          tooltip: '技能',
          onPressed: onOpenSkills,
        ),
        GlassIconButton(
          icon: Icons.tune,
          tooltip: '设置',
          onPressed: onOpenSettings,
        ),
        GlassButton(
          onPressed: onChooseModel,
          icon: Icons.hub_outlined,
          label: selectedModel ?? '选择模型',
          height: 32,
          dense: true,
          tooltip: selectedModel ?? '点击选择模型',
        ),
      ],
    );

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
            vertical: DS.s10,
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final compact = box.maxWidth < 760;
              final status = StatusCluster(
                items: statusItems,
                expandLeft: !compact,
                spacing: DS.s4,
                runSpacing: DS.s4,
                collapsedSize: 24,
                iconSize: 13,
              );

              final titleBlock = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          '子体控制台',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t18,
                            fontWeight: FontWeight.w700,
                            height: 1.1,
                            letterSpacing: 0.2,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: DS.s8),
                      _LiveStatusBadge(streaming: streaming),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitleText,
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: DS.t12,
                      height: 1.3,
                      letterSpacing: 0.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              );

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (!hideSessionsButton) ...[
                          GlassIconButton(
                            icon: Icons.menu,
                            tooltip: '会话',
                            onPressed: onOpenSessions,
                          ),
                          const SizedBox(width: DS.s10),
                        ],
                        Expanded(child: titleBlock),
                        const SizedBox(width: DS.s10),
                        status,
                      ],
                    ),
                    const SizedBox(height: DS.s8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(child: actions),
                        if (ownerName != null) ...[
                          const SizedBox(width: DS.s10),
                          _OwnerCard(name: ownerName!, id: ownerId),
                        ],
                      ],
                    ),
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (!hideSessionsButton) ...[
                    GlassIconButton(
                      icon: Icons.menu,
                      tooltip: '会话',
                      onPressed: onOpenSessions,
                    ),
                    const SizedBox(width: DS.s12),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: titleBlock,
                  ),
                  const SizedBox(width: DS.s14),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        runAlignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: DS.s12,
                        runSpacing: DS.s4,
                        children: [status, actions],
                      ),
                    ),
                  ),
                  if (ownerName != null) ...[
                    const SizedBox(width: DS.s16),
                    Container(width: 1, height: 22, color: palette.divider),
                    const SizedBox(width: DS.s12),
                    _OwnerCard(name: ownerName!, id: ownerId),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _OwnerCard extends StatefulWidget {
  const _OwnerCard({required this.name, this.id});

  final String name;
  final String? id;

  @override
  State<_OwnerCard> createState() => _OwnerCardState();
}

class _OwnerCardState extends State<_OwnerCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DS.dFast,
        padding: const EdgeInsets.fromLTRB(DS.s8, 3, DS.s6, 3),
        decoration: BoxDecoration(
          color: _hover ? palette.glassFillStrong : Colors.transparent,
          borderRadius: BorderRadius.circular(DS.rPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'LOCAL OWNER',
                  style: TextStyle(
                    color: palette.textTertiary,
                    fontSize: DS.t10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 2),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: DS.t13,
                      fontWeight: FontWeight.w700,
                      height: 1.0,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: DS.s8),
            HanaAvatar(label: widget.name, size: 30),
          ],
        ),
      ),
    );
  }
}

class _LiveStatusBadge extends StatelessWidget {
  const _LiveStatusBadge({required this.streaming});

  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = streaming ? palette.accentEmerald : palette.textSecondary;
    final label = streaming ? '响应中' : '就绪';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: DS.s8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: palette.isDark ? 0.10 : 0.08),
        borderRadius: BorderRadius.circular(DS.rPill),
        border: Border.all(
          color: color.withValues(
            alpha: streaming ? 0.42 : (palette.isDark ? 0.18 : 0.22),
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: color, size: 6, pulse: streaming, glow: true),
          const SizedBox(width: DS.s6),
          Text(
            label,
            style: TextStyle(
              color: Color.lerp(palette.textSecondary, color, 0.7)!,
              fontSize: DS.t10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

// -- Status label / color / tooltip helpers --

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
    parts.add('IPv6 直连');
  }
  if (status.ipv4Status == ExperienceNetworkPathStatus.holePunchable) {
    parts.add('IPv4 打洞');
  } else if (status.ipv4Status == ExperienceNetworkPathStatus.notPunchable) {
    parts.add('IPv4 不可打洞');
  }
  if (parts.length == 1) {
    parts.add(status.bestModeLabel);
  }
  return parts.join(' · ');
}

Color _networkStatusColor(
  HanaPalette palette,
  ExperienceNetworkStatus? status, {
  required bool loading,
  String? error,
}) {
  if (status == null) {
    return loading ? palette.accentCyan : palette.accentCrimson;
  }
  if (error != null || status.error != null || status.connectedDhtCount == 0) {
    return palette.accentCrimson;
  }
  if (status.ipv6Status == ExperienceNetworkPathStatus.direct) {
    return palette.accentEmerald;
  }
  if (status.ipv4Status == ExperienceNetworkPathStatus.holePunchable) {
    return palette.accentEmerald;
  }
  if (status.ipv4Status == ExperienceNetworkPathStatus.notPunchable) {
    return palette.accentAmber;
  }
  return palette.accentCrimson;
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
  HanaPalette palette,
  WindowsOpsCapabilities? status, {
  required bool loading,
  String? error,
}) {
  if (status == null) {
    return loading ? palette.accentCyan : palette.accentCrimson;
  }
  if (error != null || !status.sidecar) return palette.accentCrimson;
  if (status.inputMouse &&
      status.inputKeyboard &&
      status.uiParsing &&
      status.ocr) {
    return palette.accentEmerald;
  }
  if (status.inputMouse || status.inputKeyboard || status.uiaTree) {
    return palette.accentEmerald;
  }
  return palette.accentAmber;
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

// =====================================================================
// Composer
// =====================================================================

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

  final ImageComposerController controller;
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
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'chat-composer');
    _focusNode.onKeyEvent = _handleKeyEvent;
    _focusNode.addListener(_onFocusChanged);
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
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    final has = _focusNode.hasFocus;
    if (has != _focused) setState(() => _focused = has);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final hintText = widget.activeAgent == null
        ? '请先创建或选择 Agent'
        : !widget.identityReady
        ? '请先创建或解锁子体身份'
        : widget.selectedModel == null
        ? '请先选择模型'
        : widget.streaming
        ? '输入插话，或留空停止当前回复'
        : '继续输入：让子体把这个方向落到下一步…';
    final hasContent = widget.controller.hasComposedContent;
    final stopOnly = widget.streaming && !hasContent;
    final buttonEnabled = widget.canSend && (hasContent || stopOnly);
    final buttonIcon = stopOnly
        ? Icons.stop_rounded
        : Icons.arrow_upward_rounded;
    final buttonLabel = stopOnly ? '停止' : '发送';
    final buttonAction = stopOnly ? widget.onStop : widget.onSend;

    return Container(
      decoration: BoxDecoration(
        color: palette.bgRaised.withValues(alpha: palette.isDark ? 0.55 : 0.86),
        border: Border(
          top: BorderSide(color: palette.divider, width: DS.hairline),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: DS.workspaceWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                DS.s20,
                DS.s12,
                DS.s20,
                DS.s14,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: _ComposerInputShell(
                      focused: _focused,
                      leadingIcon: widget.canSend
                          ? _ComposerAttachButton(onPressed: _pickImageFile)
                          : const SizedBox(width: DS.s10),
                      child: TextField(
                        focusNode: _focusNode,
                        controller: widget.controller,
                        enabled: widget.canSend,
                        minLines: 1,
                        maxLines: 6,
                        keyboardType: TextInputType.multiline,
                        cursorColor: palette.accentEmerald,
                        decoration: InputDecoration(
                          hintText: hintText,
                          hintStyle: TextStyle(
                            color: palette.textTertiary,
                            fontSize: DS.t15,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          filled: false,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 0,
                            vertical: DS.s14,
                          ),
                          isCollapsed: false,
                        ),
                        style: TextStyle(
                          fontSize: DS.t15,
                          height: 1.5,
                          color: palette.textPrimary,
                        ),
                        textInputAction: TextInputAction.newline,
                      ),
                    ),
                  ),
                  const SizedBox(width: DS.s12),
                  _CircleSendButton(
                    icon: buttonIcon,
                    label: buttonLabel,
                    onPressed: buttonEnabled ? buttonAction : null,
                    danger: stopOnly,
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
    final isPaste =
        key == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed);
    if (isPaste) {
      unawaited(_pasteFromClipboard());
      return KeyEventResult.handled;
    }
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

  Future<void> _pickImageFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '图片',
          extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
        ),
      ],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    _insertImageBytes(
      bytes,
      label: _fileName(file.path),
      path: file.path,
      mimeType: _mimeTypeForPath(file.path),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final image = await _readClipboardImage();
    if (image != null) {
      widget.controller.insertImage(image);
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _insertText(text);
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _insertNewline() {
    _insertText('\n');
  }

  void _insertText(String inserted) {
    final value = widget.controller.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final nextText = text.replaceRange(start, end, inserted);
    final caret = start + inserted.length;
    widget.controller.value = value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: caret),
      composing: TextRange.empty,
    );
  }

  void _insertImageBytes(
    Uint8List bytes, {
    required String label,
    required String mimeType,
    String? path,
  }) {
    widget.controller.insertImage(
      ComposerImageAttachment(
        dataUrl: 'data:$mimeType;base64,${base64Encode(bytes)}',
        mimeType: mimeType,
        label: label,
        path: path,
      ),
    );
  }
}

class _ComposerInputShell extends StatelessWidget {
  const _ComposerInputShell({
    required this.focused,
    required this.leadingIcon,
    required this.child,
  });

  /// 父级管理的 focus 状态，统一控制边框高亮。
  final bool focused;

  /// 左侧内嵌的小附件按钮（可以是 SizedBox.shrink 占位）。
  final Widget leadingIcon;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AnimatedContainer(
      duration: DS.dQuick,
      curve: DS.cStandard,
      decoration: BoxDecoration(
        color: palette.bgDeep.withValues(alpha: palette.isDark ? 0.66 : 0.50),
        borderRadius: BorderRadius.circular(DS.r14),
        border: Border.all(
          color: focused
              ? palette.accentEmerald.withValues(alpha: 0.55)
              : palette.divider,
          width: focused ? 1.4 : DS.hairline,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: palette.accentEmerald.withValues(alpha: 0.10),
                  blurRadius: 16,
                ),
              ]
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: DS.s8),
            child: leadingIcon,
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _ComposerAttachButton extends StatefulWidget {
  const _ComposerAttachButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_ComposerAttachButton> createState() => _ComposerAttachButtonState();
}

class _ComposerAttachButtonState extends State<_ComposerAttachButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Tooltip(
      message: '添加图片 (Ctrl+V 粘贴)',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: DS.dFast,
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: _hover
                ? palette.accentEmerald.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DS.r8),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(DS.r8),
            child: InkWell(
              borderRadius: BorderRadius.circular(DS.r8),
              onTap: widget.onPressed,
              child: Center(
                child: Icon(
                  Icons.add_photo_alternate_outlined,
                  size: 16,
                  color: _hover ? palette.accentEmerald : palette.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CircleSendButton extends StatefulWidget {
  const _CircleSendButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.danger,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// 停止状态 — 用 crimson 描边强调。
  final bool danger;

  @override
  State<_CircleSendButton> createState() => _CircleSendButtonState();
}

class _CircleSendButtonState extends State<_CircleSendButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final enabled = widget.onPressed != null;
    final accent = widget.danger
        ? palette.accentCrimson
        : palette.accentEmerald;

    // 设计图: 白色圆形按钮 + 内部深色 icon。
    // 在浅色主题: bg = pure white; 在深色主题: bg = warm off-white。
    final baseBg = palette.isDark ? const Color(0xFFEEF2F5) : Colors.white;
    final bg = !enabled
        ? baseBg.withValues(alpha: 0.45)
        : _pressed
        ? Color.lerp(baseBg, accent.withValues(alpha: 1), 0.10)!
        : (_hover
              ? Color.lerp(baseBg, accent.withValues(alpha: 1), 0.06)!
              : baseBg);
    final fg = !enabled
        ? palette.textTertiary
        : (_hover ? accent : const Color(0xFF0E1A1F));
    return Tooltip(
      message: widget.label,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: _pressed ? 0.92 : (_hover && enabled ? 1.04 : 1.0),
          duration: DS.dFast,
          curve: DS.cStandard,
          child: AnimatedContainer(
            duration: DS.dFast,
            curve: DS.cStandard,
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bg,
              border: Border.all(
                color: enabled
                    ? (_hover
                          ? accent.withValues(alpha: 0.45)
                          : palette.divider)
                    : palette.divider,
                width: _hover && enabled ? 1.4 : DS.hairline,
              ),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: palette.isDark ? 0.32 : 0.10,
                        ),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                        spreadRadius: -2,
                      ),
                      if (_hover)
                        BoxShadow(
                          color: accent.withValues(alpha: 0.22),
                          blurRadius: 18,
                          spreadRadius: -4,
                          offset: const Offset(0, 6),
                        ),
                    ]
                  : null,
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onPressed,
                onHighlightChanged: (v) => setState(() => _pressed = v),
                splashColor: accent.withValues(alpha: 0.18),
                hoverColor: Colors.transparent,
                child: Center(child: Icon(widget.icon, color: fg, size: 22)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback? onPressed;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final enabled = widget.onPressed != null;
    final base = widget.accent;
    final bg = !enabled
        ? base.withValues(alpha: 0.30)
        : _pressed
        ? Color.lerp(base, Colors.black, 0.16)!
        : (_hover ? Color.lerp(base, Colors.white, 0.10)! : base);
    final fg = palette.isDark ? const Color(0xFF06120A) : Colors.white;
    return Tooltip(
      message: widget.label,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: _pressed ? 0.92 : (_hover && enabled ? 1.04 : 1.0),
          duration: DS.dFast,
          curve: DS.cStandard,
          child: AnimatedContainer(
            duration: DS.dFast,
            curve: DS.cStandard,
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: enabled
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color.lerp(bg, Colors.white, 0.06)!, bg],
                    )
                  : null,
              color: enabled ? null : bg,
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: base.withValues(alpha: 0.45),
                        blurRadius: 18,
                        spreadRadius: -2,
                        offset: const Offset(0, 6),
                      ),
                      BoxShadow(
                        color: Colors.white.withValues(
                          alpha: palette.isDark ? 0.18 : 0.32,
                        ),
                        blurRadius: 2,
                        spreadRadius: -1,
                        offset: const Offset(0, -1),
                      ),
                    ]
                  : null,
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onPressed,
                onHighlightChanged: (v) => setState(() => _pressed = v),
                splashColor: Colors.white.withValues(alpha: 0.18),
                hoverColor: Colors.transparent,
                child: Center(child: Icon(widget.icon, color: fg, size: 22)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// Empty hint / message bubble / error
// =====================================================================

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
    final palette = context.palette;
    final ready = activeAgent != null && identityReady && selectedModel != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DS.s40),
      child: Center(
        child: FadeSlideIn(
          child: GlassSurface(
            constraints: const BoxConstraints(maxWidth: 600),
            padding: const EdgeInsets.all(DS.s24),
            radius: DS.r14,
            intensity: GlassIntensity.regular,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            palette.accentEmerald.withValues(alpha: 0.24),
                            palette.accentCyan.withValues(alpha: 0.18),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(DS.r10),
                        border: Border.all(
                          color: palette.accentEmerald.withValues(alpha: 0.32),
                        ),
                      ),
                      child: Icon(
                        ready
                            ? Icons.bolt_outlined
                            : Icons.hourglass_top_outlined,
                        size: 22,
                        color: palette.accentEmerald,
                      ),
                    ),
                    const SizedBox(width: DS.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            ready ? '准备就绪' : '等待环境就绪',
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: DS.t18,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ready ? '随时输入指令开启新一轮对话。' : '完成以下项目后即可开始。',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: DS.t13,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: DS.s20),
                Wrap(
                  spacing: DS.s6,
                  runSpacing: DS.s6,
                  children: [
                    HanaPill(
                      icon: Icons.account_tree_outlined,
                      label: activeAgent == null
                          ? '等待 Agent'
                          : 'Agent: $activeAgent',
                      color: activeAgent == null
                          ? palette.accentCrimson
                          : palette.accentEmerald,
                    ),
                    HanaPill(
                      icon: Icons.key_outlined,
                      label: identityReady ? '身份可用' : '身份待解锁',
                      color: identityReady
                          ? palette.accentEmerald
                          : palette.accentCrimson,
                    ),
                    HanaPill(
                      icon: Icons.memory_outlined,
                      label: selectedModel == null
                          ? '模型待选择'
                          : '模型 · $selectedModel',
                      color: selectedModel == null
                          ? palette.accentAmber
                          : palette.accentEmerald,
                    ),
                  ],
                ),
                if (ready) ...[
                  const SizedBox(height: DS.s14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DS.s12,
                      vertical: DS.s10,
                    ),
                    decoration: BoxDecoration(
                      color: palette.bgDeep.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(DS.r8),
                      border: Border.all(color: palette.divider),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.keyboard_return_rounded,
                          size: 14,
                          color: palette.textTertiary,
                        ),
                        const SizedBox(width: DS.s8),
                        Text(
                          'Enter 发送',
                          style: TextStyle(
                            color: palette.textSecondary,
                            fontSize: DS.t12,
                          ),
                        ),
                        const SizedBox(width: DS.s14),
                        Icon(
                          Icons.keyboard_capslock_outlined,
                          size: 14,
                          color: palette.textTertiary,
                        ),
                        const SizedBox(width: DS.s8),
                        Text(
                          'Shift+Enter 换行',
                          style: TextStyle(
                            color: palette.textSecondary,
                            fontSize: DS.t12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
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
    final palette = context.palette;
    final hasDetails = details != null && details!.trim().isNotEmpty;
    final subtitle = statusCode == null
        ? message
        : 'HTTP $statusCode · $message';
    return HanaBanner(
      icon: Icons.error_outline_rounded,
      leadingLabel: 'ERROR',
      title: '请求失败',
      subtitle: subtitle,
      color: palette.accentCrimson,
      trailing: hasDetails
          ? GlassButton(
              label: '详情',
              icon: Icons.code_rounded,
              onPressed: () => _showDetails(context),
              dense: true,
            )
          : null,
    );
  }

  void _showDetails(BuildContext context) {
    final palette = context.palette;
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
                style: TextStyle(
                  fontFamilyFallback: DS.monoFallback,
                  height: 1.5,
                  color: palette.textPrimary,
                ),
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
    if (!mounted) return;
    await ref.read(chatProvider.notifier).editUserAt(widget.index, result);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final isUser = widget.message.role == 'user';
    final copyText = widget.message.copyText;
    final accent = isUser ? palette.accentLavender : palette.accentEmerald;
    final roleLabel = isUser ? 'USER' : 'HANAKO';

    final actions = <Widget>[
      _BubbleAction(
        icon: Icons.copy_rounded,
        tooltip: '复制',
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
        _BubbleAction(
          icon: Icons.edit_rounded,
          tooltip: '编辑并重新生成',
          onPressed: widget.streaming ? null : _editUserMessage,
        )
      else
        _BubbleAction(
          icon: Icons.refresh_rounded,
          tooltip: '重新生成',
          onPressed: widget.streaming
              ? null
              : () =>
                    ref.read(chatProvider.notifier).regenerateAt(widget.index),
        ),
      _BubbleAction(
        icon: Icons.delete_outline_rounded,
        tooltip: '删除',
        onPressed: widget.streaming
            ? null
            : () => ref.read(chatProvider.notifier).removeAt(widget.index),
      ),
    ];

    return RepaintBoundary(
      child: FadeSlideIn(
        duration: DS.dBase,
        offset: 6,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: DS.s10),
            child: Align(
              alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: isUser
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.6),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: DS.s6),
                        Text(
                          roleLabel,
                          style: TextStyle(
                            color: accent,
                            fontSize: DS.t10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 2),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    child: GlassSurface(
                      padding: const EdgeInsets.symmetric(
                        horizontal: DS.s16,
                        vertical: DS.s12,
                      ),
                      radius: DS.r12,
                      intensity: isUser
                          ? GlassIntensity.strong
                          : GlassIntensity.regular,
                      accent: accent,
                      elevated: !isUser,
                      child: MessageBlocksView(blocks: widget.message.blocks),
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: _hover ? 1 : 0,
                    duration: DS.dQuick,
                    curve: DS.cStandard,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: actions,
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

/// 底部"待授权动作"横条 — 对应设计图里的 WAITING FOR YOU 红调横条。
/// 显示在 Composer 上方，给用户快速拒绝/允许的入口；点击查看详情可弹出完整
/// 权限说明 dialog。
class _PendingPermissionBanner extends StatelessWidget {
  const _PendingPermissionBanner({
    required this.request,
    required this.onDeny,
    required this.onApprove,
    required this.onShowDetails,
  });

  final CodexPermissionRequest request;
  final VoidCallback onDeny;
  final VoidCallback onApprove;
  final VoidCallback onShowDetails;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = palette.accentCrimson;
    final reason = request.reason?.trim();
    final subtitle = reason != null && reason.isNotEmpty
        ? reason
        : '模型请求临时提升本地工具权限。';
    return Container(
      decoration: BoxDecoration(
        color: palette.bgRaised.withValues(alpha: palette.isDark ? 0.78 : 0.94),
        border: Border(
          top: BorderSide(color: accent.withValues(alpha: 0.36), width: 1.2),
        ),
      ),
      child: SafeArea(
        bottom: false,
        top: false,
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: DS.workspaceWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                DS.s20,
                DS.s12,
                DS.s20,
                DS.s12,
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(DS.r8),
                      border: Border.all(color: accent.withValues(alpha: 0.42)),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.28),
                          blurRadius: 10,
                          spreadRadius: -2,
                        ),
                      ],
                    ),
                    child: Icon(Icons.policy_outlined, color: accent, size: 18),
                  ),
                  const SizedBox(width: DS.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'WAITING FOR YOU',
                              style: TextStyle(
                                color: accent,
                                fontSize: DS.t10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.4,
                              ),
                            ),
                            const SizedBox(width: DS.s8),
                            StatusDot(color: accent, size: 5, pulse: true),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '待授权动作',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t14,
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textSecondary,
                            fontSize: DS.t12,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: DS.s10),
                  GlassButton(
                    icon: Icons.code_rounded,
                    label: '详情',
                    onPressed: onShowDetails,
                    dense: true,
                  ),
                  const SizedBox(width: DS.s6),
                  GlassButton(label: '拒绝', onPressed: onDeny, dense: true),
                  const SizedBox(width: DS.s6),
                  GlassButton(
                    label: '授权一次',
                    icon: Icons.check_rounded,
                    onPressed: onApprove,
                    accent: accent,
                    filled: true,
                    dense: true,
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

class _BubbleAction extends StatelessWidget {
  const _BubbleAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 15),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        padding: EdgeInsets.zero,
        color: palette.textSecondary,
        disabledColor: palette.textDisabled,
        splashRadius: 18,
        onPressed: enabled ? onPressed : null,
      ),
    );
  }
}
