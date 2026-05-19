import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/runtime_session_store.dart';
import 'experience_store.dart';

class ExperienceSessionCapture {
  const ExperienceSessionCapture._();

  static Future<ExperienceSaveResult> saveSessionAsPrivateExperience({
    required Directory agentDir,
    required String sessionPath,
    required String title,
    String brief = '',
    List<String> keywords = const [],
    int maxMessages = 0,
    DateTime? now,
  }) async {
    final draft = buildDraftFromSession(
      sessionPath: sessionPath,
      maxMessages: maxMessages,
    );
    if (draft.conversation.trim().isEmpty) {
      throw StateError('当前会话没有可写入经验的上下文');
    }
    return ExperienceStore(agentDir: agentDir).savePrivateExperience(
      title: title,
      brief: brief,
      keywords: keywords,
      conversation: draft.conversation,
      events: draft.events,
      sourceType: 'current_session',
      sourceSessionPath: sessionPath,
      toolFiles: draft.toolFiles,
      attachmentFiles: draft.attachmentFiles,
      now: now,
    );
  }

  static Future<ExperienceSaveResult> overwritePrivateExperienceFromSession({
    required Directory agentDir,
    required String experienceId,
    required String sessionPath,
    required String title,
    String brief = '',
    List<String> keywords = const [],
    int maxMessages = 0,
    DateTime? now,
  }) async {
    final draft = buildDraftFromSession(
      sessionPath: sessionPath,
      maxMessages: maxMessages,
    );
    if (draft.conversation.trim().isEmpty) {
      throw StateError('当前会话没有可写入经验的上下文');
    }
    return ExperienceStore(agentDir: agentDir).overwritePrivateExperience(
      experienceId: experienceId,
      title: title,
      brief: brief,
      keywords: keywords,
      conversation: draft.conversation,
      events: draft.events,
      sourceType: 'current_session',
      sourceSessionPath: sessionPath,
      toolFiles: draft.toolFiles,
      attachmentFiles: draft.attachmentFiles,
      now: now,
    );
  }

  static ExperienceSessionDraft buildDraftFromSession({
    required String sessionPath,
    int maxMessages = 0,
  }) {
    final file = File(sessionPath);
    if (!file.existsSync()) {
      throw StateError('会话文件不存在：$sessionPath');
    }
    final messages = RuntimeSessionStore.loadDisplayMessages(sessionPath);
    final selected = maxMessages > 0 && messages.length > maxMessages
        ? messages.sublist(messages.length - maxMessages)
        : messages;
    final conversation = StringBuffer();
    final events = StringBuffer()..writeln('# 工具调用索引\n');
    final ctx = _CaptureContext();
    var hasToolEvent = false;
    for (var i = 0; i < selected.length; i++) {
      final messageNo = i + 1;
      final message = selected[i];
      final role = switch (message.role) {
        'user' => '用户',
        'assistant' => 'AI',
        _ => message.role,
      };
      final parts = <String>[];
      for (final block in message.blocks) {
        switch (block) {
          case RuntimeDisplayTextBlock(:final text):
            if (text.trim().isNotEmpty) parts.add(text.trim());
          case RuntimeDisplayImageBlock():
            final imageRef = ctx.captureImageBlock(
              block,
              prefix: 'm${_pad(messageNo)}-image',
            );
            if (imageRef.trim().isNotEmpty) parts.add(imageRef);
          case RuntimeDisplayFileBlock(:final label, :final path):
            parts.add('[文件：$label]\n$path');
          case RuntimeDisplayLinkBlock(:final label, :final url):
            parts.add('[链接：$label]\n$url');
          case RuntimeDisplayThinkingBlock():
            break;
          case RuntimeDisplayToolCallBlock():
            final event = ctx.captureToolCall(
              block,
              messageNo: messageNo,
              role: role,
            );
            parts.add(
              '[工具调用 ${event.eventId}：${block.name}](../tool-calls/${event.relativePath})',
            );
            events
              ..writeln(
                '## ${event.eventId} · 消息 $messageNo · $role · ${block.name}',
              )
              ..writeln()
              ..writeln('- 状态：${block.resultIsError ? "失败" : "成功"}')
              ..writeln(
                '- 详情文件：[${event.relativePath}](../tool-calls/${event.relativePath})',
              )
              ..writeln();
            hasToolEvent = true;
          case RuntimeDisplayCompactBoundaryBlock():
            break;
        }
      }
      if (parts.isNotEmpty) {
        conversation
          ..writeln('## $messageNo. $role')
          ..writeln()
          ..writeln(parts.join('\n\n'))
          ..writeln();
      }
    }
    return ExperienceSessionDraft(
      conversation: conversation.toString().trimRight(),
      events: hasToolEvent ? events.toString().trimRight() : '无工具事件记录。',
      toolFiles: ctx.toolFiles,
      attachmentFiles: ctx.attachmentFiles,
    );
  }
}

class ExperienceSessionDraft {
  const ExperienceSessionDraft({
    required this.conversation,
    required this.events,
    this.toolFiles = const [],
    this.attachmentFiles = const [],
  });

  final String conversation;
  final String events;
  final List<ExperienceRawFile> toolFiles;
  final List<ExperienceRawFile> attachmentFiles;
}

class _ToolCaptureRef {
  const _ToolCaptureRef({required this.eventId, required this.relativePath});

  final String eventId;
  final String relativePath;
}

class _CaptureContext {
  final toolFiles = <ExperienceRawFile>[];
  final attachmentFiles = <ExperienceRawFile>[];
  var _toolSeq = 0;
  var _attachmentSeq = 0;

  _ToolCaptureRef captureToolCall(
    RuntimeDisplayToolCallBlock block, {
    required int messageNo,
    required String role,
  }) {
    _toolSeq++;
    final eventId = 't${_pad(_toolSeq)}';
    final safeName = _safeFilePart(block.name);
    final relativePath = '$eventId-m${_pad(messageNo)}-$safeName.md';
    final result = _materializeImagesInText(
      block.resultContent?.trim() ?? '',
      prefix: '$eventId-result',
    );
    final details = block.resultDetails == null
        ? ''
        : _materializeImagesInText(
            const JsonEncoder.withIndent('  ').convert(block.resultDetails),
            prefix: '$eventId-details',
          );
    final body = StringBuffer()
      ..writeln('# $eventId · ${block.name}')
      ..writeln()
      ..writeln('- 对话消息：$messageNo')
      ..writeln('- 角色：$role')
      ..writeln('- 工具调用 ID：${block.id}')
      ..writeln('- 状态：${block.resultIsError ? "失败" : "成功"}')
      ..writeln()
      ..writeln('## 参数')
      ..writeln()
      ..writeln('```json')
      ..writeln(_prettyJson(block.argsJson))
      ..writeln('```')
      ..writeln()
      ..writeln('## 返回')
      ..writeln()
      ..writeln(result.trim().isEmpty ? '无返回正文。' : result.trimRight());
    if (details.trim().isNotEmpty) {
      body
        ..writeln()
        ..writeln()
        ..writeln('## 结构化详情')
        ..writeln()
        ..writeln(details.trimRight());
    }
    toolFiles.add(ExperienceRawFile.text(relativePath, body.toString()));
    return _ToolCaptureRef(eventId: eventId, relativePath: relativePath);
  }

  String captureImageBlock(
    RuntimeDisplayImageBlock block, {
    required String prefix,
  }) {
    final label = block.label?.trim().isNotEmpty == true
        ? block.label!.trim()
        : '图片';
    final dataUrl = block.dataUrl?.trim();
    if (dataUrl != null && dataUrl.isNotEmpty) {
      final image = _decodeDataImage(dataUrl);
      if (image != null) {
        return _writeImageMarkdown(
          image.bytes,
          extension: image.extension,
          label: label,
          prefix: prefix,
        );
      }
    }
    final path = block.path?.trim();
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      final bytes = File(path).readAsBytesSync();
      return _writeImageMarkdown(
        bytes,
        extension:
            _imageExtensionFromPath(path) ?? _imageExtensionFromBytes(bytes),
        label: label,
        prefix: prefix,
      );
    }
    final imageUrl = block.imageUrl?.trim();
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return '![$label]($imageUrl)';
    }
    return '[图片：$label]';
  }

  String _materializeImagesInText(String text, {required String prefix}) {
    if (text.trim().isEmpty) return '';
    final decoded = _tryDecodeJson(text);
    if (decoded != null) {
      final markdownRefs = <String>[];
      final transformed = _materializeJsonImages(
        decoded,
        prefix: prefix,
        keyName: '',
        markdownRefs: markdownRefs,
      );
      final out = StringBuffer()
        ..writeln(
          const JsonEncoder.withIndent('  ').convert(transformed).trimRight(),
        );
      if (markdownRefs.isNotEmpty) {
        out
          ..writeln()
          ..writeln('### 图片附件')
          ..writeln();
        for (final ref in markdownRefs) {
          out.writeln(ref);
        }
      }
      return out.toString().trimRight();
    }
    var imageIndex = 0;
    return text.replaceAllMapped(_dataImagePattern, (match) {
      imageIndex++;
      final mime = match.group(1) ?? 'png';
      final payload = match.group(2) ?? '';
      final bytes = _decodeBase64(payload);
      if (bytes == null) return match.group(0) ?? '';
      return _writeImageMarkdown(
        bytes,
        extension: _extensionFromMimePart(mime),
        label: '$prefix-$imageIndex',
        prefix: prefix,
      );
    });
  }

  Object? _materializeJsonImages(
    Object? value, {
    required String prefix,
    required String keyName,
    required List<String> markdownRefs,
  }) {
    if (value is Map) {
      return value.map(
        (key, child) => MapEntry(
          key.toString(),
          _materializeJsonImages(
            child,
            prefix: prefix,
            keyName: key.toString(),
            markdownRefs: markdownRefs,
          ),
        ),
      );
    }
    if (value is List) {
      return [
        for (var i = 0; i < value.length; i++)
          _materializeJsonImages(
            value[i],
            prefix: '$prefix-${i + 1}',
            keyName: keyName,
            markdownRefs: markdownRefs,
          ),
      ];
    }
    if (value is String) {
      final dataImage = _decodeDataImage(value);
      if (dataImage != null) {
        final ref = _writeImageMarkdown(
          dataImage.bytes,
          extension: dataImage.extension,
          label: prefix,
          prefix: prefix,
        );
        markdownRefs.add(ref);
        return ref;
      }
      if (_looksLikeImageBase64(keyName, value)) {
        final bytes = _decodeBase64(value);
        if (bytes != null) {
          final ref = _writeImageMarkdown(
            bytes,
            extension: _imageExtensionFromBytes(bytes),
            label: prefix,
            prefix: prefix,
          );
          markdownRefs.add(ref);
          return ref;
        }
      }
    }
    return value;
  }

  String _writeImageMarkdown(
    Uint8List bytes, {
    required String extension,
    required String label,
    required String prefix,
  }) {
    _attachmentSeq++;
    final cleanExt = extension.trim().replaceFirst('.', '').toLowerCase();
    final filename =
        '${_safeFilePart(prefix)}-${_pad(_attachmentSeq)}.$cleanExt';
    attachmentFiles.add(
      ExperienceRawFile(relativePath: filename, bytes: bytes),
    );
    return '![$label](../attachments/$filename)';
  }
}

final _dataImagePattern = RegExp(
  r'data:image/([a-zA-Z0-9.+-]+);base64,([A-Za-z0-9+/=_-]+)',
);

Object? _tryDecodeJson(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return null;
  try {
    return jsonDecode(trimmed);
  } catch (_) {
    return null;
  }
}

String _prettyJson(String raw) {
  final decoded = _tryDecodeJson(raw);
  if (decoded == null) return raw.trim().isEmpty ? '{}' : raw.trim();
  return const JsonEncoder.withIndent('  ').convert(decoded);
}

_DecodedImage? _decodeDataImage(String text) {
  final match = _dataImagePattern.firstMatch(text.trim());
  if (match == null || match.group(0) != text.trim()) return null;
  final bytes = _decodeBase64(match.group(2) ?? '');
  if (bytes == null) return null;
  return _DecodedImage(
    bytes: bytes,
    extension: _extensionFromMimePart(match.group(1) ?? 'png'),
  );
}

Uint8List? _decodeBase64(String value) {
  final compact = value.trim().replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return null;
  var normalized = compact.replaceAll('-', '+').replaceAll('_', '/');
  final missingPadding = normalized.length % 4;
  if (missingPadding != 0) {
    normalized = normalized.padRight(
      normalized.length + 4 - missingPadding,
      '=',
    );
  }
  try {
    return Uint8List.fromList(base64Decode(normalized));
  } catch (_) {
    return null;
  }
}

bool _looksLikeImageBase64(String keyName, String value) {
  final key = keyName.toLowerCase();
  if (!key.contains('image') && !key.contains('screenshot')) return false;
  if (!key.contains('base64') && !key.endsWith('_b64')) return false;
  return value.trim().length > 64;
}

String _extensionFromMimePart(String mimePart) {
  final value = mimePart.toLowerCase();
  if (value.contains('jpeg') || value.contains('jpg')) return 'jpg';
  if (value.contains('webp')) return 'webp';
  if (value.contains('gif')) return 'gif';
  return 'png';
}

String? _imageExtensionFromPath(String path) {
  final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
  if (['png', 'jpg', 'jpeg', 'webp', 'gif'].contains(ext)) {
    return ext == 'jpeg' ? 'jpg' : ext;
  }
  return null;
}

String _imageExtensionFromBytes(Uint8List bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'jpg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'webp';
  }
  return 'png';
}

String _safeFilePart(String value) {
  final safe = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^[_\.-]+|[_\.-]+$'), '');
  return safe.isEmpty ? 'item' : safe;
}

String _pad(int value) => value.toString().padLeft(4, '0');

class _DecodedImage {
  const _DecodedImage({required this.bytes, required this.extension});

  final Uint8List bytes;
  final String extension;
}
