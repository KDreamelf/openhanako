import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../design/design.dart';

/// 编辑器子窗口：用 re_editor + re_highlight 替代 CodeMirror 6。
/// 支持：行号 / 自动语言识别 / 暗色亮色主题 / 保存（Ctrl+S）。
class EditorWindow extends StatefulWidget {
  const EditorWindow({super.key, required this.filePath});
  final String filePath;

  @override
  State<EditorWindow> createState() => _EditorWindowState();
}

class _EditorWindowState extends State<EditorWindow> {
  final _controller = CodeLineEditingController();
  bool _modified = false;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
    _controller.addListener(() {
      if (!_modified) setState(() => _modified = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.filePath.isEmpty) return;
    try {
      final f = File(widget.filePath);
      if (f.existsSync()) {
        _controller.text = await f.readAsString();
        _modified = false;
        if (mounted) setState(() {});
      }
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _save() async {
    if (widget.filePath.isEmpty) {
      setState(() => _error = '没有指定文件路径');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final f = File(widget.filePath);
      f.parent.createSync(recursive: true);
      await f.writeAsString(_controller.text, flush: true);
      if (!mounted) return;
      setState(() {
        _modified = false;
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _saving = false;
      });
    }
  }

  dynamic _detectLanguage() {
    final ext = widget.filePath.split('.').last.toLowerCase();
    return switch (ext) {
      'dart' => langDart,
      'js' || 'mjs' || 'cjs' => langJavascript,
      'ts' || 'tsx' => langTypescript,
      'json' => langJson,
      'md' || 'markdown' => langMarkdown,
      'py' => langPython,
      'yaml' || 'yml' => langYaml,
      _ => null,
    };
  }

  String _ext() => widget.filePath.split('.').last.toLowerCase();

  String _shortName() {
    if (widget.filePath.isEmpty) return '(新文件)';
    final normalized = widget.filePath.replaceAll('\\', '/');
    final ix = normalized.lastIndexOf('/');
    return ix < 0 ? normalized : normalized.substring(ix + 1);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final isDark = palette.isDark;
    final bg = palette.bgDeep;
    final lang = _detectLanguage();

    return Scaffold(
      backgroundColor: bg,
      body: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: palette.bgRaised
                  .withValues(alpha: palette.isDark ? 0.86 : 0.94),
              border: Border(
                bottom: BorderSide(color: palette.divider, width: DS.hairline),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: DS.s14,
                  vertical: DS.s10,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: palette.accentLavender.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(DS.r6),
                        border: Border.all(
                          color:
                              palette.accentLavender.withValues(alpha: 0.36),
                        ),
                      ),
                      child: Icon(
                        Icons.edit_note_rounded,
                        size: 16,
                        color: palette.accentLavender,
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
                                _shortName(),
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontSize: DS.t14,
                                  fontWeight: FontWeight.w700,
                                  height: 1.15,
                                ),
                              ),
                              if (_modified) ...[
                                const SizedBox(width: 6),
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: palette.accentAmber,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: palette.accentAmber
                                            .withValues(alpha: 0.6),
                                        blurRadius: 4,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (widget.filePath.isNotEmpty)
                            Text(
                              widget.filePath,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.textTertiary,
                                fontSize: DS.t11,
                                fontFamilyFallback: DS.monoFallback,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_ext().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: DS.s8),
                        child: HanaPill(
                          label: _ext(),
                          color: palette.accentCyan,
                          dense: true,
                          outlined: false,
                        ),
                      ),
                    GlassButton(
                      icon: Icons.save_rounded,
                      label: _saving ? '保存中…' : '保存',
                      tooltip: 'Ctrl+S',
                      accent: palette.accentEmerald,
                      filled: true,
                      onPressed: _saving ? null : _save,
                      dense: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Shortcuts(
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.keyS, control: true):
                        _SaveIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      _SaveIntent: CallbackAction<_SaveIntent>(
                        onInvoke: (_) {
                          _save();
                          return null;
                        },
                      ),
                    },
                    child: Focus(
                      autofocus: true,
                      child: CodeEditor(
                        controller: _controller,
                        style: CodeEditorStyle(
                          fontFamily: DS.monoPrimary,
                          fontSize: 13,
                          backgroundColor: bg,
                          codeTheme: CodeHighlightTheme(
                            languages: {
                              if (lang != null)
                                _ext(): CodeHighlightThemeMode(mode: lang),
                            },
                            theme: isDark ? atomOneDarkTheme : atomOneLightTheme,
                          ),
                        ),
                        indicatorBuilder: (
                          context,
                          editingController,
                          chunkController,
                          notifier,
                        ) {
                          return Row(
                            children: [
                              DefaultCodeLineNumber(
                                controller: editingController,
                                notifier: notifier,
                              ),
                              DefaultCodeChunkIndicator(
                                width: 14,
                                controller: chunkController,
                                notifier: notifier,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                if (_error != null)
                  Positioned(
                    left: DS.s14,
                    right: DS.s14,
                    bottom: DS.s14,
                    child: HanaBanner(
                      icon: Icons.error_outline_rounded,
                      title: '编辑器错误',
                      subtitle: _error!,
                      color: palette.accentCrimson,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}
