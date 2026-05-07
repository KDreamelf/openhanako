import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

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
      case RuntimeDisplayToolCallBlock():
        return _ToolCallCard(block: block as RuntimeDisplayToolCallBlock);
    }
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

class _ToolCallCard extends StatelessWidget {
  const _ToolCallCard({required this.block});

  final RuntimeDisplayToolCallBlock block;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final status = _toolStatus(block);
    return InkWell(
      onTap: () => _showToolDetails(context, block),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: _toolCardDecoration(context),
        child: Row(
          children: [
            Icon(Icons.build, size: 16, color: c.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(block.name, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _toolSummary(block),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: c.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 8),
            _ToolStatusPill(status: status),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: c.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  void _showToolDetails(
    BuildContext context,
    RuntimeDisplayToolCallBlock block,
  ) {
    final auditText = _toolAuditText(block);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('工具调用：${block.name}'),
        content: SizedBox(
          width: 760,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 620),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailSection(
                    title: '参数',
                    content: _prettyJson(block.argsJson),
                  ),
                  const SizedBox(height: 14),
                  _DetailSection(
                    title: block.resultIsError ? '结果（失败）' : '结果',
                    content: block.resultContent?.trim().isNotEmpty == true
                        ? _prettyJson(block.resultContent!)
                        : '尚未收到执行结果',
                  ),
                  if (block.resultDetails != null) ...[
                    const SizedBox(height: 14),
                    _DetailSection(
                      title: '详情',
                      content: const JsonEncoder.withIndent(
                        '  ',
                      ).convert(block.resultDetails),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: auditText));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('工具详情已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制全部'),
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

class _ToolStatusPill extends StatelessWidget {
  const _ToolStatusPill({required this.status});

  final _ToolStatus status;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final (label, color) = switch (status) {
      _ToolStatus.running => ('执行中', c.tertiary),
      _ToolStatus.success => ('完成', c.primary),
      _ToolStatus.failed => ('失败', c.error),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withAlpha(96)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.content});

  final String title;
  final String content;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.outlineVariant),
          ),
          child: SelectableText(
            content,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}

enum _ToolStatus { running, success, failed }

_ToolStatus _toolStatus(RuntimeDisplayToolCallBlock block) {
  final content = block.resultContent;
  if (content == null) return _ToolStatus.running;
  if (block.resultIsError) return _ToolStatus.failed;
  final decoded = _decodeArgs(content);
  if (decoded != null && decoded['ok'] == false) return _ToolStatus.failed;
  return _ToolStatus.success;
}

String _toolSummary(RuntimeDisplayToolCallBlock block) {
  final args = _decodeArgs(block.argsJson);
  if (args == null || args.isEmpty) return '无参数';
  if (block.name == LocalToolNames.bash) {
    return _oneLine(args['command']?.toString() ?? block.argsJson);
  }
  const preferredKeys = [
    'path',
    'file_path',
    'filePath',
    'url',
    'query',
    'pattern',
    'action',
    'id',
    'title',
    'name',
  ];
  for (final key in preferredKeys) {
    final value = args[key];
    if (value == null) continue;
    return '$key=${_oneLine(value.toString())}';
  }
  final first = args.entries.first;
  return '${first.key}=${_oneLine(first.value.toString())}';
}

String _toolAuditText(RuntimeDisplayToolCallBlock block) {
  final parts = <String>[
    '工具：${block.name}',
    '调用 ID：${block.id}',
    '状态：${switch (_toolStatus(block)) {
      _ToolStatus.running => '执行中',
      _ToolStatus.success => '完成',
      _ToolStatus.failed => '失败',
    }}',
    '参数：',
    _prettyJson(block.argsJson),
    '结果：',
    block.resultContent?.trim().isNotEmpty == true
        ? _prettyJson(block.resultContent!)
        : '尚未收到执行结果',
  ];
  if (block.resultDetails != null) {
    parts
      ..add('详情：')
      ..add(const JsonEncoder.withIndent('  ').convert(block.resultDetails));
  }
  return parts.join('\n');
}

String _prettyJson(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  try {
    final decoded = jsonDecode(text);
    return const JsonEncoder.withIndent('  ').convert(decoded);
  } catch (_) {
    return text;
  }
}

String _oneLine(String value) {
  final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  const max = 180;
  if (text.length <= max) return text;
  return '${text.substring(0, max)}...';
}
