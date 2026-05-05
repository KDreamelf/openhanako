import 'dart:async';

import '../llm/provider.dart';
import 'deep_memory.dart';
import 'memory_compile.dart';
import 'session_summary.dart';

/// 与 legacy lib/memory/memory-ticker.js 对齐：turn-based 调度器。
///
/// 周期：
///   - 每 6 轮 → 滚动摘要 + compileToday + assemble
///   - session 结束 → final 滚动摘要 + compileToday + assemble + deep-memory
///   - 每日一次（日期变化）→ compileWeek + compileLongterm + compileFacts
///                          + assemble + deep-memory
class MemoryTicker {
  MemoryTicker({
    required this.summaries,
    required this.compiler,
    required this.deepMemory,
    required this.summarizerProvider,
    required this.summarizerModel,
    this.turnsPerCheckpoint = 6,
    this.dailyCheckInterval = const Duration(hours: 1),
    this.isMemoryMasterEnabled,
    this.isSessionMemoryEnabled,
    this.loadMessages,
  });

  final SessionSummaryStore summaries;
  final MemoryCompiler compiler;
  final DeepMemory deepMemory;
  final LlmProvider summarizerProvider;
  final String summarizerModel;
  final int turnsPerCheckpoint;
  final Duration dailyCheckInterval;

  /// 全局开关。返回 false 时所有 ticker 操作 no-op。
  final bool Function()? isMemoryMasterEnabled;

  /// session 级开关。
  final bool Function(String sessionId)? isSessionMemoryEnabled;

  /// 调用方提供：根据 sessionId 加载完整 messages（用于 rollUp）。
  final Future<List<Message>> Function(String sessionId)? loadMessages;

  // 状态
  final _turnCounters = <String, int>{};
  final _dailyStepsCompleted = <String>{};
  String? _lastDailyDate;
  Timer? _dailyTimer;
  bool _running = false;

  bool get _masterOn => isMemoryMasterEnabled?.call() ?? true;
  bool _sessionOn(String sid) =>
      _masterOn && (isSessionMemoryEnabled?.call(sid) ?? true);

  void start() {
    if (_running) return;
    _running = true;
    _dailyTimer ??=
        Timer.periodic(dailyCheckInterval, (_) => _maybeRunDaily());
  }

  void stop() {
    _running = false;
    _dailyTimer?.cancel();
    _dailyTimer = null;
  }

  /// 每轮结束后由 SessionCoordinator 调用。
  Future<void> notifyTurn(String sessionId) async {
    if (!_sessionOn(sessionId)) return;
    final cnt = (_turnCounters[sessionId] ?? 0) + 1;
    _turnCounters[sessionId] = cnt;
    if (cnt % turnsPerCheckpoint != 0) return;

    await _rollAndAssemble(sessionId);
  }

  /// session 关闭时调用：final 滚动 + deep-memory。
  Future<void> notifySessionEnd(String sessionId) async {
    if (!_sessionOn(sessionId)) return;
    await _rollAndAssemble(sessionId);
    _turnCounters.remove(sessionId);
    try {
      await deepMemory.processDirty();
    } catch (_) {}
  }

  /// 强制刷新（日记功能等触发）。
  Future<void> flushSession(String sessionId) async {
    if (!_sessionOn(sessionId)) return;
    await _rollAndAssemble(sessionId);
  }

  Future<void> _rollAndAssemble(String sessionId) async {
    final loader = loadMessages;
    if (loader == null) return;
    try {
      final messages = await loader(sessionId);
      await summaries.rollUp(
        sessionId: sessionId,
        messages: messages,
        summarizer: summarizerProvider,
        model: summarizerModel,
      );
      await compiler.compileToday();
      await compiler.assemble();
    } catch (_) {
      // ticker 不抛出，避免影响主流程
    }
  }

  /// 跨日检查：日期变化触发 compileWeek + compileLongterm + compileFacts。
  Future<void> _maybeRunDaily() async {
    if (!_masterOn) return;
    final today = _todayKey();
    if (_lastDailyDate == today) return;
    _lastDailyDate = today;
    _dailyStepsCompleted.clear();

    Future<void> step(String name, Future<void> Function() f) async {
      if (_dailyStepsCompleted.contains(name)) return;
      try {
        await f();
        _dailyStepsCompleted.add(name);
      } catch (_) {}
    }

    await step('compileToday', () => compiler.compileToday(daily: true));
    await step('compileWeek', () => compiler.compileWeek());
    await step('compileLongterm', () => compiler.compileLongterm());
    await step('compileFacts', () => compiler.compileFacts());
    await step('assemble', compiler.assemble);
    await step('deepMemory', () => deepMemory.processDirty());
  }

  String _todayKey() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, "0")}-${n.day.toString().padLeft(2, "0")}';
  }
}
