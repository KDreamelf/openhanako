// lib/ui/memory/memory_page.dart
//
// Memory 浏览器：展示当前 agent 的文件式记忆系统（.md 文件 + MEMORY.md 索引 +
// pinned.md 置顶记忆）。
//
// 数据源：agent/memory/ 目录下的 .md 文件，通过 claude_memory.dart 扫描解析。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../memory/claude_memory.dart';
import '../design/design.dart';

class MemoryPage extends ConsumerStatefulWidget {
  const MemoryPage({super.key});

  @override
  ConsumerState<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends ConsumerState<MemoryPage> {
  List<ClaudeMemoryHeader> _memories = const [];
  String _entrypointContent = '';
  String _pinnedContent = '';
  String _teamEntrypointContent = '';
  String _query = '';
  List<ClaudeMemorySearchResult> _searchResults = const [];
  bool _busy = false;
  String? _error;
  String? _agentId;
  Directory? _memoryRoot;
  String? _expandedFile;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _searchController.dispose();
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
      final memRoot = getClaudeMemoryRoot(eng.home.agentDir(agentId));
      await ensureMemoryDirExists(memRoot);
      if (!mounted) return;
      setState(() {
        _agentId = agentId;
        _memoryRoot = memRoot;
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '打开记忆目录失败：$e');
    }
  }

  Future<void> _refresh() async {
    if (_memoryRoot == null) return;
    setState(() => _busy = true);
    try {
      final headers = await scanMemoryFiles(_memoryRoot!);

      final entryFile = getClaudeMemoryEntrypoint(_memoryRoot!);
      final entryContent =
          entryFile.existsSync() ? await entryFile.readAsString() : '';

      final eng = ref.read(engineProvider);
      final pinnedFile =
          File(p.join(eng.home.agentDir(_agentId!).path, 'pinned.md'));
      final pinned =
          pinnedFile.existsSync() ? await pinnedFile.readAsString() : '';

      final teamMemRoot = Directory(p.join(_memoryRoot!.path, 'team'));
      final teamEntryFile = getClaudeMemoryEntrypoint(teamMemRoot);
      final teamContent =
          teamEntryFile.existsSync() ? await teamEntryFile.readAsString() : '';

      if (!mounted) return;
      setState(() {
        _memories = headers;
        _entrypointContent = entryContent.trim();
        _pinnedContent = pinned.trim();
        _teamEntrypointContent = teamContent.trim();
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读取记忆失败：$e';
        _busy = false;
      });
    }
  }

  Future<void> _search(String query) async {
    _query = query;
    if (query.trim().isEmpty) {
      setState(() => _searchResults = const []);
      return;
    }
    if (_memoryRoot == null) return;
    try {
      final results = await searchMemoryFiles(_memoryRoot!, query);
      if (!mounted) return;
      setState(() => _searchResults = results);
    } catch (_) {}
  }

  Future<void> _deleteMemory(ClaudeMemoryHeader header) async {
    final palette = context.palette;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记忆'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(header.filename,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (header.description != null && header.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(header.description!,
                    style: TextStyle(color: palette.textSecondary)),
              ),
            const SizedBox(height: 12),
            const Text('删除后不可恢复。'),
          ],
        ),
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

    try {
      final file = File(header.filePath);
      if (file.existsSync()) await file.delete();
      _removeFromIndex(header.filename);
      await _refresh();
      _showSnack('已删除 ${header.filename}');
    } catch (e) {
      _showSnack('删除失败：$e');
    }
  }

  void _removeFromIndex(String filename) {
    if (_memoryRoot == null) return;
    final entryFile = getClaudeMemoryEntrypoint(_memoryRoot!);
    if (!entryFile.existsSync()) return;
    try {
      final lines = entryFile.readAsLinesSync();
      final filtered =
          lines.where((l) => !l.contains('($filename)')).toList();
      entryFile.writeAsStringSync('${filtered.join('\n')}\n');
    } catch (_) {}
  }

  Future<String?> _readFileContent(String filePath) async {
    try {
      return await File(filePath).readAsString();
    } catch (_) {
      return null;
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final isSearching = _query.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: Column(
          children: [
            _MemoryHeader(
              agentId: _agentId,
              memoryCount: _memories.length,
              busy: _busy,
              onRefresh: _busy ? null : _refresh,
              onClose: () => Navigator.of(context).pop(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(DS.s16),
                child: HanaBanner(
                  icon: Icons.error_outline,
                  title: '记忆系统错误',
                  subtitle: _error!,
                  color: palette.accentCrimson,
                ),
              )
            else if (_memoryRoot == null)
              const Expanded(
                  child: Center(child: CircularProgressIndicator()))
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    DS.s20, DS.s12, DS.s20, DS.s10),
                child: _SearchField(
                    controller: _searchController, onChanged: _search),
              ),
              if (_busy)
                LinearProgressIndicator(
                  minHeight: 2,
                  color: palette.accentEmerald,
                  backgroundColor: Colors.transparent,
                ),
              Expanded(
                child: isSearching
                    ? _buildSearchResults(palette)
                    : _buildMemoryList(palette),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults(HanaPalette palette) {
    if (_searchResults.isEmpty) {
      return Center(
        child: Text('没有匹配的记忆',
            style: TextStyle(color: palette.textSecondary)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(DS.s20, DS.s4, DS.s20, DS.s20),
      itemCount: _searchResults.length,
      itemBuilder: (ctx, i) {
        final r = _searchResults[i];
        return _SearchResultCard(
          result: r,
          onTap: () {
            _searchController.clear();
            setState(() {
              _query = '';
              _searchResults = const [];
              _expandedFile = r.filePath;
            });
          },
        );
      },
    );
  }

  Widget _buildMemoryList(HanaPalette palette) {
    final hasPinned = _pinnedContent.isNotEmpty;
    final hasEntry = _entrypointContent.isNotEmpty;
    final hasTeam = _teamEntrypointContent.isNotEmpty;
    final hasMemories = _memories.isNotEmpty;

    if (!hasPinned && !hasEntry && !hasTeam && !hasMemories) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_alt_outlined,
                size: 36, color: palette.textTertiary),
            const SizedBox(height: DS.s10),
            Text('还没有记忆',
                style: TextStyle(
                    color: palette.textSecondary, fontSize: DS.t13)),
            const SizedBox(height: 4),
            Text('与子体对话时会自动积累记忆',
                style: TextStyle(
                    color: palette.textTertiary, fontSize: DS.t11)),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(DS.s20, DS.s4, DS.s20, DS.s20),
      children: [
        if (hasPinned) ...[
          _SectionTitle(
              icon: Icons.push_pin_outlined,
              label: '置顶记忆',
              color: palette.accentAmber),
          const SizedBox(height: DS.s8),
          _PinnedCard(content: _pinnedContent),
          const SizedBox(height: DS.s16),
        ],
        if (hasEntry) ...[
          _SectionTitle(
              icon: Icons.list_alt_rounded,
              label: 'MEMORY.md 索引',
              color: palette.accentCyan),
          const SizedBox(height: DS.s8),
          _IndexCard(content: _entrypointContent),
          const SizedBox(height: DS.s16),
        ],
        if (hasTeam) ...[
          _SectionTitle(
              icon: Icons.groups_outlined,
              label: 'team/MEMORY.md 团队记忆',
              color: palette.accentEmerald),
          const SizedBox(height: DS.s8),
          _IndexCard(content: _teamEntrypointContent),
          const SizedBox(height: DS.s16),
        ],
        if (hasMemories) ...[
          _SectionTitle(
              icon: Icons.psychology_outlined,
              label: '记忆文件 (${_memories.length})',
              color: palette.accentLavender),
          const SizedBox(height: DS.s8),
          for (final m in _memories)
            _MemoryFileCard(
              header: m,
              expanded: _expandedFile == m.filePath,
              onTap: () => setState(() => _expandedFile =
                  _expandedFile == m.filePath ? null : m.filePath),
              onDelete: () => _deleteMemory(m),
              onCopy: () async {
                final content = await _readFileContent(m.filePath);
                if (content != null) {
                  Clipboard.setData(ClipboardData(text: content));
                  _showSnack('内容已复制');
                }
              },
              readContent: _readFileContent,
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _MemoryHeader extends StatelessWidget {
  const _MemoryHeader({
    required this.agentId,
    required this.memoryCount,
    required this.busy,
    required this.onRefresh,
    required this.onClose,
  });

  final String? agentId;
  final int memoryCount;
  final bool busy;
  final VoidCallback? onRefresh;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      decoration: BoxDecoration(
        color:
            palette.bgRaised.withValues(alpha: palette.isDark ? 0.70 : 0.86),
        border: Border(
            bottom: BorderSide(color: palette.divider, width: DS.hairline)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: DS.s16, vertical: DS.s12),
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
                          color:
                              palette.accentLavender.withValues(alpha: 0.42)),
                    ),
                    child: Icon(Icons.psychology_outlined,
                        size: 18, color: palette.accentLavender),
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
                            '记忆系统',
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: DS.t18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                              height: 1.15,
                            ),
                          ),
                          if (memoryCount > 0) ...[
                            const SizedBox(width: DS.s10),
                            HanaPill(
                              label: '$memoryCount 条记忆',
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
                            : 'Agent · $agentId · 文件式记忆',
                        style: TextStyle(
                            color: palette.textSecondary, fontSize: DS.t12),
                      ),
                    ],
                  ),
                ],
              ),
              GlassIconButton(
                icon: Icons.refresh_rounded,
                tooltip: '刷新',
                onPressed: onRefresh,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

class _SearchField extends StatefulWidget {
  const _SearchField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
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
            color: palette.bgDeep
                .withValues(alpha: palette.isDark ? 0.5 : 0.4),
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
                      color:
                          palette.accentLavender.withValues(alpha: 0.10),
                      blurRadius: 14,
                    ),
                  ]
                : null,
          ),
          child: TextField(
            controller: widget.controller,
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.search_rounded,
                  size: 18, color: palette.textTertiary),
              hintText: '搜索记忆内容…',
              hintStyle: TextStyle(color: palette.textTertiary),
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 0, vertical: DS.s12),
            ),
            cursorColor: palette.accentLavender,
            onChanged: widget.onChanged,
            style:
                TextStyle(color: palette.textPrimary, fontSize: DS.t14),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section title
// ---------------------------------------------------------------------------

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(
      {required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: DS.t12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            )),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Index card (MEMORY.md)
// ---------------------------------------------------------------------------

class _IndexCard extends StatelessWidget {
  const _IndexCard({required this.content});
  final String content;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(DS.s14),
      decoration: BoxDecoration(
        color: palette.glassFill,
        borderRadius: BorderRadius.circular(DS.r10),
        border: Border.all(color: palette.divider),
      ),
      child: SelectableText(
        content,
        style: TextStyle(
          color: palette.textPrimary,
          fontSize: DS.t12,
          height: 1.6,
          fontFamilyFallback: DS.monoFallback,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pinned card
// ---------------------------------------------------------------------------

class _PinnedCard extends StatelessWidget {
  const _PinnedCard({required this.content});
  final String content;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(DS.s14),
      decoration: BoxDecoration(
        color: palette.accentAmber.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(DS.r10),
        border:
            Border.all(color: palette.accentAmber.withValues(alpha: 0.25)),
      ),
      child: SelectableText(
        content,
        style: TextStyle(
          color: palette.textPrimary,
          fontSize: DS.t13,
          height: 1.55,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

Color _memoryTypeColor(HanaPalette palette, String? type) {
  return switch (type) {
    'user' => palette.accentCyan,
    'feedback' => palette.accentEmerald,
    'project' => palette.accentAmber,
    'reference' => palette.accentLavender,
    _ => palette.textTertiary,
  };
}

// ---------------------------------------------------------------------------
// Memory file card
// ---------------------------------------------------------------------------

class _MemoryFileCard extends StatefulWidget {
  const _MemoryFileCard({
    required this.header,
    required this.expanded,
    required this.onTap,
    required this.onDelete,
    required this.onCopy,
    required this.readContent,
  });

  final ClaudeMemoryHeader header;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onCopy;
  final Future<String?> Function(String path) readContent;

  @override
  State<_MemoryFileCard> createState() => _MemoryFileCardState();
}

class _MemoryFileCardState extends State<_MemoryFileCard> {
  bool _hover = false;
  String? _content;
  bool _loadingContent = false;

  @override
  void didUpdateWidget(covariant _MemoryFileCard old) {
    super.didUpdateWidget(old);
    if (widget.expanded && !old.expanded && _content == null) {
      _loadContent();
    }
  }

  Future<void> _loadContent() async {
    setState(() => _loadingContent = true);
    final content = await widget.readContent(widget.header.filePath);
    if (!mounted) return;
    setState(() {
      _content = content;
      _loadingContent = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final h = widget.header;
    final age = memoryAgeLabel(h.mtimeMs);
    final typeColor = _memoryTypeColor(palette, h.type);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DS.dFast,
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: _hover ? palette.glassFillStrong : palette.glassFill,
          borderRadius: BorderRadius.circular(DS.r10),
          border: Border.all(
            color: widget.expanded
                ? typeColor.withValues(alpha: 0.45)
                : _hover
                    ? palette.accentLavender.withValues(alpha: 0.36)
                    : palette.divider,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () {
                if (!widget.expanded && _content == null) _loadContent();
                widget.onTap();
              },
              borderRadius: BorderRadius.circular(DS.r10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    DS.s14, DS.s12, DS.s10, DS.s12),
                child: Row(
                  children: [
                    Container(
                      width: 3,
                      constraints: const BoxConstraints(minHeight: 28),
                      decoration: BoxDecoration(
                        color: typeColor.withValues(
                            alpha: _hover ? 0.85 : 0.45),
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
                              if (h.type != null && h.type!.isNotEmpty) ...[
                                HanaPill(
                                  label: h.type!,
                                  color: typeColor,
                                  dense: true,
                                ),
                                const SizedBox(width: DS.s8),
                              ],
                              Flexible(
                                child: Text(
                                  h.filename,
                                  style: TextStyle(
                                    color: palette.textPrimary,
                                    fontSize: DS.t13,
                                    fontWeight: FontWeight.w600,
                                    fontFamilyFallback: DS.monoFallback,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: DS.s8),
                              Text(age,
                                  style: TextStyle(
                                      color: palette.textTertiary,
                                      fontSize: DS.t11)),
                            ],
                          ),
                          if (h.description != null &&
                              h.description!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                h.description!,
                                style: TextStyle(
                                    color: palette.textSecondary,
                                    fontSize: DS.t12),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                    AnimatedOpacity(
                      opacity: _hover ? 1 : 0.55,
                      duration: DS.dFast,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon:
                                const Icon(Icons.copy_rounded, size: 15),
                            tooltip: '复制内容',
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints.tightFor(
                                width: 28, height: 28),
                            padding: EdgeInsets.zero,
                            color: palette.textSecondary,
                            onPressed: widget.onCopy,
                          ),
                          IconButton(
                            icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 15),
                            tooltip: '删除',
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints.tightFor(
                                width: 28, height: 28),
                            padding: EdgeInsets.zero,
                            color: palette.accentCrimson,
                            onPressed: widget.onDelete,
                          ),
                          Icon(
                            widget.expanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: 18,
                            color: palette.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.expanded)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(
                    DS.s20, 0, DS.s14, DS.s14),
                child: _loadingContent
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: DS.s10),
                        child: Center(
                            child:
                                SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))),
                      )
                    : Container(
                        padding: const EdgeInsets.all(DS.s12),
                        decoration: BoxDecoration(
                          color: palette.bgDeep.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(DS.r8),
                          border: Border.all(
                              color:
                                  palette.divider.withValues(alpha: 0.5)),
                        ),
                        child: SelectableText(
                          _content ?? '(无法读取)',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t12,
                            height: 1.6,
                            fontFamilyFallback: DS.monoFallback,
                          ),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }

}

// ---------------------------------------------------------------------------
// Search result card
// ---------------------------------------------------------------------------

class _SearchResultCard extends StatefulWidget {
  const _SearchResultCard({required this.result, required this.onTap});
  final ClaudeMemorySearchResult result;
  final VoidCallback onTap;

  @override
  State<_SearchResultCard> createState() => _SearchResultCardState();
}

class _SearchResultCardState extends State<_SearchResultCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final r = widget.result;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DS.dFast,
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: _hover ? palette.glassFillStrong : palette.glassFill,
          borderRadius: BorderRadius.circular(DS.r10),
          border: Border.all(
            color: _hover
                ? palette.accentLavender.withValues(alpha: 0.36)
                : palette.divider,
          ),
        ),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(DS.r10),
          child: Padding(
            padding: const EdgeInsets.all(DS.s14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (r.type != null && r.type!.isNotEmpty) ...[
                      HanaPill(
                        label: r.type!,
                        color: _memoryTypeColor(palette, r.type),
                        dense: true,
                      ),
                      const SizedBox(width: DS.s8),
                    ],
                    Flexible(
                      child: Text(
                        r.filename,
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: DS.t13,
                          fontWeight: FontWeight.w600,
                          fontFamilyFallback: DS.monoFallback,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: DS.s8),
                    Text('L${r.line}',
                        style: TextStyle(
                            color: palette.textTertiary,
                            fontSize: DS.t11,
                            fontFamilyFallback: DS.monoFallback)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  r.snippet,
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: DS.t12,
                    height: 1.5,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
