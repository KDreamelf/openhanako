import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../shared/hana_home.dart';

class DeskManager {
  const DeskManager(this.home);

  final HanaHome home;

  Directory deskDir(String agentId) => home.agentDesk(agentId);

  List<DeskEntry> listFiles(String agentId, {int maxEntries = 200}) {
    final root = deskDir(agentId);
    final entries = <DeskEntry>[];
    if (!root.existsSync()) return entries;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entries.length >= maxEntries) break;
      final stat = entity.statSync();
      if (stat.type == FileSystemEntityType.directory) continue;
      if (stat.type != FileSystemEntityType.file) continue;
      final relativePath = p.relative(entity.path, from: root.path);
      entries.add(
        DeskEntry(
          path: entity.path,
          relativePath: relativePath,
          name: p.basename(entity.path),
          size: stat.size,
          modified: stat.modified,
          kind: _kindForPath(entity.path),
        ),
      );
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  Future<DeskPreview> preview(
    String agentId,
    String path, {
    int maxBytes = 512 * 1024,
  }) async {
    final file = resolveDeskFile(agentId, path);
    if (!file.existsSync()) {
      throw StateError('Desk file not found: $path');
    }
    final stat = await file.stat();
    final kind = _kindForPath(file.path);
    if (kind == DeskFileKind.image) {
      return DeskPreview(
        path: file.path,
        relativePath: p.relative(file.path, from: deskDir(agentId).path),
        kind: kind,
        size: stat.size,
      );
    }
    if (!_looksText(file.path) || stat.size > maxBytes) {
      return DeskPreview(
        path: file.path,
        relativePath: p.relative(file.path, from: deskDir(agentId).path),
        kind: DeskFileKind.binary,
        size: stat.size,
      );
    }
    final bytes = await file.readAsBytes();
    return DeskPreview(
      path: file.path,
      relativePath: p.relative(file.path, from: deskDir(agentId).path),
      kind: kind,
      size: stat.size,
      text: utf8.decode(bytes, allowMalformed: true),
    );
  }

  File resolveDeskFile(String agentId, String rawPath) {
    final root = _normalizedAbsolute(deskDir(agentId).path);
    final target = p.isAbsolute(rawPath)
        ? _normalizedAbsolute(rawPath)
        : _normalizedAbsolute(p.join(root, rawPath));
    if (!_isWithin(root, target)) {
      throw ArgumentError.value(rawPath, 'path', 'path escapes agent desk');
    }
    return File(target);
  }

  static String _normalizedAbsolute(String path) =>
      p.normalize(p.absolute(path));

  static bool _isWithin(String root, String target) {
    final normalizedRoot = _caseKey(root);
    final normalizedTarget = _caseKey(target);
    return normalizedTarget == normalizedRoot ||
        normalizedTarget.startsWith('$normalizedRoot${p.separator}');
  }

  static String _caseKey(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;

  static DeskFileKind _kindForPath(String path) {
    final ext = p.extension(path).toLowerCase();
    if (_imageExts.contains(ext)) return DeskFileKind.image;
    if (ext == '.md' || ext == '.markdown') return DeskFileKind.markdown;
    if (_textExts.contains(ext)) return DeskFileKind.text;
    return DeskFileKind.binary;
  }

  static bool _looksText(String path) {
    final kind = _kindForPath(path);
    return kind == DeskFileKind.text || kind == DeskFileKind.markdown;
  }
}

class DeskEntry {
  const DeskEntry({
    required this.path,
    required this.relativePath,
    required this.name,
    required this.size,
    required this.modified,
    required this.kind,
  });

  final String path;
  final String relativePath;
  final String name;
  final int size;
  final DateTime modified;
  final DeskFileKind kind;
}

class DeskPreview {
  const DeskPreview({
    required this.path,
    required this.relativePath,
    required this.kind,
    required this.size,
    this.text,
  });

  final String path;
  final String relativePath;
  final DeskFileKind kind;
  final int size;
  final String? text;
}

enum DeskFileKind {
  text,
  markdown,
  image,
  binary;

  String get label => switch (this) {
    DeskFileKind.text => '文本',
    DeskFileKind.markdown => 'Markdown',
    DeskFileKind.image => '图片',
    DeskFileKind.binary => '文件',
  };
}

const _imageExts = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

const _textExts = {
  '.txt',
  '.json',
  '.yaml',
  '.yml',
  '.csv',
  '.log',
  '.dart',
  '.js',
  '.ts',
  '.tsx',
  '.html',
  '.css',
  '.py',
  '.go',
  '.rs',
  '.java',
  '.kt',
  '.swift',
  '.sh',
  '.ps1',
};
