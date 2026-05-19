import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'p2p_message.dart';
import 'p2p_transport.dart';

/// BT 式 UDP 分片传输。
///
/// 发送端把完整字节拆成固定大小 chunk，每个 chunk 用 packageData 消息类型
/// 通过 P2pTransport 逐片发送；接收端按 chunkIndex 重组，全部到齐后返回
/// 完整字节。
///
/// chunk size 取 1200 bytes，远低于典型 MTU 1500，留出 UDP/IP 头 + P2pEnvelope
/// 头的空间，避免 IP 层分片。
class P2pChunkedTransfer {
  static const int chunkSize = 1200;

  /// 将完整字节拆成 chunk 列表。
  static List<P2pChunk> split(String transferId, Uint8List data) {
    final totalChunks = (data.length + chunkSize - 1) ~/ chunkSize;
    final hash = crypto.sha256.convert(data).toString();
    final chunks = <P2pChunk>[];
    for (var i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = start + chunkSize > data.length ? data.length : start + chunkSize;
      chunks.add(P2pChunk(
        transferId: transferId,
        packageHash: hash,
        chunkIndex: i,
        totalChunks: totalChunks,
        totalBytes: data.length,
        data: data.sublist(start, end),
      ));
    }
    return chunks;
  }

  /// 发送所有 chunk 到指定地址。
  static Future<void> sendAll(
    P2pTransport transport,
    List<P2pChunk> chunks,
    String host,
    int port, {
    Duration chunkDelay = const Duration(milliseconds: 2),
  }) async {
    for (final chunk in chunks) {
      transport.sendTo(
        P2pEnvelope(type: P2pMessageType.packageData, payload: chunk.toJson()),
        host,
        port,
      );
      if (chunkDelay.inMicroseconds > 0) {
        await Future<void>.delayed(chunkDelay);
      }
    }
  }
}

class P2pChunk {
  const P2pChunk({
    required this.transferId,
    required this.packageHash,
    required this.chunkIndex,
    required this.totalChunks,
    required this.totalBytes,
    required this.data,
  });

  final String transferId;
  final String packageHash;
  final int chunkIndex;
  final int totalChunks;
  final int totalBytes;
  final Uint8List data;

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'packageHash': packageHash,
    'chunkIndex': chunkIndex,
    'totalChunks': totalChunks,
    'totalBytes': totalBytes,
    'data': data.toList(),
  };

  static P2pChunk? fromJson(Map<String, dynamic> json) {
    final transferId = json['transferId'];
    final packageHash = json['packageHash'];
    final chunkIndex = json['chunkIndex'];
    final totalChunks = json['totalChunks'];
    final totalBytes = json['totalBytes'];
    final rawData = json['data'];
    if (transferId is! String ||
        packageHash is! String ||
        chunkIndex is! int ||
        totalChunks is! int ||
        totalBytes is! int ||
        rawData is! List) {
      return null;
    }
    return P2pChunk(
      transferId: transferId,
      packageHash: packageHash,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      totalBytes: totalBytes,
      data: Uint8List.fromList(rawData.cast<int>()),
    );
  }
}

/// 接收端 chunk 重组器。
///
/// 每个 transferId 对应一个 assembler。收齐全部 chunk 后触发回调。
class P2pChunkAssembler {
  final Map<String, _PendingTransfer> _pending = {};

  static const _maxPendingAge = Duration(minutes: 5);

  bool hasExpected(String transferId) => _pending.containsKey(transferId);

  /// 注册一个传输接收。收齐后调 onComplete。
  void expect(String transferId, {required void Function(Uint8List data, String packageHash) onComplete}) {
    _pending[transferId] = _PendingTransfer(
      onComplete: onComplete,
      createdAt: DateTime.now(),
    );
  }

  /// 收到一个 chunk。如果传输完成返回 true。
  bool receive(P2pChunk chunk) {
    var transfer = _pending[chunk.transferId];
    if (transfer == null) {
      transfer = _PendingTransfer(
        onComplete: null,
        createdAt: DateTime.now(),
      );
      _pending[chunk.transferId] = transfer;
    }

    transfer.chunks[chunk.chunkIndex] = chunk;

    if (transfer.chunks.length >= chunk.totalChunks) {
      final assembled = _assemble(chunk.totalChunks, chunk.totalBytes, transfer.chunks);
      if (assembled != null) {
        final hash = crypto.sha256.convert(assembled).toString();
        if (hash == chunk.packageHash) {
          transfer.onComplete?.call(assembled, chunk.packageHash);
          _pending.remove(chunk.transferId);
          return true;
        }
      }
    }
    return false;
  }

  void cleanup() {
    final cutoff = DateTime.now().subtract(_maxPendingAge);
    _pending.removeWhere((_, t) => t.createdAt.isBefore(cutoff));
  }

  Uint8List? _assemble(int totalChunks, int totalBytes, Map<int, P2pChunk> chunks) {
    final buffer = BytesBuilder(copy: false);
    for (var i = 0; i < totalChunks; i++) {
      final chunk = chunks[i];
      if (chunk == null) return null;
      buffer.add(chunk.data);
    }
    final result = buffer.toBytes();
    if (result.length != totalBytes) return null;
    return result;
  }
}

class _PendingTransfer {
  _PendingTransfer({required this.onComplete, required this.createdAt});

  final void Function(Uint8List data, String packageHash)? onComplete;
  final DateTime createdAt;
  final Map<int, P2pChunk> chunks = {};
}
