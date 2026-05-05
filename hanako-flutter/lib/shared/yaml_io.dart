import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// YAML I/O 辅助：读 + 写回保留注释（基于 yaml_edit）。
/// 规避 N-BUG-7（yaml_writer 序列化丢失注释）。
class YamlIo {
  YamlIo._();

  /// 读取 YAML 文件为 Map（顶层应是 mapping），不存在时返回空 Map。
  static Map<String, dynamic> readMap(File file) {
    if (!file.existsSync()) return <String, dynamic>{};
    final src = file.readAsStringSync();
    if (src.trim().isEmpty) return <String, dynamic>{};
    final doc = loadYaml(src);
    if (doc is YamlMap) return _toPlain(doc) as Map<String, dynamic>;
    return <String, dynamic>{};
  }

  /// 在 [path] 处写入 [value]，保留注释与字段顺序。文件不存在则创建。
  static void writeAt(File file, List<Object> path, Object? value) {
    file.parent.createSync(recursive: true);
    String src = file.existsSync() ? file.readAsStringSync() : '';
    if (src.trim().isEmpty) src = '{}\n';
    final editor = YamlEditor(src);
    try {
      editor.update(path, value);
    } catch (_) {
      // path 不存在，逐级创建
      for (var i = 1; i <= path.length; i++) {
        final parentPath = path.sublist(0, i - 1);
        final key = path[i - 1];
        Object? maybe;
        try {
          maybe = editor.parseAt(parentPath).value;
        } catch (_) {
          maybe = null;
        }
        if (i == path.length) {
          if (maybe is Map) {
            editor.update(path, value);
          } else {
            editor.update(parentPath, {key: value});
          }
        } else {
          if (maybe is! Map) {
            editor.update(parentPath, {key: <String, dynamic>{}});
          }
        }
      }
    }
    file.writeAsStringSync(editor.toString(), flush: true);
  }

  /// 删除 [path] 处的 key。不存在静默忽略。
  static void removeAt(File file, List<Object> path) {
    if (!file.existsSync()) return;
    final src = file.readAsStringSync();
    final editor = YamlEditor(src);
    try {
      editor.remove(path);
      file.writeAsStringSync(editor.toString(), flush: true);
    } catch (_) {}
  }

  /// 全文覆盖（不保留注释）。仅在新建文件时使用。
  static void writeWhole(File file, Map<String, dynamic> data) {
    file.parent.createSync(recursive: true);
    final editor = YamlEditor('');
    editor.update([], data);
    file.writeAsStringSync(editor.toString(), flush: true);
  }

  static Object? _toPlain(Object? n) {
    if (n is YamlMap) {
      return n.map((k, v) => MapEntry(k.toString(), _toPlain(v)));
    }
    if (n is YamlList) {
      return n.map(_toPlain).toList();
    }
    return n;
  }
}
