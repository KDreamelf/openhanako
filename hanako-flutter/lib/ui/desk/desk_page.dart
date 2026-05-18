import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/desk_manager.dart';
import '../design/design.dart';

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
    final palette = context.palette;
    final agentId = _agentId;
    final deskPath = agentId == null
        ? null
        : ref.read(engineProvider).deskManager.deskDir(agentId).path;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: Column(
          children: [
            _DeskHeader(
              agentId: agentId,
              deskPath: deskPath,
              busy: _busy,
              entryCount: _entries.length,
              onRefresh: _busy ? null : _refresh,
              onOpenFolder:
                  deskPath == null ? null : () => _openPath(deskPath),
              onClose: () => Navigator.of(context).pop(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(DS.s16),
                child: HanaBanner(
                  icon: Icons.error_outline,
                  title: '加载失败',
                  subtitle: _error!,
                  color: palette.accentCrimson,
                ),
              ),
            if (_busy)
              LinearProgressIndicator(
                minHeight: 2,
                color: palette.accentEmerald,
                backgroundColor: Colors.transparent,
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final narrow = box.maxWidth < 820;
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
                        SizedBox(height: 260, child: list),
                        Container(
                          height: DS.hairline,
                          color: palette.divider,
                        ),
                        Expanded(child: preview),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      SizedBox(width: 320, child: list),
                      Container(
                        width: DS.hairline,
                        color: palette.divider,
                      ),
                      Expanded(child: preview),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeskHeader extends StatelessWidget {
  const _DeskHeader({
    required this.agentId,
    required this.deskPath,
    required this.busy,
    required this.entryCount,
    required this.onRefresh,
    required this.onOpenFolder,
    required this.onClose,
  });

  final String? agentId;
  final String? deskPath;
  final bool busy;
  final int entryCount;
  final VoidCallback? onRefresh;
  final VoidCallback? onOpenFolder;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: palette.bgRaised.withValues(alpha: palette.isDark ? 0.70 : 0.86),
        border: Border(
          bottom: BorderSide(color: palette.divider, width: DS.hairline),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: DS.s16,
            vertical: DS.s12,
          ),
          child: Row(
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
                  color: palette.accentCyan.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(DS.r8),
                  border: Border.all(
                    color: palette.accentCyan.withValues(alpha: 0.36),
                  ),
                ),
                child: Icon(
                  Icons.folder_special_outlined,
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
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '书桌',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t18,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                            letterSpacing: 0.2,
                          ),
                        ),
                        if (entryCount > 0) ...[
                          const SizedBox(width: DS.s10),
                          HanaPill(
                            label: '$entryCount 项',
                            color: palette.accentEmerald,
                            dense: true,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      agentId == null
                          ? '尚未选择 Agent'
                          : 'Agent · $agentId · 本地文件',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: DS.t12,
                      ),
                    ),
                  ],
                ),
              ),
              GlassIconButton(
                icon: Icons.refresh_rounded,
                tooltip: '刷新',
                onPressed: onRefresh,
              ),
              const SizedBox(width: DS.s4),
              GlassIconButton(
                icon: Icons.folder_open_rounded,
                tooltip: '打开书桌目录',
                onPressed: onOpenFolder,
              ),
            ],
          ),
        ),
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
    final palette = context.palette;
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_outlined,
              size: 36,
              color: palette.textTertiary,
            ),
            const SizedBox(height: DS.s10),
            Text(
              '书桌还没有文件',
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: DS.t13,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(DS.s8),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final isSelected = selected?.relativePath == entry.relativePath;
        return _DeskFileTile(
          entry: entry,
          selected: isSelected,
          onTap: () => onSelect(entry),
        );
      },
    );
  }
}

class _DeskFileTile extends StatefulWidget {
  const _DeskFileTile({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final DeskEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_DeskFileTile> createState() => _DeskFileTileState();
}

class _DeskFileTileState extends State<_DeskFileTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = palette.accentEmerald;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DS.dFast,
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: widget.selected
              ? accent.withValues(alpha: 0.10)
              : _hover
                  ? palette.glassFill
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(DS.r8),
          border: widget.selected
              ? Border.all(color: accent.withValues(alpha: 0.36))
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(DS.r8),
          child: InkWell(
            borderRadius: BorderRadius.circular(DS.r8),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DS.s10,
                vertical: DS.s10,
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: accent.withValues(
                        alpha: widget.selected ? 0.20 : 0.10,
                      ),
                      borderRadius: BorderRadius.circular(DS.r6),
                      border: Border.all(
                        color: accent.withValues(
                          alpha: widget.selected ? 0.42 : 0.20,
                        ),
                      ),
                    ),
                    child: Icon(
                      _kindIcon(widget.entry.kind),
                      size: 15,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: DS.s10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: DS.t13,
                            fontWeight: widget.selected
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.entry.relativePath} · ${_formatSize(widget.entry.size)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.textTertiary,
                            fontSize: DS.t11,
                          ),
                        ),
                      ],
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
    final palette = context.palette;
    final item = preview;
    if (selected == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.touch_app_outlined,
              size: 36,
              color: palette.textTertiary,
            ),
            const SizedBox(height: DS.s10),
            Text(
              '选择左侧文件查看预览',
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: DS.t13,
              ),
            ),
          ],
        ),
      );
    }
    if (item == null) {
      return Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: palette.accentEmerald,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            color: palette.bgRaised.withValues(
              alpha: palette.isDark ? 0.70 : 0.86,
            ),
            border: Border(
              bottom: BorderSide(color: palette.divider, width: DS.hairline),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(DS.s16, DS.s10, DS.s10, DS.s10),
          child: Row(
            children: [
              Icon(_kindIcon(item.kind), size: 16, color: palette.accentCyan),
              const SizedBox(width: DS.s8),
              Expanded(
                child: Text(
                  item.relativePath,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: DS.t14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              GlassIconButton(
                icon: Icons.copy_rounded,
                size: 30,
                iconSize: 15,
                tooltip: '复制路径',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: item.path)),
              ),
              const SizedBox(width: DS.s4),
              GlassIconButton(
                icon: Icons.open_in_new_rounded,
                size: 30,
                iconSize: 15,
                tooltip: '打开文件',
                onPressed: onOpen,
              ),
              const SizedBox(width: DS.s4),
              GlassIconButton(
                icon: Icons.folder_open_rounded,
                size: 30,
                iconSize: 15,
                tooltip: '打开位置',
                onPressed: onOpenFolder,
              ),
            ],
          ),
        ),
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
    final palette = context.palette;
    switch (preview.kind) {
      case DeskFileKind.markdown:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(DS.s20),
          child: MarkdownBody(
            data: preview.text ?? '',
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(
                color: palette.textPrimary,
                fontSize: DS.t14,
                height: 1.6,
              ),
              code: TextStyle(
                color: palette.accentCyan,
                fontFamilyFallback: DS.monoFallback,
                fontSize: DS.t13,
              ),
              codeblockDecoration: BoxDecoration(
                color: palette.bgDeep.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(DS.r8),
                border: Border.all(color: palette.divider),
              ),
            ),
          ),
        );
      case DeskFileKind.text:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(DS.s20),
          child: SelectableText(
            preview.text ?? '',
            style: TextStyle(
              color: palette.textPrimary,
              fontFamilyFallback: DS.monoFallback,
              fontSize: DS.t13,
              height: 1.55,
            ),
          ),
        );
      case DeskFileKind.image:
        return Container(
          color: palette.bgDeep,
          child: InteractiveViewer(
            child: Center(child: Image.file(File(preview.path))),
          ),
        );
      case DeskFileKind.binary:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: palette.glassFill,
                  borderRadius: BorderRadius.circular(DS.r12),
                  border: Border.all(color: palette.divider),
                ),
                child: Icon(
                  Icons.insert_drive_file_outlined,
                  size: 30,
                  color: palette.textSecondary,
                ),
              ),
              const SizedBox(height: DS.s14),
              Text(
                '${preview.kind.label} · ${_formatSize(preview.size)}',
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: DS.t13,
                ),
              ),
              const SizedBox(height: DS.s4),
              Text(
                '此类型不在预览支持范围内',
                style: TextStyle(
                  color: palette.textTertiary,
                  fontSize: DS.t11,
                ),
              ),
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
