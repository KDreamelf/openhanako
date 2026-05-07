import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/runtime_session_store.dart';
import '../../local_tools/local_tools.dart';

/// 流式消息渲染。
/// `RepaintBoundary` 隔离每条消息，避免新消息到达重绘整个列表（性能复盘文档 §8）。
class StreamingMessage extends StatelessWidget {
  final List<RuntimeDisplayBlock> blocks;
  final bool streaming;

  const StreamingMessage({
    super.key,
    this.blocks = const [],
    this.streaming = false,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MessageBlocksView(blocks: blocks),
            if (streaming)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class MessageBlocksView extends StatelessWidget {
  const MessageBlocksView({super.key, required this.blocks});

  final List<RuntimeDisplayBlock> blocks;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final block in blocks) _DisplayBlockView(block: block)],
    );
  }
}

class _DisplayBlockView extends StatelessWidget {
  const _DisplayBlockView({required this.block});

  final RuntimeDisplayBlock block;

  @override
  Widget build(BuildContext context) {
    switch (block) {
      case RuntimeDisplayTextBlock(:final text):
        if (text.trim().isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: MarkdownBody(
            data: text,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(
              Theme.of(context),
            ).copyWith(p: Theme.of(context).textTheme.bodyMedium),
          ),
        );
      case RuntimeDisplayThinkingBlock(:final text):
        if (text.trim().isEmpty) return const SizedBox.shrink();
        return _ThinkingBlock(text: text);
      case RuntimeDisplayToolCallBlock(:final name, :final argsJson):
        if (name == LocalToolNames.presentFiles) {
          return _PresentedFilesCard(argsJson: argsJson);
        }
        if (name == LocalToolNames.createArtifact) {
          return _ArtifactCard(argsJson: argsJson);
        }
        return _ToolCallChip(name: name, args: argsJson);
    }
  }
}

class _PresentedFilesCard extends StatelessWidget {
  const _PresentedFilesCard({required this.argsJson});

  final String argsJson;

  @override
  Widget build(BuildContext context) {
    final files = _presentedPaths(argsJson);
    if (files.isEmpty) {
      return const _ToolCallChip(name: LocalToolNames.presentFiles, args: '{}');
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: _toolCardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_open, size: 16),
              const SizedBox(width: 6),
              Text('文件', style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 8),
          for (final path in files) _PresentedFileRow(path: path),
        ],
      ),
    );
  }
}

class _PresentedFileRow extends StatelessWidget {
  const _PresentedFileRow({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    final exists = file.existsSync();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(
            exists ? Icons.insert_drive_file_outlined : Icons.error_outline,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              p.basename(path),
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            tooltip: '复制路径',
            visualDensity: VisualDensity.compact,
            onPressed: () => Clipboard.setData(ClipboardData(text: path)),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 16),
            tooltip: '打开文件',
            visualDensity: VisualDensity.compact,
            onPressed: exists ? () => launchUrl(Uri.file(path)) : null,
          ),
        ],
      ),
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({required this.argsJson});

  final String argsJson;

  @override
  Widget build(BuildContext context) {
    final data = _artifactArgs(argsJson);
    if (data == null) {
      return const _ToolCallChip(
        name: LocalToolNames.createArtifact,
        args: '{}',
      );
    }
    return InkWell(
      onTap: () => _showArtifact(context, data),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: _toolCardDecoration(context),
        child: Row(
          children: [
            Icon(_artifactIcon(data.type), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.title,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.language == null || data.language!.isEmpty
                        ? data.type
                        : '${data.type} · ${data.language}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }

  void _showArtifact(BuildContext context, _ArtifactArgs data) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(data.title),
        content: SizedBox(
          width: 720,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 560),
            child: SingleChildScrollView(child: _ArtifactBody(data: data)),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: data.content)),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制'),
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

class _ArtifactBody extends StatelessWidget {
  const _ArtifactBody({required this.data});

  final _ArtifactArgs data;

  @override
  Widget build(BuildContext context) {
    if (data.type == 'markdown') {
      return MarkdownBody(data: data.content, selectable: true);
    }
    return SelectableText(
      data.content,
      style: const TextStyle(fontFamily: 'monospace', height: 1.45),
    );
  }
}

class _ThinkingBlock extends StatelessWidget {
  final String text;
  const _ThinkingBlock({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: Theme.of(context).dividerColor, width: 2),
        ),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontStyle: FontStyle.italic,
          color: Theme.of(context).hintColor,
        ),
      ),
    );
  }
}

List<String> _presentedPaths(String argsJson) {
  final raw = _decodeArgs(argsJson);
  if (raw == null) return const [];
  final out = <String>[];
  final filepaths = raw['filepaths'];
  if (filepaths is List) {
    for (final item in filepaths) {
      final path = item.toString().trim();
      if (path.isNotEmpty) out.add(path);
    }
  }
  final single = raw['filePath'];
  if (single is String && single.trim().isNotEmpty) out.add(single.trim());
  return out;
}

_ArtifactArgs? _artifactArgs(String argsJson) {
  final raw = _decodeArgs(argsJson);
  if (raw == null) return null;
  final type = raw['type']?.toString().trim();
  final title = raw['title']?.toString().trim();
  final content = raw['content']?.toString();
  if (type == null ||
      type.isEmpty ||
      title == null ||
      title.isEmpty ||
      content == null) {
    return null;
  }
  return _ArtifactArgs(
    type: type,
    title: title,
    content: content,
    language: raw['language']?.toString(),
  );
}

Map<String, dynamic>? _decodeArgs(String argsJson) {
  try {
    final raw = jsonDecode(argsJson);
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return raw.cast<String, dynamic>();
  } catch (_) {}
  return null;
}

BoxDecoration _toolCardDecoration(BuildContext context) => BoxDecoration(
  color: Theme.of(context).colorScheme.surfaceContainerHighest,
  borderRadius: BorderRadius.circular(6),
  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
);

IconData _artifactIcon(String type) => switch (type) {
  'markdown' => Icons.article_outlined,
  'html' => Icons.web_asset_outlined,
  'code' => Icons.code,
  _ => Icons.widgets_outlined,
};

class _ArtifactArgs {
  const _ArtifactArgs({
    required this.type,
    required this.title,
    required this.content,
    this.language,
  });

  final String type;
  final String title;
  final String content;
  final String? language;
}

class _ToolCallChip extends StatelessWidget {
  const _ToolCallChip({required this.name, required this.args});

  final String name;
  final String args;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.build, size: 14),
              const SizedBox(width: 4),
              Text(name, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
          if (args.isNotEmpty && args.trim() != '{}')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                args,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}
