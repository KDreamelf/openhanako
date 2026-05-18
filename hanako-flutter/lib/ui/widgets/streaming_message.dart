import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/runtime_session_store.dart';
import '../design/design.dart';

/// 流式消息渲染（hanako 一侧）。
///
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
    final palette = context.palette;
    final accent = palette.accentEmerald;
    return RepaintBoundary(
      child: FadeSlideIn(
        duration: DS.dBase,
        offset: 6,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: DS.s10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusDot(color: accent, size: 4, pulse: streaming),
                      const SizedBox(width: DS.s6),
                      Text(
                        'HANAKO',
                      style: TextStyle(
                        color: accent,
                        fontSize: DS.t10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(width: DS.s8),
                    Text(
                      streaming ? '正在生成…' : '已就绪',
                      style: TextStyle(
                        color: palette.textTertiary,
                        fontSize: DS.t10,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
              ),
              GlassSurface(
                margin: const EdgeInsets.only(bottom: 2),
                padding: const EdgeInsets.symmetric(
                  horizontal: DS.s16,
                  vertical: DS.s12,
                ),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                accent: accent,
                radius: DS.r12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MessageBlocksView(blocks: blocks),
                    if (streaming)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TypingCaret(color: accent, height: 14),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
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
    // 把同一段 assistant 消息里**连续出现**的工具调用合并到一张多行卡里
    // （以 text/image/thinking 这些非工具块为界）。这跟同类 Codex 客户端的
    // 习惯一致：连续动作合一张卡，更接近"工具栈"的语义，也便于二阶截断
    // 优先保住"工具用途"的可读性。
    final children = <Widget>[];
    var toolGroup = <RuntimeDisplayToolCallBlock>[];

    void flushToolGroup() {
      if (toolGroup.isEmpty) return;
      children.add(_ToolCallStackCard(blocks: List.of(toolGroup)));
      toolGroup = <RuntimeDisplayToolCallBlock>[];
    }

    for (final block in blocks) {
      if (block is RuntimeDisplayToolCallBlock) {
        toolGroup.add(block);
        continue;
      }
      flushToolGroup();
      children.add(_DisplayBlockView(block: block));
    }
    flushToolGroup();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
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
        final expanded = displayBlocksFromMarkdownLinks(text);
        if (expanded.length != 1 ||
            expanded.single is! RuntimeDisplayTextBlock ||
            (expanded.single as RuntimeDisplayTextBlock).text != text) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final child in expanded) _DisplayBlockView(block: child),
            ],
          );
        }
        final palette = context.palette;
        return Padding(
          padding: const EdgeInsets.only(bottom: DS.s6),
          child: MarkdownBody(
            data: text,
            selectable: true,
            softLineBreak: true,
            onTapLink: (text, href, title) {
              if (href != null) _openWebLink(context, href);
            },
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(
                color: palette.textPrimary,
                fontSize: DS.t14,
                height: 1.6,
              ),
              code: TextStyle(
                color: palette.accentCyan,
                fontSize: DS.t13,
                backgroundColor:
                    palette.bgDeep.withValues(alpha: palette.isDark ? 0.6 : 0.4),
                fontFamilyFallback: DS.monoFallback,
              ),
              codeblockDecoration: BoxDecoration(
                color: palette.bgDeep.withValues(alpha: palette.isDark ? 0.66 : 0.40),
                borderRadius: BorderRadius.circular(DS.r8),
                border: Border.all(color: palette.divider),
              ),
              codeblockPadding: const EdgeInsets.all(DS.s12),
              blockquoteDecoration: BoxDecoration(
                color: palette.accentLavender.withValues(alpha: 0.06),
                border: Border(
                  left: BorderSide(color: palette.accentLavender, width: 3),
                ),
                borderRadius: BorderRadius.circular(DS.r4),
              ),
              blockquote: TextStyle(
                color: palette.textSecondary,
                fontStyle: FontStyle.italic,
                fontSize: DS.t14,
              ),
              h1: TextStyle(
                color: palette.textPrimary,
                fontSize: DS.t22,
                fontWeight: FontWeight.w700,
              ),
              h2: TextStyle(
                color: palette.textPrimary,
                fontSize: DS.t18,
                fontWeight: FontWeight.w700,
              ),
              h3: TextStyle(
                color: palette.textPrimary,
                fontSize: DS.t16,
                fontWeight: FontWeight.w700,
              ),
              listBullet: TextStyle(
                color: palette.accentEmerald,
                fontWeight: FontWeight.w700,
              ),
              a: TextStyle(
                color: palette.accentCyan,
                decoration: TextDecoration.underline,
                decorationColor: palette.accentCyan.withValues(alpha: 0.6),
              ),
              tableHead: TextStyle(
                color: palette.textPrimary,
                fontWeight: FontWeight.w700,
              ),
              tableBody: TextStyle(color: palette.textPrimary),
              tableBorder: TableBorder.all(color: palette.divider),
              tableCellsPadding: const EdgeInsets.symmetric(
                horizontal: DS.s10,
                vertical: 6,
              ),
              horizontalRuleDecoration: BoxDecoration(
                border: Border(top: BorderSide(color: palette.divider)),
              ),
            ),
          ),
        );
      case RuntimeDisplayImageBlock():
        return _ImageBlock(block: block as RuntimeDisplayImageBlock);
      case RuntimeDisplayFileBlock():
        return _FileBlock(block: block as RuntimeDisplayFileBlock);
      case RuntimeDisplayLinkBlock():
        return _LinkBlock(block: block as RuntimeDisplayLinkBlock);
      case RuntimeDisplayThinkingBlock(:final text):
        if (text.trim().isEmpty) return const SizedBox.shrink();
        return _ThinkingBlock(text: text);
      case RuntimeDisplayToolCallBlock():
        return _ToolCallStackCard(
          blocks: [block as RuntimeDisplayToolCallBlock],
        );
    }
  }
}

class _ImageBlock extends StatelessWidget {
  const _ImageBlock({required this.block});

  final RuntimeDisplayImageBlock block;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final dataUrl = block.dataUrl;
    final bytes = dataUrl == null ? null : _bytesFromDataUrl(dataUrl);
    final label = block.label?.trim().isNotEmpty == true
        ? block.label!.trim()
        : block.path?.trim().isNotEmpty == true
        ? block.path!.trim().split(RegExp(r'[\\/]')).last
        : '图片';
    final image = bytes == null
        ? null
        : Image.memory(
            bytes,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Icon(
              Icons.broken_image_outlined,
              size: 28,
              color: palette.textTertiary,
            ),
          );
    return Container(
      margin: const EdgeInsets.only(bottom: DS.s8),
      constraints: const BoxConstraints(maxWidth: 380),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DS.r10),
        border: Border.all(
          color: palette.accentEmerald.withValues(alpha: 0.28),
        ),
        color: palette.bgDeep.withValues(alpha: palette.isDark ? 0.5 : 0.3),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: image == null
              ? null
              : () => _showImageViewer(context, image, label),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: image ??
                    Center(
                      child: Icon(
                        Icons.image_outlined,
                        size: 32,
                        color: palette.textTertiary,
                      ),
                    ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: DS.s12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.image_outlined,
                      size: 12,
                      color: palette.textTertiary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: DS.t11,
                        ),
                      ),
                    ),
                    if (image != null)
                      Icon(
                        Icons.zoom_out_map_rounded,
                        size: 12,
                        color: palette.textTertiary,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 点击图片块时弹出的可缩放查看器。
void _showImageViewer(BuildContext context, Image image, String label) {
  final palette = context.palette;
  showDialog<void>(
    context: context,
    barrierColor: palette.scrim,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(DS.s20),
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(DS.r12),
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 8,
              child: image,
            ),
          ),
          Positioned(
            top: DS.s10,
            right: DS.s10,
            child: GlassIconButton(
              icon: Icons.close_rounded,
              tooltip: '关闭 (Esc)',
              size: 36,
              iconSize: 18,
              onPressed: () => Navigator.of(ctx).maybePop(),
            ),
          ),
          if (label.isNotEmpty)
            Positioned(
              bottom: DS.s14,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DS.s12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: palette.bgDeep.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(DS.rPill),
                    border: Border.all(color: palette.divider),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: DS.t12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _FileBlock extends StatelessWidget {
  const _FileBlock({required this.block});

  final RuntimeDisplayFileBlock block;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final subtitle = [
      if (block.mimeType?.trim().isNotEmpty == true) block.mimeType!.trim(),
      if (block.sizeBytes != null) _formatFileSize(block.sizeBytes!),
      if (!block.exists) '文件不存在',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: DS.s8),
      constraints: const BoxConstraints(maxWidth: 460),
      decoration: BoxDecoration(
        color: palette.glassFill,
        borderRadius: BorderRadius.circular(DS.r8),
        border: Border.all(color: palette.divider),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(DS.r8),
        child: InkWell(
          onTap: block.exists ? () => _openFile(context, block.path) : null,
          borderRadius: BorderRadius.circular(DS.r8),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DS.s12,
              vertical: DS.s10,
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.accentCyan.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(DS.r8),
                    border: Border.all(
                      color: palette.accentCyan.withValues(alpha: 0.28),
                    ),
                  ),
                  child: Icon(
                    _fileIcon(block),
                    size: 18,
                    color: palette.accentCyan,
                  ),
                ),
                const SizedBox(width: DS.s10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        block.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: DS.t13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle.isEmpty ? block.path : subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: block.exists
                              ? palette.textTertiary
                              : palette.accentCrimson,
                          fontSize: DS.t11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: DS.s6),
                _MicroIconButton(
                  icon: Icons.open_in_new_rounded,
                  tooltip: '打开文件',
                  onPressed: block.exists
                      ? () => _openFile(context, block.path)
                      : null,
                ),
                _MicroIconButton(
                  icon: Icons.folder_open_rounded,
                  tooltip: '打开所在文件夹',
                  onPressed: () => _openContainingFolder(context, block.path),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LinkBlock extends StatelessWidget {
  const _LinkBlock({required this.block});

  final RuntimeDisplayLinkBlock block;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LinkPreviewMetadata?>(
      future: _cachedLinkPreview(block.url),
      builder: (context, snapshot) {
        final metadata = snapshot.data;
        final uri = Uri.tryParse(block.url);
        final host = uri?.host ?? block.url;
        final title = metadata?.title?.trim().isNotEmpty == true
            ? metadata!.title!.trim()
            : block.label;
        final description = metadata?.description?.trim().isNotEmpty == true
            ? metadata!.description!.trim()
            : host;
        final palette = context.palette;
        return Container(
          margin: const EdgeInsets.only(bottom: DS.s8),
          constraints: const BoxConstraints(maxWidth: 460),
          decoration: BoxDecoration(
            color: palette.glassFill,
            borderRadius: BorderRadius.circular(DS.r8),
            border: Border.all(color: palette.divider),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(DS.r8),
            child: InkWell(
              onTap: () => _openWebLink(context, block.url),
              borderRadius: BorderRadius.circular(DS.r8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: DS.s12,
                  vertical: DS.s10,
                ),
                child: Row(
                  children: [
                    _LinkIcon(iconUrl: metadata?.iconUrl),
                    const SizedBox(width: DS.s10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: DS.t13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.textTertiary,
                              fontSize: DS.t11,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: DS.s6),
                    _MicroIconButton(
                      icon: Icons.open_in_new_rounded,
                      tooltip: '打开链接',
                      onPressed: () => _openWebLink(context, block.url),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LinkIcon extends StatelessWidget {
  const _LinkIcon({this.iconUrl});

  final String? iconUrl;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final url = iconUrl?.trim();
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.accentLavender.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(DS.r8),
        border: Border.all(
          color: palette.accentLavender.withValues(alpha: 0.30),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null || url.isEmpty
          ? Icon(Icons.link_rounded, size: 18, color: palette.accentLavender)
          : Image.network(
              url,
              width: 22,
              height: 22,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Icon(
                Icons.link_rounded,
                size: 18,
                color: palette.accentLavender,
              ),
            ),
    );
  }
}

class _ThinkingBlock extends StatefulWidget {
  final String text;
  const _ThinkingBlock({required this.text});

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = palette.accentLavender;
    final preview = widget.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final shortPreview = preview.length > 80
        ? '${preview.substring(0, 80)}…'
        : preview;
    return Padding(
      padding: const EdgeInsets.only(bottom: DS.s8),
      child: Container(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: palette.isDark ? 0.06 : 0.05),
          borderRadius: BorderRadius.circular(DS.r8),
          border: Border(
            left: BorderSide(color: accent.withValues(alpha: 0.5), width: 2.5),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(DS.r8),
          child: InkWell(
            borderRadius: BorderRadius.circular(DS.r8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DS.s10,
                vertical: 6,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.psychology_alt_outlined,
                        size: 13,
                        color: accent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'THINKING',
                        style: TextStyle(
                          color: accent,
                          fontSize: DS.t10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(width: DS.s8),
                      Expanded(
                        child: Text(
                          _expanded ? '点击折叠' : shortPreview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textTertiary,
                            fontSize: DS.t11,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: DS.dFast,
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 14,
                          color: palette.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  AnimatedCrossFade(
                    crossFadeState: _expanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    duration: DS.dQuick,
                    firstChild: const SizedBox.shrink(),
                    secondChild: Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 4),
                      child: SelectableText(
                        widget.text,
                        style: TextStyle(
                          fontStyle: FontStyle.italic,
                          color: palette.textSecondary,
                          fontSize: DS.t12,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MicroIconButton extends StatelessWidget {
  const _MicroIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 15),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        padding: EdgeInsets.zero,
        color: palette.textSecondary,
        disabledColor: palette.textDisabled,
        splashRadius: 18,
        onPressed: onPressed,
      ),
    );
  }
}

IconData _fileIcon(RuntimeDisplayFileBlock block) {
  final mime = block.mimeType?.toLowerCase() ?? '';
  final lower = block.path.toLowerCase();
  if (mime.startsWith('image/') ||
      lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.svg')) {
    return Icons.image_outlined;
  }
  if (mime == 'application/pdf' || lower.endsWith('.pdf')) {
    return Icons.picture_as_pdf_outlined;
  }
  if (mime.startsWith('audio/') ||
      lower.endsWith('.mp3') ||
      lower.endsWith('.wav')) {
    return Icons.audio_file_outlined;
  }
  if (mime.startsWith('video/') ||
      lower.endsWith('.mp4') ||
      lower.endsWith('.mov')) {
    return Icons.video_file_outlined;
  }
  if (lower.endsWith('.zip') ||
      lower.endsWith('.7z') ||
      lower.endsWith('.rar')) {
    return Icons.archive_outlined;
  }
  if (lower.endsWith('.csv') ||
      lower.endsWith('.xls') ||
      lower.endsWith('.xlsx')) {
    return Icons.table_chart_outlined;
  }
  if (lower.endsWith('.html') ||
      lower.endsWith('.css') ||
      lower.endsWith('.js') ||
      lower.endsWith('.ts') ||
      lower.endsWith('.dart') ||
      lower.endsWith('.py') ||
      lower.endsWith('.go') ||
      lower.endsWith('.rs') ||
      lower.endsWith('.json') ||
      lower.endsWith('.yaml') ||
      lower.endsWith('.yml')) {
    return Icons.code_rounded;
  }
  return Icons.description_outlined;
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
  final gib = mib / 1024;
  return '${gib.toStringAsFixed(gib < 10 ? 1 : 0)} GB';
}

Future<void> _openFile(BuildContext context, String path) async {
  try {
    await _openPath(path);
  } catch (e) {
    if (!context.mounted) return;
    _showFileActionError(context, '打开文件失败：$e');
  }
}

Future<void> _openContainingFolder(BuildContext context, String path) async {
  try {
    if (Platform.isWindows) {
      if (File(path).existsSync()) {
        await Process.start('explorer.exe', ['/select,$path']);
        return;
      }
      await _openPath(File(path).parent.path);
      return;
    }
    final target = Directory(path).existsSync() ? path : File(path).parent.path;
    await _openPath(target);
  } catch (e) {
    if (!context.mounted) return;
    _showFileActionError(context, '打开所在文件夹失败：$e');
  }
}

Future<void> _openPath(String path) async {
  if (Platform.isWindows) {
    await Process.start('explorer.exe', [path]);
    return;
  }
  if (Platform.isMacOS) {
    await Process.start('open', [path]);
    return;
  }
  await Process.start('xdg-open', [path]);
}

Future<void> _openWebLink(BuildContext context, String url) async {
  try {
    final uri = Uri.parse(url);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) throw StateError('系统未接受打开请求');
  } catch (e) {
    if (!context.mounted) return;
    _showFileActionError(context, '打开链接失败：$e');
  }
}

void _showFileActionError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}

final _linkPreviewCache = <String, Future<_LinkPreviewMetadata?>>{};

Future<_LinkPreviewMetadata?> _cachedLinkPreview(String url) {
  return _linkPreviewCache.putIfAbsent(url, () => _fetchLinkPreview(url));
}

Future<_LinkPreviewMetadata?> _fetchLinkPreview(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..userAgent = 'HanakoClient/1.0';
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 5));
    request.followRedirects = true;
    request.maxRedirects = 4;
    request.headers.set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml,*/*;q=0.8',
    );
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      return null;
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 8))) {
      bytes.addAll(chunk);
      if (bytes.length >= 256 * 1024) break;
    }
    final html = utf8.decode(bytes, allowMalformed: true);
    final title = _metaContent(html, const ['og:title', 'twitter:title']) ??
        _htmlTitle(html);
    final description = _metaContent(html, const [
      'description',
      'og:description',
      'twitter:description',
    ]);
    final iconHref = _iconHref(html);
    return _LinkPreviewMetadata(
      title: title == null ? null : _cleanHtmlText(title),
      description: description == null ? null : _cleanHtmlText(description),
      iconUrl: iconHref == null ? null : uri.resolve(iconHref).toString(),
    );
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

String? _htmlTitle(String html) {
  final match = RegExp(
    '<title[^>]*>([\\s\\S]*?)</title>',
    caseSensitive: false,
  ).firstMatch(html);
  return match?.group(1);
}

String? _metaContent(String html, List<String> names) {
  final wanted = names.map((name) => name.toLowerCase()).toSet();
  for (final match in RegExp(
    '<meta\\s+[^>]*>',
    caseSensitive: false,
  ).allMatches(html)) {
    final tag = match.group(0) ?? '';
    final name = (_htmlAttr(tag, 'name') ?? _htmlAttr(tag, 'property'))
        ?.toLowerCase();
    if (name == null || !wanted.contains(name)) continue;
    final content = _htmlAttr(tag, 'content');
    if (content != null && content.trim().isNotEmpty) return content;
  }
  return null;
}

String? _iconHref(String html) {
  for (final match in RegExp(
    '<link\\s+[^>]*>',
    caseSensitive: false,
  ).allMatches(html)) {
    final tag = match.group(0) ?? '';
    final rel = _htmlAttr(tag, 'rel')?.toLowerCase() ?? '';
    if (!rel.contains('icon')) continue;
    final href = _htmlAttr(tag, 'href');
    if (href != null && href.trim().isNotEmpty) return href;
  }
  return null;
}

String? _htmlAttr(String tag, String name) {
  final match = RegExp(
    "\\s$name=[\"']([^\"']*)[\"']",
    caseSensitive: false,
  ).firstMatch(tag);
  return match?.group(1);
}

String _cleanHtmlText(String value) {
  var out = value
      .replaceAll(RegExp('<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  out = out
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
    final code = int.tryParse(match.group(1)!, radix: 16);
    return code == null ? match.group(0)! : String.fromCharCode(code);
  });
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
    final code = int.tryParse(match.group(1)!);
    return code == null ? match.group(0)! : String.fromCharCode(code);
  });
  return out.trim();
}

class _LinkPreviewMetadata {
  const _LinkPreviewMetadata({this.title, this.description, this.iconUrl});

  final String? title;
  final String? description;
  final String? iconUrl;
}

Uint8List? _bytesFromDataUrl(String dataUrl) {
  final comma = dataUrl.indexOf(',');
  if (!dataUrl.startsWith('data:') || comma < 0) return null;
  try {
    return base64Decode(dataUrl.substring(comma + 1));
  } catch (_) {
    return null;
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

// 工具英文 toolName → 中文显示名。模型填了 `_purpose` 时，purpose 是主要展示
// 内容；模型漏填 / purpose 为空时，UI 回退用 "[中文名] [参数摘要]" 兜底展示。
// 不在 map 里的工具名直接显示英文 toolName，至少不丢信息。
const _toolDisplayNames = <String, String>{
  'exec_command': '执行命令',
  'write_stdin': '终端输入',
  'read_file': '读取文件',
  'list_dir': '列出目录',
  'search_text': '搜索文本',
  'apply_patch': '修改文件',
  'view_image': '查看图片',
  'request_permissions': '请求授权',
  'request_user_input': '请求输入',
  'tool_search': '查找工具',
  'create_goal': '创建目标',
  'get_goal': '查看目标',
  'update_goal_status': '更新目标',
  'spawn_agent': '派生子智能体',
  'send_message': '发送消息',
  'wait_agent': '等待子智能体',
  'close_agent': '关闭子智能体',
  'list_agents': '列出子智能体',
  'followup_task': '跟进任务',
  'update_plan': '更新计划',
  'windows_capture_region': '截屏',
  'windows_mouse_move': '移动鼠标',
  'windows_mouse_click': '点击',
  'windows_text_input': '输入文字',
  'windows_uia_tree': '读取 UI 树',
  'windows_uia_invoke': '调用 UI 控件',
  'windows_ocr_recognize': 'OCR 识别',
  'windows_ui_parse': '解析界面',
};

String _toolDisplayName(String toolName) =>
    _toolDisplayNames[toolName] ?? toolName;

({String label, Color color, IconData icon}) _toolStatusVisuals(
  _ToolStatus status,
  HanaPalette palette,
) {
  return switch (status) {
    _ToolStatus.running => (
      label: '运行中',
      color: palette.accentCyan,
      icon: Icons.hourglass_top_rounded,
    ),
    _ToolStatus.success => (
      label: '已运行',
      color: palette.accentEmerald,
      icon: Icons.check_rounded,
    ),
    _ToolStatus.failed => (
      label: '失败',
      color: palette.accentCrimson,
      icon: Icons.priority_high_rounded,
    ),
    _ToolStatus.timedOut => (
      label: '超时',
      color: palette.accentAmber,
      icon: Icons.timer_off_rounded,
    ),
  };
}

double _measureTextWidth(String text, TextStyle style) {
  if (text.isEmpty) return 0;
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout();
  return tp.size.width;
}

/// 一组连续工具调用的合并卡片。即便只有一条也走这里渲染，保证 UI 统一。
class _ToolCallStackCard extends StatelessWidget {
  const _ToolCallStackCard({required this.blocks});

  final List<RuntimeDisplayToolCallBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: palette.glassFill,
        borderRadius: BorderRadius.circular(DS.r8),
        border: Border.all(color: palette.divider),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DS.r8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < blocks.length; i++) ...[
              if (i > 0)
                Container(height: DS.hairline, color: palette.divider),
              _ToolCallRow(block: blocks[i]),
            ],
          ],
        ),
      ),
    );
  }
}

/// 单工具调用的一行：
///   [图标] [状态文字] · [中文名]  [purpose（主）+ 参数（次，宽度够才显示）]  ›
///
/// 二阶截断规则：
///   1. 当 purpose 和参数摘要加在一起塞得下时，两者都显示，参数用 textTertiary
///      作为次要信息。
///   2. 一起塞不下时，参数完全消失，只保留 purpose。
///   3. 仅 purpose 自己也塞不下时，RichText 在 purpose 末尾自动加 "…"。
///   4. 模型漏填 _purpose 时，参数摘要会顶替到主位置，避免行只显示"中文名"
///      让用户看不出是在做什么。
class _ToolCallRow extends StatefulWidget {
  const _ToolCallRow({required this.block});

  final RuntimeDisplayToolCallBlock block;

  @override
  State<_ToolCallRow> createState() => _ToolCallRowState();
}

class _ToolCallRowState extends State<_ToolCallRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final status = _toolStatus(widget.block);
    final visuals = _toolStatusVisuals(status, palette);
    final displayName = _toolDisplayName(widget.block.name);
    final rawPurpose = widget.block.purpose;
    final hasPurpose = rawPurpose != null && rawPurpose.isNotEmpty;
    final argsSummary = _toolSummary(widget.block);
    final primary = hasPurpose ? rawPurpose : argsSummary;
    final secondary = hasPurpose ? argsSummary : '';

    final statusStyle = TextStyle(
      color: visuals.color,
      fontSize: DS.t11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
      height: 1.2,
    );
    final dotStyle = TextStyle(
      color: palette.textTertiary,
      fontSize: DS.t11,
      height: 1.2,
    );
    final nameStyle = TextStyle(
      color: palette.textSecondary,
      fontSize: DS.t11,
      fontWeight: FontWeight.w600,
      height: 1.2,
    );
    final primaryStyle = TextStyle(
      color: palette.textPrimary,
      fontSize: DS.t12,
      height: 1.3,
    );
    final secondaryStyle = TextStyle(
      color: palette.textTertiary,
      fontSize: DS.t11,
      fontFamilyFallback: DS.monoFallback,
      height: 1.3,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: _hover
            ? visuals.color.withValues(alpha: 0.06)
            : Colors.transparent,
        child: InkWell(
          onTap: () => _showToolDetailsForBlock(context, widget.block),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DS.s10,
              vertical: DS.s8,
            ),
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                const iconSize = 14.0;
                const iconRightSp = 6.0;
                const statusRightSp = 6.0;
                const dotW = 6.0;
                const dotRightSp = 6.0;
                const nameRightSp = 10.0;
                const chevronLeftSp = 6.0;
                const chevronSize = 14.0;

                final statusW = _measureTextWidth(visuals.label, statusStyle);
                final nameW = _measureTextWidth(displayName, nameStyle);

                final fixedW =
                    iconSize +
                    iconRightSp +
                    statusW +
                    statusRightSp +
                    dotW +
                    dotRightSp +
                    nameW +
                    nameRightSp +
                    chevronLeftSp +
                    chevronSize;
                final available = (constraints.maxWidth - fixedW).clamp(
                  0.0,
                  constraints.maxWidth,
                );

                String? trailingSecondary;
                if (hasPurpose && secondary.isNotEmpty) {
                  final primaryW = _measureTextWidth(primary, primaryStyle);
                  final sepW = _measureTextWidth('  ', secondaryStyle);
                  final secondaryW = _measureTextWidth(
                    secondary,
                    secondaryStyle,
                  );
                  if (primaryW + sepW + secondaryW <= available) {
                    trailingSecondary = secondary;
                  }
                }

                return Row(
                  children: [
                    Icon(visuals.icon, size: iconSize, color: visuals.color),
                    const SizedBox(width: iconRightSp),
                    Text(visuals.label, style: statusStyle),
                    const SizedBox(width: statusRightSp),
                    Text('·', style: dotStyle),
                    const SizedBox(width: dotRightSp),
                    Text(displayName, style: nameStyle),
                    const SizedBox(width: nameRightSp),
                    Expanded(
                      child: RichText(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          children: [
                            TextSpan(text: primary, style: primaryStyle),
                            if (trailingSecondary != null)
                              TextSpan(
                                text: '  $trailingSecondary',
                                style: secondaryStyle,
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: chevronLeftSp),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: chevronSize,
                      color: palette.textTertiary,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

void _showToolDetailsForBlock(
  BuildContext context,
  RuntimeDisplayToolCallBlock block,
) {
  final auditText = _toolAuditText(block);
  final chineseName = _toolDisplayName(block.name);
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.build_outlined,
            size: 18,
            color: context.palette.accentCyan,
          ),
          const SizedBox(width: DS.s8),
          Expanded(
            child: Text(
              chineseName == block.name
                  ? '工具调用 · ${block.name}'
                  : '工具调用 · $chineseName（${block.name}）',
            ),
          ),
        ],
      ),
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
                const SizedBox(height: DS.s14),
                _DetailSection(
                  title: block.resultIsError ? '结果（失败）' : '结果',
                  content: block.resultContent?.trim().isNotEmpty == true
                      ? _prettyJson(block.resultContent!)
                      : '尚未收到执行结果',
                ),
                if (block.resultDetails != null) ...[
                  const SizedBox(height: DS.s14),
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
          icon: const Icon(Icons.copy_rounded, size: 16),
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

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.content});

  final String title;
  final String content;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: palette.textSecondary,
            fontSize: DS.t12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: DS.s6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(DS.s12),
          decoration: BoxDecoration(
            color: palette.bgDeep.withValues(alpha: palette.isDark ? 0.6 : 0.40),
            borderRadius: BorderRadius.circular(DS.r8),
            border: Border.all(color: palette.divider),
          ),
          child: SelectableText(
            content,
            style: TextStyle(
              fontFamilyFallback: DS.monoFallback,
              fontSize: DS.t12,
              height: 1.5,
              color: palette.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

enum _ToolStatus { running, success, failed, timedOut }

_ToolStatus _toolStatus(RuntimeDisplayToolCallBlock block) {
  final content = block.resultContent;
  if (content == null) return _ToolStatus.running;
  final decoded = _decodeArgs(content);
  // 超时优先：超时也是 ok=false / isError=true，但语义上是"未拿到结果"而非"执行失败"，
  // UI 上单独表达让用户能一眼区分。
  if (decoded != null &&
      (decoded['status'] == 'timed_out' || decoded['timed_out'] == true)) {
    return _ToolStatus.timedOut;
  }
  if (block.resultIsError) return _ToolStatus.failed;
  if (decoded != null && decoded['ok'] == false) return _ToolStatus.failed;
  return _ToolStatus.success;
}

String _toolSummary(RuntimeDisplayToolCallBlock block) {
  final args = _decodeArgs(block.argsJson);
  if (args == null || args.isEmpty) return '';
  // 过滤掉 _purpose：那是给 UI 用的中文说明，不是真正的工具参数。
  final filtered = <String, dynamic>{
    for (final entry in args.entries)
      if (entry.key != '_purpose') entry.key: entry.value,
  };
  if (filtered.isEmpty) return '';
  if (block.name == 'exec_command') {
    final cmd = filtered['cmd']?.toString() ?? filtered['command']?.toString();
    return cmd == null ? '' : _oneLine(cmd);
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
    final value = filtered[key];
    if (value == null) continue;
    return '$key=${_oneLine(value.toString())}';
  }
  final first = filtered.entries.first;
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
      _ToolStatus.timedOut => '超时',
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
