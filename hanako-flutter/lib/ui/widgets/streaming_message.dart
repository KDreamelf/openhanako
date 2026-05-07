import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/runtime_session_store.dart';

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
        return _ToolCallChip(name: name, args: argsJson);
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
