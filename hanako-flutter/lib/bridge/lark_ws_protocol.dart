import 'dart:convert';
import 'dart:typed_data';

/// 飞书长连接 pbbp2 帧编解码器。
///
/// 手写 protobuf wire codec（方案 B），不引入 protoc 工具链。
/// 来源：从 `larksuite/oapi-sdk-go` v3_main `ws/pbbp2.pb.go` 反推。
///
/// Frame 结构（protobuf wire format）：
///   tag 1: uint32  FrameType  (0=Control, 1=Data)
///   tag 2: repeated Header { key:string(tag1), value:string(tag2) }
///   tag 3: bytes   Payload
///
/// Response 结构（上行 ack）：
///   tag 1: int32   StatusCode
///   tag 2: map<string,string> Headers
///   tag 3: bytes   Data

class LarkFrame {
  const LarkFrame({
    required this.frameType,
    this.headers = const {},
    this.payload = const [],
  });

  /// 0 = Control, 1 = Data
  final int frameType;
  final Map<String, String> headers;
  final List<int> payload;

  String? header(String key) => headers[key];
  String get type => headers['type'] ?? '';
  String get messageId => headers['message_id'] ?? '';
  int get sum => int.tryParse(headers['sum'] ?? '1') ?? 1;
  int get seq => int.tryParse(headers['seq'] ?? '0') ?? 0;
  String get traceId => headers['trace_id'] ?? headers['link_id'] ?? '';

  bool get isControl => frameType == 0;
  bool get isData => frameType == 1;
  bool get isPing => isControl && type == 'ping';
  bool get isPong => isControl && type == 'pong';

  Uint8List encode() {
    final buf = BytesBuilder();
    // tag 1: varint (FrameType)
    _writeVarintField(buf, 1, frameType);
    // tag 2: repeated Header (length-delimited)
    for (final entry in headers.entries) {
      final headerBytes = _encodeHeader(entry.key, entry.value);
      _writeLengthDelimitedField(buf, 2, headerBytes);
    }
    // tag 3: bytes (Payload)
    if (payload.isNotEmpty) {
      _writeLengthDelimitedField(buf, 3, Uint8List.fromList(payload));
    }
    return buf.toBytes();
  }

  static LarkFrame? decode(Uint8List data) {
    int frameType = 0;
    final headers = <String, String>{};
    Uint8List payload = Uint8List(0);

    int offset = 0;
    while (offset < data.length) {
      final tagResult = _readVarint(data, offset);
      if (tagResult == null) break;
      final tag = tagResult.value;
      offset = tagResult.nextOffset;
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x7;

      switch (fieldNumber) {
        case 1: // FrameType (varint)
          if (wireType != 0) return null;
          final vr = _readVarint(data, offset);
          if (vr == null) return null;
          frameType = vr.value;
          offset = vr.nextOffset;
        case 2: // Header (length-delimited)
          if (wireType != 2) return null;
          final lr = _readLengthDelimited(data, offset);
          if (lr == null) return null;
          final kv = _decodeHeader(lr.bytes);
          if (kv != null) headers[kv.key] = kv.value;
          offset = lr.nextOffset;
        case 3: // Payload (length-delimited)
          if (wireType != 2) return null;
          final lr = _readLengthDelimited(data, offset);
          if (lr == null) return null;
          payload = lr.bytes;
          offset = lr.nextOffset;
        default:
          // 未知字段：跳过
          if (wireType == 0) {
            final vr = _readVarint(data, offset);
            if (vr == null) return null;
            offset = vr.nextOffset;
          } else if (wireType == 2) {
            final lr = _readLengthDelimited(data, offset);
            if (lr == null) return null;
            offset = lr.nextOffset;
          } else {
            return null;
          }
      }
    }

    return LarkFrame(
      frameType: frameType,
      headers: headers,
      payload: payload,
    );
  }

  static LarkFrame ping() => const LarkFrame(
    frameType: 0,
    headers: {'type': 'ping'},
  );

  static LarkFrame pong() => const LarkFrame(
    frameType: 0,
    headers: {'type': 'pong'},
  );
}

class LarkResponse {
  const LarkResponse({
    this.statusCode = 0,
    this.headers = const {},
    this.data = const [],
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<int> data;

  Uint8List encode() {
    final buf = BytesBuilder();
    _writeVarintField(buf, 1, statusCode);
    for (final entry in headers.entries) {
      final mapEntry = _encodeMapEntry(entry.key, entry.value);
      _writeLengthDelimitedField(buf, 2, mapEntry);
    }
    if (data.isNotEmpty) {
      _writeLengthDelimitedField(buf, 3, Uint8List.fromList(data));
    }
    return buf.toBytes();
  }
}

// ---- protobuf wire helpers ----

Uint8List _encodeHeader(String key, String value) {
  final buf = BytesBuilder();
  _writeStringField(buf, 1, key);
  _writeStringField(buf, 2, value);
  return buf.toBytes();
}

MapEntry<String, String>? _decodeHeader(Uint8List data) {
  String? key;
  String? value;
  int offset = 0;
  while (offset < data.length) {
    final tagResult = _readVarint(data, offset);
    if (tagResult == null) break;
    offset = tagResult.nextOffset;
    final fieldNumber = tagResult.value >> 3;
    final wireType = tagResult.value & 0x7;
    if (wireType != 2) break;
    final lr = _readLengthDelimited(data, offset);
    if (lr == null) break;
    offset = lr.nextOffset;
    if (fieldNumber == 1) key = utf8.decode(lr.bytes, allowMalformed: true);
    if (fieldNumber == 2) value = utf8.decode(lr.bytes, allowMalformed: true);
  }
  if (key == null || value == null) return null;
  return MapEntry(key, value);
}

Uint8List _encodeMapEntry(String key, String value) {
  final buf = BytesBuilder();
  _writeStringField(buf, 1, key);
  _writeStringField(buf, 2, value);
  return buf.toBytes();
}

void _writeVarintField(BytesBuilder buf, int fieldNumber, int value) {
  _writeVarint(buf, (fieldNumber << 3) | 0);
  _writeVarint(buf, value);
}

void _writeStringField(BytesBuilder buf, int fieldNumber, String value) {
  final bytes = utf8.encode(value);
  _writeLengthDelimitedField(buf, fieldNumber, Uint8List.fromList(bytes));
}

void _writeLengthDelimitedField(BytesBuilder buf, int fieldNumber, Uint8List data) {
  _writeVarint(buf, (fieldNumber << 3) | 2);
  _writeVarint(buf, data.length);
  buf.add(data);
}

void _writeVarint(BytesBuilder buf, int value) {
  var v = value & 0xFFFFFFFF;
  while (v > 0x7F) {
    buf.addByte((v & 0x7F) | 0x80);
    v >>= 7;
  }
  buf.addByte(v & 0x7F);
}

_VarintResult? _readVarint(Uint8List data, int offset) {
  int value = 0;
  int shift = 0;
  while (offset < data.length) {
    final byte = data[offset++];
    value |= (byte & 0x7F) << shift;
    if ((byte & 0x80) == 0) {
      return _VarintResult(value, offset);
    }
    shift += 7;
    if (shift > 35) return null;
  }
  return null;
}

_LengthDelimitedResult? _readLengthDelimited(Uint8List data, int offset) {
  final lenResult = _readVarint(data, offset);
  if (lenResult == null) return null;
  final length = lenResult.value;
  final start = lenResult.nextOffset;
  if (start + length > data.length) return null;
  return _LengthDelimitedResult(
    Uint8List.sublistView(data, start, start + length),
    start + length,
  );
}

class _VarintResult {
  const _VarintResult(this.value, this.nextOffset);
  final int value;
  final int nextOffset;
}

class _LengthDelimitedResult {
  const _LengthDelimitedResult(this.bytes, this.nextOffset);
  final Uint8List bytes;
  final int nextOffset;
}
