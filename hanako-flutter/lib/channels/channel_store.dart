import 'dart:io';

import 'package:path/path.dart' as p;

/// 与 legacy lib/channels/channel-store.js 对齐：channel `.md` 文件读写。
///
/// 文件名约定：`ch_{id}.md`
/// Frontmatter（顶部用 `---` 包围）：
///   id: ch_xxx
///   name: ...
///   description: ...
///   members: [a, b, c]
///
/// 消息格式（每条单独一段）：
///   ### {sender} | {YYYY-MM-DD HH:mm:ss}
///   <message body>
///   ---
class ChannelStore {
  ChannelStore(this.channelsDir);
  final Directory channelsDir;

  static final _msgHeaderRe =
      RegExp(r'^### (.+?) \| (\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2})?)$');

  Directory get _dir {
    if (!channelsDir.existsSync()) channelsDir.createSync(recursive: true);
    return channelsDir;
  }

  File _file(String channelId) {
    final id = channelId.startsWith('ch_') ? channelId : 'ch_$channelId';
    return File(p.join(_dir.path, '$id.md'));
  }

  /// 列出所有频道。
  List<ChannelMeta> listChannels() {
    if (!_dir.existsSync()) return const [];
    final out = <ChannelMeta>[];
    for (final f in _dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.md')) continue;
      try {
        final meta = readMeta(p.basenameWithoutExtension(f.path));
        if (meta != null) out.add(meta);
      } catch (_) {}
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  /// 创建频道。
  ChannelMeta create({
    String? id,
    String? name,
    String? description,
    List<String> members = const [],
    String? intro,
  }) {
    final channelId = id != null
        ? (id.startsWith('ch_') ? id : 'ch_$id')
        : _generateId();
    final f = _file(channelId);
    if (f.existsSync()) {
      throw StateError('频道 $channelId 已存在');
    }
    final meta = ChannelMeta(
      id: channelId,
      name: name,
      description: description,
      members: members,
    );
    final parts = <String>[
      _serializeFrontmatter(meta),
      '',
    ];
    if (intro != null && intro.isNotEmpty) {
      parts.addAll([
        '### system | ${_formatTs(DateTime.now())}',
        '',
        intro,
        '',
        '---',
        '',
      ]);
    }
    f.writeAsStringSync(parts.join('\n'), flush: true);
    return meta;
  }

  /// 删除频道。
  bool delete(String channelId) {
    final f = _file(channelId);
    if (f.existsSync()) {
      f.deleteSync();
      return true;
    }
    return false;
  }

  ChannelMeta? readMeta(String channelId) {
    final f = _file(channelId);
    if (!f.existsSync()) return null;
    final src = f.readAsStringSync();
    return _parseFrontmatter(src);
  }

  /// 追加一条消息。
  void appendMessage(String channelId, String sender, String body,
      {DateTime? ts}) {
    final f = _file(channelId);
    if (!f.existsSync()) {
      throw StateError('频道 $channelId 不存在');
    }
    final time = _formatTs(ts ?? DateTime.now());
    final block = '### $sender | $time\n\n$body\n\n---\n\n';
    final raf = f.openSync(mode: FileMode.append);
    try {
      raf.writeStringSync(block);
    } finally {
      raf.closeSync();
    }
  }

  /// 读取最近 N 条消息（按发送顺序），可选传入 since（时间戳过滤）。
  List<ChannelMessage> readRecent(String channelId,
      {int limit = 50, DateTime? since}) {
    final f = _file(channelId);
    if (!f.existsSync()) return const [];
    final src = f.readAsStringSync();
    // 跳过 frontmatter
    final body = _stripFrontmatter(src);
    final blocks = body.split(RegExp(r'\n---\n'));
    final out = <ChannelMessage>[];
    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.isEmpty) continue;
      final m = _msgHeaderRe.firstMatch(lines.first.trim());
      if (m == null) continue;
      final sender = m.group(1)!;
      final tsStr = m.group(2)!;
      final ts = _parseTs(tsStr);
      if (since != null && ts != null && ts.isBefore(since)) continue;
      final msgBody = lines.skip(1).join('\n').trim();
      out.add(ChannelMessage(
        sender: sender,
        timestamp: ts,
        body: msgBody,
      ));
    }
    if (out.length > limit) {
      return out.sublist(out.length - limit);
    }
    return out;
  }

  /// 移除某 agent 在所有频道的成员身份。
  void cleanupAgentFromAllChannels(String agentId) {
    for (final f in _dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.md')) continue;
      try {
        final src = f.readAsStringSync();
        final meta = _parseFrontmatter(src);
        if (meta == null || !meta.members.contains(agentId)) continue;
        final newMembers =
            meta.members.where((m) => m != agentId).toList();
        final updated = meta.copyWith(members: newMembers);
        final body = _stripFrontmatter(src);
        f.writeAsStringSync(
          '${_serializeFrontmatter(updated)}\n$body',
          flush: true,
        );
      } catch (_) {}
    }
  }

  // -- internals --

  String _generateId() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return 'ch_$ts';
  }

  String _formatTs(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  DateTime? _parseTs(String s) {
    try {
      // YYYY-MM-DD HH:mm[:ss]
      final parts = s.split(' ');
      final dateP = parts[0].split('-');
      final timeP = parts[1].split(':');
      return DateTime(
        int.parse(dateP[0]),
        int.parse(dateP[1]),
        int.parse(dateP[2]),
        int.parse(timeP[0]),
        int.parse(timeP[1]),
        timeP.length > 2 ? int.parse(timeP[2]) : 0,
      );
    } catch (_) {
      return null;
    }
  }

  String _serializeFrontmatter(ChannelMeta meta) {
    final lines = <String>['---', 'id: ${meta.id}'];
    if (meta.name != null) lines.add('name: ${meta.name}');
    if (meta.description != null) lines.add('description: ${meta.description}');
    if (meta.members.isNotEmpty) {
      lines.add('members: [${meta.members.join(", ")}]');
    } else {
      lines.add('members: []');
    }
    lines.add('---');
    return lines.join('\n');
  }

  ChannelMeta? _parseFrontmatter(String src) {
    final m = RegExp(r'^---\s*\n([\s\S]*?)\n---\s*\n').firstMatch(src);
    if (m == null) return null;
    final fm = m.group(1)!;
    final result = <String, Object>{};
    for (final line in fm.split('\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final k = line.substring(0, colon).trim();
      var v = line.substring(colon + 1).trim();
      if (v.startsWith('[') && v.endsWith(']')) {
        result[k] = v
            .substring(1, v.length - 1)
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      } else {
        result[k] = v;
      }
    }
    final id = result['id'] as String?;
    if (id == null) return null;
    return ChannelMeta(
      id: id,
      name: result['name'] as String?,
      description: result['description'] as String?,
      members: (result['members'] as List?)?.cast<String>() ?? const [],
    );
  }

  String _stripFrontmatter(String src) {
    final m = RegExp(r'^---\s*\n[\s\S]*?\n---\s*\n').firstMatch(src);
    if (m == null) return src;
    return src.substring(m.end);
  }
}

class ChannelMeta {
  final String id;
  final String? name;
  final String? description;
  final List<String> members;
  const ChannelMeta({
    required this.id,
    this.name,
    this.description,
    this.members = const [],
  });

  ChannelMeta copyWith({
    String? name,
    String? description,
    List<String>? members,
  }) =>
      ChannelMeta(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        members: members ?? this.members,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        'members': members,
      };
}

class ChannelMessage {
  final String sender;
  final DateTime? timestamp;
  final String body;
  const ChannelMessage({
    required this.sender,
    this.timestamp,
    required this.body,
  });

  Map<String, dynamic> toJson() => {
        'sender': sender,
        if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
        'body': body,
      };
}
