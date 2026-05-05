import '../channels/channel_store.dart';
import '../shared/hana_home.dart';

/// ChannelManager 与 legacy core/channel-manager.js 对齐：
/// 频道 CRUD + 成员管理 + 消息追加 + 退群清理。
///
/// 注：legacy 的 ChannelTriage / Hub 自动判断回复机制**不在 Flutter 分支移植范围**。
/// 频道在 Flutter 端定位为「人 ↔ agent」单线对话的存档/记录形态，自动 multi-agent
/// triage 由调用方 / 外部 hub 工具自行实现。
class ChannelManager {
  ChannelManager(HanaHome home) : store = ChannelStore(home.channelsDir);

  final ChannelStore store;

  Future<List<ChannelMeta>> listChannels() async => store.listChannels();

  Future<ChannelMeta?> readChannel(String channelId) async =>
      store.readMeta(channelId);

  Future<ChannelMeta> createChannel({
    String? id,
    String? name,
    String? description,
    List<String> members = const [],
    String? intro,
  }) async {
    return store.create(
      id: id,
      name: name,
      description: description,
      members: members,
      intro: intro,
    );
  }

  Future<bool> deleteChannelByName(String channelId) async {
    return store.delete(channelId);
  }

  /// agent 删除时调用：从所有频道的 members 清掉该 agentId。
  Future<void> cleanupAgentFromChannels(String agentId) async {
    store.cleanupAgentFromAllChannels(agentId);
  }

  /// 追加消息（system / agent / user 都用这个）。
  Future<void> appendMessage(
      String channelId, String sender, String body) async {
    store.appendMessage(channelId, sender, body);
  }

  /// 读取最近消息。
  Future<List<ChannelMessage>> readRecent(String channelId,
      {int limit = 50}) async {
    return store.readRecent(channelId, limit: limit);
  }
}
