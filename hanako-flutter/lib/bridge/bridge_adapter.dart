/// Bridge 适配器抽象。每个外部平台一个实现。
abstract class BridgeAdapter {
  String get platform; // 'lark' / 'feishu' / 'qq'
  Stream<IncomingMessage> get messages;
  Future<BridgeResult> send(OutgoingMessage msg);
  Future<void> dispose();
}

class IncomingMessage {
  final String userId;
  final String? userName;
  final String? chatId;
  final String text;
  final DateTime ts;
  final Map<String, dynamic> raw;
  const IncomingMessage({
    required this.userId,
    this.userName,
    this.chatId,
    required this.text,
    required this.ts,
    this.raw = const {},
  });
}

class OutgoingMessage {
  final String chatId;
  final String text;
  final Map<String, dynamic>? extra;
  const OutgoingMessage({
    required this.chatId,
    required this.text,
    this.extra,
  });
}

/// 显式 Result 类型——规避 BUG-4 静默失败。
sealed class BridgeResult {
  const BridgeResult();
}

class BridgeSuccess extends BridgeResult {
  final String messageId;
  const BridgeSuccess(this.messageId);
}

class BridgeError extends BridgeResult {
  final String reason;
  final String? remoteCode;
  const BridgeError(this.reason, {this.remoteCode});
}
