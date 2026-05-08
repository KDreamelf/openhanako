import 'dart:convert';
import 'dart:io';

/// Local JSONL diagnostics writer for production triage.
///
/// This logger is intentionally tiny and synchronous: it is used only for
/// bounded diagnostic events on critical flows, and it must never break the
/// user-facing operation if the log file cannot be written.
class DiagnosticsLog {
  DiagnosticsLog(this.file, {this.source});

  final File file;
  final String? source;

  void write(
    String event, {
    required String layer,
    Map<String, dynamic> fields = const {},
  }) {
    final payload = <String, dynamic>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'schema_version': 1,
      'layer': layer,
      'event': event,
      if (source != null && source!.isNotEmpty) 'source': source,
    };
    for (final entry in fields.entries) {
      final value = _jsonSafe(entry.value);
      if (value != null) payload[entry.key] = value;
    }
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${jsonEncode(payload)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Diagnostics must never interrupt login, recovery, chat, or tools.
    }
  }
}

Object? _jsonSafe(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Duration) return value.inMilliseconds;
  if (value is Iterable) {
    return value.map(_jsonSafe).where((item) => item != null).toList();
  }
  if (value is Map) {
    final out = <String, dynamic>{};
    for (final entry in value.entries) {
      final safe = _jsonSafe(entry.value);
      if (safe != null) out[entry.key.toString()] = safe;
    }
    return out;
  }
  return value.toString();
}
