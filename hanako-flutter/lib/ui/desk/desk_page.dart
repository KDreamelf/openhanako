import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/desk_manager.dart';

class DeskPage extends ConsumerStatefulWidget {
  const DeskPage({super.key});

  @override
  ConsumerState<DeskPage> createState() => _DeskPageState();
}

class _DeskPageState extends ConsumerState<DeskPage> {
  List<DeskEntry> _entries = const [];
  DeskEntry? _selected;
  DeskPreview? _preview;
  bool _busy = false;
  String? _agentId;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final eng = ref.read(engineProvider);
    final agentId = eng.agentManager.activeAgentId;
    if (agentId == null) {
      if (!mounted) return;
      setState(() => _error = '没有活动的 Agent。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _agentId = agentId;
    });
    try {
      final entries = eng.deskManager.listFiles(agentId);
      DeskPreview? preview;
      DeskEntry? selected = _selected;
      if (selected != null &&
          entries.any(
            (entry) => entry.relativePath == selected!.relativePath,
          )) {
        preview = await eng.deskManager.preview(agentId, selected.relativePath);
      } else {
        selected = null;
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _selected = selected;
        _preview = preview;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '刷新书桌失败：$e';
        _busy = false;
      });
    }
  }

  Future<void> _select(DeskEntry entry) async {
    final agentId = _agentId;
    if (agentId == null) return;
    setState(() {
      _selected = entry;
      _preview = null;
      _busy = true;
    });
    try {
      final preview = await ref
          .read(engineProvider)
          .deskManager
          .preview(agentId, entry.relativePath);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '预览失败：$e';
        _busy = false;
      });
    }
  }

  Future<void> _openPath(String path) async {
    await launchUrl(Uri.file(path));
  }

  Future<void> _openContainingFolder(String path) async {
    await launchUrl(Uri.directory(p.dirname(path)));
  }

  @override
  Widget build(BuildContext context) {
    final agentId = _agentId;
    final deskPath = agentId == null
        ? null
        : ref.read(engineProvider).deskManager.deskDir(agentId).path;
    return Scaffold(
      appBar: AppBar(
        title: Text(agentId == null ? '书桌' : '书桌 · agent=$agentId'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _busy ? null : _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: '打开书桌目录',
            onPressed: deskPath == null ? null : () => _openPath(deskPath),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : Column(
              children: [
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final narrow = box.maxWidth < 760;
                      final list = _DeskFileList(
                        entries: _entries,
                        selected: _selected,
                        onSelect: _select,
                      );
                      final preview = _DeskPreviewPane(
                        preview: _preview,
                        selected: _selected,
                        onOpen: _preview == null
                            ? null
                            : () => _openPath(_preview!.path),
                        onOpenFolder: _preview == null
                            ? null
                            : () => _openContainingFolder(_preview!.path),
                      );
                      if (narrow) {
                        return Column(
                          children: [
                            SizedBox(height: 220, child: list),
                            const Divider(height: 1),
                            Expanded(child: preview),
                          ],
                        );
                      }
                      return Row(
                        children: [
                          SizedBox(width: 340, child: list),
                          const VerticalDivider(width: 1),
                          Expanded(child: preview),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _DeskFileList extends StatelessWidget {
  const _DeskFileList({
    required this.entries,
    required this.selected,
    required this.onSelect,
  });

  final List<DeskEntry> entries;
  final DeskEntry? selected;
  final ValueChanged<DeskEntry> onSelect;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(child: Text('书桌还没有文件'));
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ListTile(
          selected: selected?.relativePath == entry.relativePath,
          leading: Icon(_kindIcon(entry.kind), size: 20),
          title: Text(entry.name, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${entry.relativePath}\n${_formatSize(entry.size)} · ${entry.kind.label}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => onSelect(entry),
        );
      },
    );
  }
}

class _DeskPreviewPane extends StatelessWidget {
  const _DeskPreviewPane({
    required this.preview,
    required this.selected,
    required this.onOpen,
    required this.onOpenFolder,
  });

  final DeskPreview? preview;
  final DeskEntry? selected;
  final VoidCallback? onOpen;
  final VoidCallback? onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final item = preview;
    if (selected == null) return const Center(child: Text('选择文件查看预览'));
    if (item == null) return const Center(child: CircularProgressIndicator());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: Row(
              children: [
                Icon(_kindIcon(item.kind), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.relativePath,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: '复制路径',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: item.path)),
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  tooltip: '打开文件',
                  onPressed: onOpen,
                ),
                IconButton(
                  icon: const Icon(Icons.folder_open, size: 18),
                  tooltip: '打开位置',
                  onPressed: onOpenFolder,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _PreviewBody(preview: item)),
      ],
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({required this.preview});

  final DeskPreview preview;

  @override
  Widget build(BuildContext context) {
    switch (preview.kind) {
      case DeskFileKind.markdown:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: MarkdownBody(data: preview.text ?? '', selectable: true),
        );
      case DeskFileKind.text:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            preview.text ?? '',
            style: const TextStyle(fontFamily: 'monospace', height: 1.45),
          ),
        );
      case DeskFileKind.image:
        return InteractiveViewer(
          child: Center(child: Image.file(File(preview.path))),
        );
      case DeskFileKind.binary:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 44),
              const SizedBox(height: 12),
              Text('${preview.kind.label} · ${_formatSize(preview.size)}'),
            ],
          ),
        );
    }
  }
}

IconData _kindIcon(DeskFileKind kind) => switch (kind) {
  DeskFileKind.markdown => Icons.article_outlined,
  DeskFileKind.text => Icons.description_outlined,
  DeskFileKind.image => Icons.image_outlined,
  DeskFileKind.binary => Icons.insert_drive_file_outlined,
};

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
