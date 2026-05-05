import 'dart:convert';
import 'package:dio/dio.dart';

/// SSE 流式 `data: ` 行解析器。
///
/// 防 N-BUG-1（详见 flutter-migration-plan/04-BUG甄别与重写策略.md §4.13）：
/// dio 流式响应按 TCP chunk 给，可能在 SSE event 中间切断。这里跨 chunk 累积，
/// 遇到 `\n` 边界才输出一行；空行作为 event 分隔符可由调用方自己判断。
Stream<String> sseDataLines(Response<ResponseBody> resp) async* {
  final stream = resp.data!.stream;
  final buffer = StringBuffer();
  await for (final chunk in stream) {
    buffer.write(utf8.decode(chunk, allowMalformed: true));
    while (true) {
      final str = buffer.toString();
      final idx = str.indexOf('\n');
      if (idx < 0) break;
      final line = str.substring(0, idx);
      buffer
        ..clear()
        ..write(str.substring(idx + 1));
      if (line.startsWith('data: ')) yield line.substring(6).trimRight();
    }
  }
}
