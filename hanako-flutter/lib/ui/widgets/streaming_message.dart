import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// 流式消息渲染。
/// `RepaintBoundary` 隔离每条消息，避免新消息到达重绘整个列表（性能复盘文档 §8）。
class StreamingMessage extends StatelessWidget {
  final String text;
  final String thinking;
  final List<ToolCallView> toolCalls;
  final bool streaming;

  const StreamingMessage({
    super.key,
    this.text = '',
    this.thinking = '',
    this.toolCalls = const [],
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
            if (thinking.isNotEmpty) _ThinkingBlock(text: thinking),
            if (text.isNotEmpty)
              MarkdownBody(
                data: text,
                selectable: true,
                styleSheet:
                    MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            for (final tc in toolCalls) _ToolCallChip(call: tc),
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

class ToolCallView {
  final String id;
  final String name;
  final String args;
  const ToolCallView({required this.id, required this.name, this.args = ''});
}

class _ToolCallChip extends StatelessWidget {
  final ToolCallView call;
  const _ToolCallChip({required this.call});

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
          Row(children: [
            const Icon(Icons.build, size: 14),
            const SizedBox(width: 4),
            Text(call.name, style: Theme.of(context).textTheme.labelSmall),
          ]),
          if (call.args.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                call.args,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
