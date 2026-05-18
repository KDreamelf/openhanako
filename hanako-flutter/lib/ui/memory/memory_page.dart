// lib/ui/memory/memory_page.dart
//
// Memory 浏览器：列出当前 agent 的事实库，支持搜索 / 查看 / 编辑 / 删除 /
// 导出。
//
// 数据源：[engine.home.agentFactsDb(agentId)] → [HanaDatabase] → [FactStore]
// 当前 agent 的 facts.db 由 MemoryPage 内部打开，离开页面时关闭。

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../core/engine.dart';
import '../../llm/provider.dart';
import '../../memory/database.dart';
import '../../memory/fact_store.dart';
import '../../memory/memory_compile.dart';
import '../../memory/session_summary.dart';
import '../design/design.dart';

class MemoryPage extends ConsumerStatefulWidget {
  const MemoryPage({super.key});

  @override
  ConsumerState<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends ConsumerState<MemoryPage> {
  HanaDatabase? _db;
  FactStore? _store;
  List<FactView> _facts = const [];
  String _query = '';
  bool _busy = false;
  String? _error;
  String? _agentId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }

  Future<void> _open() async {
    final eng = ref.read(engineProvider);
    final agentId = eng.agentManager.activeAgentId;
    if (agentId == null) {
      if (!mounted) return;
      setState(() => _error = '没有活动的 agent。请先创建一个。');
      return;
    }
    try {
      final dbFile = eng.home.agentFactsDb(agentId);
      final db = openHanaDatabaseAt(dbFile);
      final store = FactStore(db);
      if (!mounted) return;
      setState(() {
        _agentId = agentId;
        _db = db;
        _store = store;
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '打开 facts.db 失败：$e');
    }
  }

  Future<void> _refresh() async {
    if (_store == null) return;
    setState(() => _busy = true);
    try {
      List<FactView> rows;
      if (_query.trim().isEmpty) {
        rows = await _store!.getAll();
      } else {
        rows = await _store!.searchFullText(_query.trim(), limit: 200);
      }
      if (!mounted) return;
      setState(() {
        _facts = rows;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '查询失败：$e';
        _busy = false;
      });
    }
  }

  Future<void> _delete(FactView fact) async {
    final palette = context.palette;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除事实'),
        content: Text(fact.fact, maxLines: 5, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: palette.accentCrimson,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store!.delete(fact.id);
    await _refresh();
  }

  Future<void> _import() async {
    if (_store == null) return;
    final request = await _askImportRequest();
    if (request == null) return;

    final file = File(request.path);
    if (!file.existsSync()) {
      _showSnack('导入失败：文件不存在');
      return;
    }

    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final raw = await file.readAsString();
      final entries = _parseImportEntries(raw, request.tags);
      if (entries.isEmpty) {
        throw const FormatException('没有找到可导入的事实');
      }
      final before = await _store!.count();
      await _store!.importAll(entries);
      final after = await _store!.count();
      await _refresh();
      _showSnack('已导入 ${after - before} 条新事实');
    } catch (e) {
      _showSnack('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_MemoryImportRequest?> _askImportRequest() async {
    final pathController = TextEditingController();
    final tagsController = TextEditingController(text: 'imported');
    try {
      return await showDialog<_MemoryImportRequest>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入记忆'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: pathController,
                  decoration: const InputDecoration(
                    labelText: '文件路径',
                    hintText: r'C:\path\memory.md 或 facts.json',
                  ),
                ),
                const SizedBox(height: DS.s12),
                TextField(
                  controller: tagsController,
                  decoration: const InputDecoration(
                    labelText: '附加标签',
                    hintText: '多个标签用逗号分隔',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final path = pathController.text.trim();
                if (path.isEmpty) return;
                Navigator.pop(
                  ctx,
                  _MemoryImportRequest(
                    path: path,
                    tags: _splitTags(tagsController.text),
                  ),
                );
              },
              child: const Text('导入'),
            ),
          ],
        ),
      );
    } finally {
      pathController.dispose();
      tagsController.dispose();
    }
  }

  Future<void> _clearAll() async {
    if (_store == null) return;
    final palette = context.palette;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空事实库'),
        content: const Text('此操作会删除当前 Agent 的全部事实记忆，不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: palette.accentCrimson,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      await _store!.clearAll();
      await _refresh();
      _showSnack('事实库已清空');
    } catch (e) {
      _showSnack('清空失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _compileMemory() async {
    final agentId = _agentId;
    if (agentId == null) return;

    final eng = ref.read(engineProvider);
    final memoryDir = eng.home.agentMemory(agentId);
    final summaries = SessionSummaryStore(
      Directory(p.join(memoryDir.path, 'summaries')),
    );
    final identity = eng.identityRepository.current;
    final model = eng.modelManager.currentModelId;
    final canCallLlm = identity != null && model != null && model.isNotEmpty;
    final compiler = MemoryCompiler(
      memoryDir: memoryDir,
      summaries: summaries,
      compilerProvider: canCallLlm
          ? _GatewayLlmProvider(eng)
          : const _UnavailableLlmProvider(),
      compilerModel: model ?? '',
    );

    setState(() => _busy = true);
    try {
      if (!canCallLlm) {
        await compiler.assemble();
        _showSnack('已重新组装 memory.md；完整编译需要先解锁身份并选择模型。');
        return;
      }

      await eng.backendClient.handshake(keyPair: identity.keyPair);
      final statuses = <String, CompileStatus>{
        'today': await compiler.compileToday(),
        'week': await compiler.compileWeek(),
        'longterm': await compiler.compileLongterm(),
        'facts': await compiler.compileFacts(),
      };
      await compiler.assemble();
      final text = statuses.entries
          .map((entry) => '${entry.key}=${entry.value.name}')
          .join(', ');
      _showSnack('记忆编译完成：$text');
    } catch (e) {
      _showSnack('编译失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    if (_facts.isEmpty) return;
    try {
      final dir = await getDownloadsDirectory();
      final outPath =
          '${dir?.path ?? Directory.systemTemp.path}/hanako-memory-$_agentId-${DateTime.now().millisecondsSinceEpoch}.md';
      final buf = StringBuffer()
        ..writeln('# Hanako Memory · agent=$_agentId')
        ..writeln('')
        ..writeln('导出时间：${DateTime.now().toIso8601String()}')
        ..writeln('共 ${_facts.length} 条事实')
        ..writeln('')
        ..writeln('---');
      for (final f in _facts) {
        buf
          ..writeln('')
          ..writeln('## #${f.id}')
          ..writeln('')
          ..writeln(f.fact)
          ..writeln('')
          ..writeln(
            '> tags: ${f.tags.isEmpty ? "(none)" : f.tags.join(", ")}  ·  '
            'time: ${f.time ?? "-"}  ·  createdAt: ${f.createdAt}',
          );
        if (f.sessionId != null) {
          buf.writeln('> session: ${f.sessionId}');
        }
      }
      await File(outPath).writeAsString(buf.toString());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出到 $outPath'),
          action: SnackBarAction(
            label: '复制路径',
            onPressed: () => Clipboard.setData(ClipboardData(text: outPath)),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  List<FactInput> _parseImportEntries(String raw, List<String> extraTags) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];

    final parsed = _tryParseJson(trimmed);
    if (parsed != null) {
      final entries = _entriesFromJson(parsed, extraTags);
      if (entries.isNotEmpty) return entries;
    }

    final entries = <FactInput>[];
    for (final rawLine in const LineSplitter().convert(raw)) {
      var line = rawLine.trim();
      if (line.isEmpty ||
          line.startsWith('#') ||
          line.startsWith('>') ||
          line == '---' ||
          line.startsWith('```') ||
          line.startsWith('导出时间：') ||
          line.startsWith('共 ')) {
        continue;
      }
      line = line.replaceFirst(RegExp(r'^[-*]\s+'), '');
      line = line.replaceFirst(RegExp(r'^\d+\.\s+'), '');
      if (line.length < 2) continue;
      entries.add(FactInput(fact: line, tags: extraTags));
    }
    return entries;
  }

  Object? _tryParseJson(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  List<FactInput> _entriesFromJson(Object parsed, List<String> extraTags) {
    final List rawEntries;
    if (parsed is List) {
      rawEntries = parsed;
    } else if (parsed is Map && parsed['facts'] is List) {
      rawEntries = parsed['facts'] as List;
    } else {
      rawEntries = const [];
    }
    final entries = <FactInput>[];
    for (final item in rawEntries) {
      if (item is String && item.trim().isNotEmpty) {
        entries.add(FactInput(fact: item.trim(), tags: extraTags));
        continue;
      }
      if (item is! Map) continue;
      final fact = (item['fact'] ?? item['content'] ?? item['text'])
          ?.toString()
          .trim();
      if (fact == null || fact.isEmpty) continue;
      final tags = <String>[..._tagsFromValue(item['tags']), ...extraTags];
      entries.add(
        FactInput(
          fact: fact,
          tags: tags,
          time: item['time']?.toString(),
          sessionId: (item['session_id'] ?? item['sessionId'])?.toString(),
        ),
      );
    }
    return entries;
  }

  List<String> _tagsFromValue(Object? raw) {
    if (raw is List) {
      return raw
          .whereType<String>()
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toList(growable: false);
    }
    if (raw is String) return _splitTags(raw);
    return const [];
  }

  static List<String> _splitTags(String raw) {
    final out = <String>[];
    final seen = <String>{};
    for (final part in raw.split(RegExp(r'[,，\s]+'))) {
      final tag = part.trim();
      if (tag.isEmpty || !seen.add(tag)) continue;
      out.add(tag);
    }
    return out;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: Column(
          children: [
            _MemoryHeader(
              agentId: _agentId,
              factCount: _facts.length,
              busy: _busy,
              hasFacts: _facts.isNotEmpty,
              onRefresh: _busy ? null : _refresh,
              onImport: _busy || _store == null ? null : _import,
              onCompile: _busy || _agentId == null ? null : _compileMemory,
              onExport: _facts.isEmpty || _busy ? null : _export,
              onClear: _facts.isEmpty || _busy ? null : _clearAll,
              onClose: () => Navigator.of(context).pop(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(DS.s16),
                child: HanaBanner(
                  icon: Icons.error_outline,
                  title: '记忆库错误',
                  subtitle: _error!,
                  color: palette.accentCrimson,
                ),
              )
            else if (_store == null)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  DS.s20,
                  DS.s12,
                  DS.s20,
                  DS.s10,
                ),
                child: _MemorySearchField(
                  onChanged: (v) {
                    _query = v;
                    _refresh();
                  },
                ),
              ),
              if (_busy)
                LinearProgressIndicator(
                  minHeight: 2,
                  color: palette.accentEmerald,
                  backgroundColor: Colors.transparent,
                ),
              Expanded(
                child: _facts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.psychology_alt_outlined,
                              size: 36,
                              color: palette.textTertiary,
                            ),
                            const SizedBox(height: DS.s10),
                            Text(
                              _query.isEmpty ? '还没有事实记录' : '搜索结果为空',
                              style: TextStyle(
                                color: palette.textSecondary,
                                fontSize: DS.t13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _query.isEmpty
                                  ? '与子体对话时会自动累积事实'
                                  : '试试更宽泛的关键词',
                              style: TextStyle(
                                color: palette.textTertiary,
                                fontSize: DS.t11,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          DS.s20,
                          DS.s4,
                          DS.s20,
                          DS.s20,
                        ),
                        itemCount: _facts.length,
                        itemBuilder: (ctx, i) {
                          final f = _facts[i];
                          return _FactCard(
                            fact: f,
                            onDelete: () => _delete(f),
                            onCopy: () {
                              Clipboard.setData(ClipboardData(text: f.fact));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('内容已复制'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MemoryHeader extends StatelessWidget {
  const _MemoryHeader({
    required this.agentId,
    required this.factCount,
    required this.busy,
    required this.hasFacts,
    required this.onRefresh,
    required this.onImport,
    required this.onCompile,
    required this.onExport,
    required this.onClear,
    required this.onClose,
  });

  final String? agentId;
  final int factCount;
  final bool busy;
  final bool hasFacts;
  final VoidCallback? onRefresh;
  final VoidCallback? onImport;
  final VoidCallback? onCompile;
  final VoidCallback? onExport;
  final VoidCallback? onClear;
  final VoidCallback onClose;

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
          padding: const EdgeInsets.symmetric(
            horizontal: DS.s16,
            vertical: DS.s12,
          ),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: DS.s8,
            spacing: DS.s8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: '返回',
                    onPressed: onClose,
                  ),
                  const SizedBox(width: DS.s12),
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          palette.accentLavender.withValues(alpha: 0.32),
                          palette.accentCyan.withValues(alpha: 0.20),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(DS.r8),
                      border: Border.all(
                        color: palette.accentLavender.withValues(alpha: 0.42),
                      ),
                    ),
                    child: Icon(
                      Icons.psychology_outlined,
                      size: 18,
                      color: palette.accentLavender,
                    ),
                  ),
                  const SizedBox(width: DS.s10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '记忆库',
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: DS.t18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                              height: 1.15,
                            ),
                          ),
                          if (factCount > 0) ...[
                            const SizedBox(width: DS.s10),
                            HanaPill(
                              label: '$factCount 条事实',
                              color: palette.accentLavender,
                              dense: true,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        agentId == null
                            ? '未关联 Agent'
                            : 'Agent · $agentId · FTS5 全文索引',
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: DS.t12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Wrap(
                spacing: DS.s4,
                runSpacing: DS.s4,
                children: [
                  GlassIconButton(
                    icon: Icons.refresh_rounded,
                    tooltip: '刷新',
                    onPressed: onRefresh,
                  ),
                  GlassIconButton(
                    icon: Icons.upload_file_outlined,
                    tooltip: '导入',
                    onPressed: onImport,
                  ),
                  GlassButton(
                    icon: Icons.auto_fix_high_outlined,
                    label: '编译记忆',
                    onPressed: onCompile,
                    dense: true,
                    accent: palette.accentCyan,
                  ),
                  GlassIconButton(
                    icon: Icons.download_outlined,
                    tooltip: '导出 Markdown',
                    onPressed: onExport,
                  ),
                  GlassIconButton(
                    icon: Icons.delete_sweep_outlined,
                    tooltip: '清空',
                    accent: palette.accentCrimson,
                    onPressed: onClear,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemorySearchField extends StatefulWidget {
  const _MemorySearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  State<_MemorySearchField> createState() => _MemorySearchFieldState();
}

class _MemorySearchFieldState extends State<_MemorySearchField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      child: FocusScope(
        onFocusChange: (v) => setState(() => _focused = v),
        child: AnimatedContainer(
          duration: DS.dQuick,
          decoration: BoxDecoration(
            color: palette.bgDeep.withValues(alpha: palette.isDark ? 0.5 : 0.4),
            borderRadius: BorderRadius.circular(DS.r10),
            border: Border.all(
              color: _focused
                  ? palette.accentLavender.withValues(alpha: 0.55)
                  : palette.divider,
              width: _focused ? 1.4 : DS.hairline,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: palette.accentLavender.withValues(alpha: 0.10),
                      blurRadius: 14,
                    ),
                  ]
                : null,
          ),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: palette.textTertiary,
              ),
              hintText: '搜索事实（FTS5 全文索引）…',
              hintStyle: TextStyle(color: palette.textTertiary),
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 0,
                vertical: DS.s12,
              ),
            ),
            cursorColor: palette.accentLavender,
            onChanged: widget.onChanged,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: DS.t14,
            ),
          ),
        ),
      ),
    );
  }
}

class _MemoryImportRequest {
  const _MemoryImportRequest({required this.path, required this.tags});

  final String path;
  final List<String> tags;
}

class _GatewayLlmProvider implements LlmProvider {
  const _GatewayLlmProvider(this.engine);

  final HanaEngine engine;

  @override
  String get name => 'hanako_gateway';

  @override
  Stream<LlmEvent> chat({
    required List<Message> messages,
    required String model,
    List<Tool>? tools,
    bool? thinking,
    CancelToken? cancelToken,
  }) {
    return engine.backendClient.chatEvents(
      model: model,
      messages: messages.map((message) => message.toJson()).toList(),
      tools: tools,
      cancelToken: cancelToken,
    );
  }
}

class _UnavailableLlmProvider implements LlmProvider {
  const _UnavailableLlmProvider();

  @override
  String get name => 'unavailable';

  @override
  Stream<LlmEvent> chat({
    required List<Message> messages,
    required String model,
    List<Tool>? tools,
    bool? thinking,
    CancelToken? cancelToken,
  }) async* {
    yield const LlmError(message: 'LLM 未配置');
  }
}

class _FactCard extends StatefulWidget {
  const _FactCard({
    required this.fact,
    required this.onDelete,
    required this.onCopy,
  });

  final FactView fact;
  final VoidCallback onDelete;
  final VoidCallback onCopy;

  @override
  State<_FactCard> createState() => _FactCardState();
}

class _FactCardState extends State<_FactCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DS.dFast,
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: _hover
              ? palette.glassFillStrong
              : palette.glassFill,
          borderRadius: BorderRadius.circular(DS.r10),
          border: Border.all(
            color: _hover
                ? palette.accentLavender.withValues(alpha: 0.36)
                : palette.divider,
          ),
        ),
        padding: const EdgeInsets.fromLTRB(DS.s14, DS.s12, DS.s10, DS.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 3,
              constraints: const BoxConstraints(minHeight: 28),
              decoration: BoxDecoration(
                color: palette.accentLavender.withValues(
                  alpha: _hover ? 0.85 : 0.45,
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: DS.s10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        '#${widget.fact.id}',
                        style: TextStyle(
                          color: palette.textTertiary,
                          fontSize: DS.t11,
                          fontFamilyFallback: DS.monoFallback,
                        ),
                      ),
                      const SizedBox(width: DS.s10),
                      Text(
                        widget.fact.createdAt.split('T').first,
                        style: TextStyle(
                          color: palette.textTertiary,
                          fontSize: DS.t11,
                        ),
                      ),
                      if (widget.fact.time != null) ...[
                        const SizedBox(width: DS.s10),
                        Icon(
                          Icons.access_time_rounded,
                          size: 11,
                          color: palette.textTertiary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          widget.fact.time!,
                          style: TextStyle(
                            color: palette.textTertiary,
                            fontSize: DS.t11,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    widget.fact.fact,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: DS.t13,
                      height: 1.55,
                    ),
                  ),
                  if (widget.fact.tags.isNotEmpty ||
                      widget.fact.sessionId != null) ...[
                    const SizedBox(height: DS.s8),
                    Wrap(
                      spacing: DS.s6,
                      runSpacing: 4,
                      children: [
                        for (final t in widget.fact.tags)
                          HanaPill(
                            icon: Icons.label_outline_rounded,
                            label: t,
                            color: palette.accentCyan,
                            dense: true,
                          ),
                        if (widget.fact.sessionId != null)
                          HanaPill(
                            icon: Icons.chat_bubble_outline_rounded,
                            label: widget.fact.sessionId!,
                            color: palette.accentEmerald,
                            dense: true,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: _hover ? 1 : 0.55,
              duration: DS.dFast,
              child: Column(
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    tooltip: '复制',
                    visualDensity: VisualDensity.compact,
                    constraints:
                        const BoxConstraints.tightFor(width: 28, height: 28),
                    padding: EdgeInsets.zero,
                    color: palette.textSecondary,
                    onPressed: widget.onCopy,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 15),
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                    constraints:
                        const BoxConstraints.tightFor(width: 28, height: 28),
                    padding: EdgeInsets.zero,
                    color: palette.accentCrimson,
                    onPressed: widget.onDelete,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
