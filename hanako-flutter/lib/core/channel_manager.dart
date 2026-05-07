import '../channels/channel_store.dart';
import '../shared/hana_home.dart';

/// ChannelManager 与 legacy core/channel-manager.js 对齐：
/// 频道 CRUD + 成员管理 + 消息追加 + 退群清理。
///
/// 注：频道文件读写仍保持轻量；自动 multi-agent triage 由协作运行时编排，
/// 避免 ChannelStore 直接依赖 LLM/runtime。
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
    String channelId,
    String sender,
    String body,
  ) async {
    store.appendMessage(channelId, sender, body);
  }

  /// 读取最近消息。
  Future<List<ChannelMessage>> readRecent(
    String channelId, {
    int limit = 50,
  }) async {
    return store.readRecent(channelId, limit: limit);
  }
}
