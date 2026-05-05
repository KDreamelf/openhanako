// lib/bridge/bridge_identity_resolver.dart
//
// 外部 IM 用户身份解析器：把 (platform, externalUserId) 映射到 Hanako 身份。
//
// 当前形态：从本地 preferences.bridge.owner.{platform} 读出绑定 ID，命中即
// owner（子体主人本人），未命中即 guest（外部访客）。
//
// 终态形态（用户后端就位后）：调用户后端 API 按服务端绑定表返回。
// 子体登录后从后端拉用户在 Telegram / 飞书 / 微信等的所有绑定 ID，
// 缓存到本地，Bridge 进来时按这个表查。
//
// 这一层抽象的目的：
//   1. 标记"账号系统的边界"——所有 IM → Hanako 身份判断都走这里
//   2. 单元测试时可注入 mock，不依赖 PreferencesManager
//   3. 将来切换到远程实现时，BridgeSessionManager 不用改

import '../core/preferences_manager.dart';

/// 外部 IM 用户在 Hanako 系统内的身份范畴。
enum HanakoIdentityScope {
  /// 子体主人本人，享有完整工具集 + 私有上下文。
  owner,

  /// 外部访客，guest 模式（只读 / 受限工具集 / 不暴露私有 ishiki）。
  guest,
}

/// Bridge 入口的身份解析器。
abstract class BridgeIdentityResolver {
  /// 解析外部 IM 用户。
  ///
  /// 实现方应该是幂等且无副作用的；BridgeSessionManager 每条消息都会调一次。
  Future<HanakoIdentityScope> resolve({
    required String platform,
    required String externalUserId,
  });
}

/// 默认实现：从本地 preferences 读 `bridge.owner.{platform}` 字段判断 owner。
/// 与原 BridgeSessionManager._onIncoming 中的硬编码逻辑等价。
class PreferencesBridgeIdentityResolver implements BridgeIdentityResolver {
  PreferencesBridgeIdentityResolver(this.preferences);

  final PreferencesManager preferences;

  @override
  Future<HanakoIdentityScope> resolve({
    required String platform,
    required String externalUserId,
  }) async {
    final ownerCfg = preferences.get<Map>('bridge')?['owner'] as Map?;
    final ownerForPlatform = ownerCfg?[platform] as String?;
    final isOwner =
        ownerForPlatform != null && ownerForPlatform == externalUserId;
    return isOwner ? HanakoIdentityScope.owner : HanakoIdentityScope.guest;
  }
}

/// 占位：未来用户后端就位时的远程实现框架。当前不实装。
///
/// ```dart
/// class RemoteBridgeIdentityResolver implements BridgeIdentityResolver {
///   RemoteBridgeIdentityResolver(this.client, this.cache);
///
///   final HanakoBackendClient client;
///   final BridgeBindingCache cache;
///
///   @override
///   Future<HanakoIdentityScope> resolve({
///     required String platform,
///     required String externalUserId,
///   }) async {
///     // 1. 先查本地缓存
///     final cached = cache.lookup(platform, externalUserId);
///     if (cached != null) return cached;
///     // 2. 走后端 /api/bridge/lookup
///     final resp = await client.lookupBridgeBinding(
///       platform: platform,
///       externalUserId: externalUserId,
///     );
///     final scope = resp.bound ? HanakoIdentityScope.owner : HanakoIdentityScope.guest;
///     cache.put(platform, externalUserId, scope);
///     return scope;
///   }
/// }
/// ```
class RemoteBridgeIdentityResolver implements BridgeIdentityResolver {
  /// TODO: 等用户后端 / 私有 AI 网关上线后实装。
  @override
  Future<HanakoIdentityScope> resolve({
    required String platform,
    required String externalUserId,
  }) async {
    throw UnimplementedError(
      'RemoteBridgeIdentityResolver 等用户后端就位后再实装。'
      '当前请使用 PreferencesBridgeIdentityResolver。',
    );
  }
}
