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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF071426) : const Color(0xFFF6FAFF);
    final lang = _detectLanguage();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              Icons.edit_note,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.filePath.isEmpty ? '（新文件）' : widget.filePath,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_modified)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Text(
                  '•',
                  style: TextStyle(fontSize: 22, color: Colors.orange),
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            tooltip: '保存 (Ctrl+S)',
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: Stack(
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
                    fontFamily: 'monospace',
                    fontSize: 13,
                    backgroundColor: bg,
                    codeTheme: CodeHighlightTheme(
                      languages: {
                        if (lang != null)
                          (widget.filePath.split('.').last.toLowerCase()):
                              CodeHighlightThemeMode(mode: lang),
                      },
                      theme: isDark ? atomOneDarkTheme : atomOneLightTheme,
                    ),
                  ),
                  indicatorBuilder:
                      (context, editingController, chunkController, notifier) {
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
              left: 12,
              right: 12,
              bottom: 12,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(_error!),
                ),
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
