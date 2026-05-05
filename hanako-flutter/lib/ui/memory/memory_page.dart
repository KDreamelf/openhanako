// lib/ui/memory/memory_page.dart
//
// Memory 浏览器：列出当前 agent 的事实库，支持搜索 / 查看 / 编辑 / 删除 /
// 导出。
//
// 数据源：[engine.home.agentFactsDb(agentId)] → [HanaDatabase] → [FactStore]
// 当前 agent 的 facts.db 由 MemoryPage 内部打开，离开页面时关闭。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../memory/database.dart';
import '../../memory/fact_store.dart';

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
        content: Text(
          fact.fact,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
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
              'time: ${f.time ?? "-"}  ·  createdAt: ${f.createdAt}');
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_agentId == null
            ? 'Memory'
            : 'Memory · ${_facts.length} 条  ·  agent=$_agentId'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _busy ? null : _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: '导出 Markdown',
            onPressed:
                _facts.isEmpty || _busy ? null : _export,
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
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (ctx, i) {
                                final f = _facts[i];
                                return _FactTile(
                                  fact: f,
                                  onDelete: () => _delete(f),
                                  onCopy: () {
                                    Clipboard.setData(
                                        ClipboardData(text: f.fact));
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(const SnackBar(
                                      content: Text('内容已复制'),
                                      duration: Duration(seconds: 1),
                                    ));
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
      title: Text(
        fact.fact,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
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
            for (final t in fact.tags) _Chip(icon: Icons.label_outline, text: t),
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
  const _Chip({
    required this.icon,
    required this.text,
    this.dim = false,
  });
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
