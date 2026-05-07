import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../llm/provider.dart';
import '../llm/utility.dart';

/// 与 legacy lib/memory/session-summary.js 对齐：滚动摘要管理。
///
/// 文件位置：`{agentMemory}/summaries/{sessionId}.json`
/// 内容字段：session_id / created_at / updated_at / summary / snapshot / snapshot_at
///
/// 摘要格式（两节）：
///   ## 重要事实
///   ## 事情经过
class SessionSummaryStore {
  SessionSummaryStore(this.summariesDir);

  final Directory summariesDir;

  static const _assistantCap = 300; // 助手消息只保留前 300 字
  static const _summaryCapTotal = 400; // 总预算 ≤400 字
  static const _summaryFloor = 40; // 至少 40 字

  Directory get _dir {
    if (!summariesDir.existsSync()) {
      summariesDir.createSync(recursive: true);
    }
    return summariesDir;
  }

  File _file(String sessionId) => File(p.join(_dir.path, '$sessionId.json'));

  SessionSummary? load(String sessionId) {
    final f = _file(sessionId);
    if (!f.existsSync()) return null;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return SessionSummary.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  void save(SessionSummary s) {
    final f = _file(s.sessionId);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(s.toJson())}\n',
      flush: true,
    );
    if (f.existsSync()) f.deleteSync();
    tmp.renameSync(f.path);
  }

  /// 列出所有"脏"摘要（summary != snapshot），供 deep-memory 处理。
  List<SessionSummary> getDirty() {
    if (!_dir.existsSync()) return const [];
    final out = <SessionSummary>[];
    for (final f in _dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final s = SessionSummary.fromJson(j);
        if (s.summary.isNotEmpty && s.summary != s.snapshot) {
          out.add(s);
        }
      } catch (_) {}
    }
    return out;
  }

  void markProcessed(String sessionId) {
    final s = load(sessionId);
    if (s == null) return;
    save(
      s.copyWith(
        snapshot: s.summary,
        snapshotAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  /// 滚动摘要：把 session 历史 messages 滚成一段两节摘要。
  /// 调用 LLM（summarizer model）。
  Future<SessionSummary> rollUp({
    required String sessionId,
    required List<Message> messages,
    required LlmProvider summarizer,
    required String model,
  }) async {
    if (messages.isEmpty) {
      final empty = SessionSummary(
        sessionId: sessionId,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        summary: '',
        snapshot: '',
      );
      save(empty);
      return empty;
    }

    final turnCount = messages.where((m) => m.role == 'user').length;
    final totalBudget = turnCount * 40 < _summaryCapTotal
        ? turnCount * 40
        : _summaryCapTotal;
    final adjusted = totalBudget < _summaryFloor ? _summaryFloor : totalBudget;
    final factsBudget = (adjusted * 0.3).round() < 15
        ? 15
        : (adjusted * 0.3).round();
    final eventsBudget = adjusted - factsBudget;

    final convoText = StringBuffer();
    for (final m in messages) {
      var content = m.content;
      if (m.role == 'assistant' && content.length > _assistantCap) {
        content = '${content.substring(0, _assistantCap)}…（长回复已截断）';
      }
      convoText.writeln('[${m.role}] $content');
    }

    final systemPrompt =
        '''
你是会话摘要助手。请按以下两节格式输出，每节单独标题：
## 重要事实
（用户侧稳定信息：偏好、决定、习惯、身份特征。$factsBudget字以内。）
## 事情经过
（按时间顺序，带 HH:MM 标注，抓重点脉络。$eventsBudget字以内。）

总字数严格控制在 $adjusted 字以内。
不输出其他内容。''';

    var summary = '';
    try {
      summary = await callProviderText(
        provider: summarizer,
        model: model,
        userContent: convoText.toString(),
        systemPrompt: systemPrompt,
        temperature: 0.3,
        maxTokens: adjusted,
      );
    } catch (e) {
      summary = '## 重要事实\n（摘要生成失败：$e）\n\n## 事情经过\n（同上）';
    }

    summary = _scrubPii(summary);

    final existing = load(sessionId);
    final now = DateTime.now().toUtc().toIso8601String();
    final next = SessionSummary(
      sessionId: sessionId,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      summary: summary,
      snapshot: existing?.snapshot ?? '',
      snapshotAt: existing?.snapshotAt,
    );
    save(next);
    return next;
  }

  static String _scrubPii(String s) {
    var out = s;
    out = out.replaceAll(
      RegExp(r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b'),
      '[REDACTED:CARD]',
    );
    out = out.replaceAll(RegExp(r'\b\d{17}[\dXx]\b'), '[REDACTED:ID]');
    out = out.replaceAll(RegExp(r'\b1[3-9]\d{9}\b'), '[REDACTED:PHONE]');
    out = out.replaceAll(
      RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b'),
      '[REDACTED:EMAIL]',
    );
    return out;
  }
}

class SessionSummary {
  final String sessionId;
  final String createdAt;
  final String updatedAt;
  final String summary;
  final String snapshot;
  final String? snapshotAt;
  const SessionSummary({
    required this.sessionId,
    required this.createdAt,
    required this.updatedAt,
    required this.summary,
    required this.snapshot,
    this.snapshotAt,
  });

  bool get isDirty => summary.isNotEmpty && summary != snapshot;

  SessionSummary copyWith({
    String? summary,
    String? snapshot,
    String? snapshotAt,
    String? updatedAt,
  }) => SessionSummary(
    sessionId: sessionId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    summary: summary ?? this.summary,
    snapshot: snapshot ?? this.snapshot,
    snapshotAt: snapshotAt ?? this.snapshotAt,
  );

  Map<String, dynamic> toJson() => {
    'session_id': sessionId,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'summary': summary,
    'snapshot': snapshot,
    if (snapshotAt != null) 'snapshot_at': snapshotAt,
  };

  static SessionSummary fromJson(Map<String, dynamic> j) => SessionSummary(
    sessionId: j['session_id'] as String,
    createdAt: j['created_at'] as String,
    updatedAt: j['updated_at'] as String,
    summary: j['summary'] as String? ?? '',
    snapshot: j['snapshot'] as String? ?? '',
    snapshotAt: j['snapshot_at'] as String?,
  );
}
