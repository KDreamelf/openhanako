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
              backgroundColor: Theme.of(context).colorScheme.error,
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
                const SizedBox(height: 12),
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空事实库'),
        content: const Text('此操作会删除当前 Agent 的全部事实记忆。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
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
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _agentId == null
              ? 'Memory'
              : 'Memory · ${_facts.length} 条  ·  agent=$_agentId',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _busy ? null : _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: '导入',
            onPressed: _busy ? null : _import,
          ),
          IconButton(
            icon: const Icon(Icons.auto_fix_high),
            tooltip: '编译记忆',
            onPressed: _busy ? null : _compileMemory,
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: '导出 Markdown',
            onPressed: _facts.isEmpty || _busy ? null : _export,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空',
            onPressed: _facts.isEmpty || _busy ? null : _clearAll,
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : _store == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search, size: 20),
                      hintText: '搜索事实（FTS5）…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      _query = v;
                      _refresh();
                    },
                  ),
                ),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: _facts.isEmpty
                      ? const Center(
                          child: Text(
                            '还没有事实记录\n（与子体对话时自动累积）',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _facts.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (ctx, i) {
                            final f = _facts[i];
                            return _FactTile(
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

class _FactTile extends StatelessWidget {
  const _FactTile({
    required this.fact,
    required this.onDelete,
    required this.onCopy,
  });

  final FactView fact;
  final VoidCallback onDelete;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      title: Text(fact.fact, maxLines: 4, overflow: TextOverflow.ellipsis),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            if (fact.time != null)
              _Chip(icon: Icons.access_time, text: fact.time!),
            if (fact.sessionId != null)
              _Chip(icon: Icons.chat_bubble_outline, text: fact.sessionId!),
            for (final t in fact.tags)
              _Chip(icon: Icons.label_outline, text: t),
            _Chip(
              icon: Icons.calendar_today_outlined,
              text: fact.createdAt.split('T').first,
              dim: true,
            ),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: '复制内容',
            onPressed: onCopy,
          ),
          IconButton(
            icon: Icon(
              Icons.delete_outline,
              size: 18,
              color: theme.colorScheme.error,
            ),
            tooltip: '删除',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, this.dim = false});
  final IconData icon;
  final String text;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = dim
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}
