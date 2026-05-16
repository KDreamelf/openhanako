import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

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
    final c = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '子体',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: c.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.only(bottom: 2),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
              ),
              decoration: BoxDecoration(
                color: c.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
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
            const SizedBox(height: 30),
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
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: MarkdownBody(
            data: text,
            selectable: true,
            softLineBreak: true,
            styleSheet: MarkdownStyleSheet.fromTheme(
              Theme.of(context),
            ).copyWith(p: Theme.of(context).textTheme.bodyMedium),
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
        return _ToolCallCard(block: block as RuntimeDisplayToolCallBlock);
    }
  }
}

class _ImageBlock extends StatelessWidget {
  const _ImageBlock({required this.block});

  final RuntimeDisplayImageBlock block;

  @override
  Widget build(BuildContext context) {
    final dataUrl = block.dataUrl;
    final bytes = dataUrl == null ? null : _bytesFromDataUrl(dataUrl);
    final label = block.label?.trim().isNotEmpty == true
        ? block.label!.trim()
        : block.path?.trim().isNotEmpty == true
        ? block.path!.trim().split(RegExp(r'[\\/]')).last
        : '图片';
    final c = Theme.of(context).colorScheme;
    final image = bytes == null
        ? null
        : Image.memory(
            bytes,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.broken_image_outlined, size: 28),
          );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      constraints: const BoxConstraints(maxWidth: 360),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.outlineVariant),
        color: c.surfaceContainerHighest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child:
                image ??
                Center(
                  child: Icon(
                    Icons.image_outlined,
                    size: 32,
                    color: c.onSurfaceVariant,
                  ),
                ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileBlock extends StatelessWidget {
  const _FileBlock({required this.block});

  final RuntimeDisplayFileBlock block;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final subtitle = [
      if (block.mimeType?.trim().isNotEmpty == true) block.mimeType!.trim(),
      if (block.sizeBytes != null) _formatFileSize(block.sizeBytes!),
      if (!block.exists) '文件不存在',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        color: c.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.outlineVariant),
      ),
      child: InkWell(
        onTap: block.exists ? () => _openFile(context, block.path) : null,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(_fileIcon(block), size: 20, color: c.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      block.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle.isEmpty ? block.path : subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: block.exists ? c.onSurfaceVariant : c.error,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '打开文件',
                icon: const Icon(Icons.open_in_new, size: 18),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                padding: EdgeInsets.zero,
                onPressed: block.exists
                    ? () => _openFile(context, block.path)
                    : null,
              ),
              IconButton(
                tooltip: '打开所在文件夹',
                icon: const Icon(Icons.folder_open, size: 18),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                padding: EdgeInsets.zero,
                onPressed: () => _openContainingFolder(context, block.path),
              ),
            ],
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
        final c = Theme.of(context).colorScheme;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          constraints: const BoxConstraints(maxWidth: 420),
          decoration: BoxDecoration(
            color: c.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.outlineVariant),
          ),
          child: InkWell(
            onTap: () => _openWebLink(context, block.url),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  _LinkIcon(iconUrl: metadata?.iconUrl),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: c.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '打开链接',
                    icon: const Icon(Icons.open_in_new, size: 18),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: () => _openWebLink(context, block.url),
                  ),
                ],
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
    final c = Theme.of(context).colorScheme;
    final url = iconUrl?.trim();
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.primary.withAlpha(20),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null || url.isEmpty
          ? Icon(Icons.link, size: 20, color: c.primary)
          : Image.network(
              url,
              width: 22,
              height: 22,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) =>
                  Icon(Icons.link, size: 20, color: c.primary),
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
    return Icons.code;
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
    final title =
        _metaContent(html, const ['og:title', 'twitter:title']) ??
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
  if (block.name == 'exec_command') {
    return _oneLine(
      args['cmd']?.toString() ?? args['command']?.toString() ?? block.argsJson,
    );
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
