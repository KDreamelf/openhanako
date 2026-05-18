import '../bridge/lark_bridge.dart';
import 'bridge_session_manager.dart';
import 'preferences_manager.dart';

class BridgeSourceManager {
  BridgeSourceManager({
    required this.preferences,
    required this.bridgeSessionManager,
  });

  final PreferencesManager preferences;
  final BridgeSessionManager bridgeSessionManager;

  final _statuses = <String, BridgeSourceStatus>{};

  List<BridgeSourceConfig> listSources() =>
      _platforms.map(_readConfig).toList(growable: false);

  BridgeSourceStatus status(String platform) =>
      _statuses[platform] ??
      BridgeSourceStatus(
        platform: platform,
        state: _readConfig(platform).enabled ? 'disconnected' : 'disabled',
      );

  Map<String, BridgeSourceStatus> statuses() => {
    for (final platform in _platforms) platform: status(platform),
  };

  Future<void> save(BridgeSourceConfig config) async {
    final normalized = config.normalized();
    _writeConfig(normalized);
    if (normalized.enabled) {
      await start(normalized.platform);
    } else {
      await stop(normalized.platform);
    }
  }

  Future<void> setEnabled(String platform, bool enabled) async {
    final config = _readConfig(platform).copyWith(enabled: enabled);
    await save(config);
  }

  Future<void> delete(String platform) async {
    final prefs = preferences.getPreferences();
    final bridge = _bridgePrefs(prefs);
    bridge.remove(platform);
    prefs['bridge'] = bridge;
    preferences.savePreferences(prefs);
    await stop(platform);
  }

  Future<void> startEnabled() async {
    for (final config in listSources()) {
      if (!config.enabled) continue;
      await start(config.platform);
    }
  }

  Future<void> start(String platform) async {
    final config = _readConfig(platform).normalized();
    try {
      if (!config.configured) {
        throw StateError('${config.label} 缺少必要凭证');
      }
      switch (config.platform) {
        case 'feishu':
        case 'lark':
          final adapter = LarkBridge(
            appId: config.credentials['appId'] ?? '',
            appSecret: config.credentials['appSecret'] ?? '',
            verificationToken: config.credentials['verificationToken'],
            encryptKey: config.credentials['encryptKey'],
          );
          await bridgeSessionManager.register(adapter);
          _statuses[platform] = BridgeSourceStatus(
            platform: platform,
            state: 'connected',
          );
        case 'qq':
          _statuses[platform] = const BridgeSourceStatus(
            platform: 'qq',
            state: 'error',
            error: 'QQ 当前只保存配置；运行 adapter 尚未接入 Flutter 客户端。',
          );
        default:
          throw ArgumentError.value(platform, 'platform', 'unknown platform');
      }
    } catch (e) {
      _statuses[platform] = BridgeSourceStatus(
        platform: platform,
        state: 'error',
        error: e.toString(),
      );
    }
  }

  Future<void> stop(String platform) async {
    await bridgeSessionManager.unregister(platform);
    _statuses[platform] = BridgeSourceStatus(
      platform: platform,
      state: 'disabled',
    );
  }

  BridgeSourceConfig _readConfig(String platform) {
    final prefs = preferences.getPreferences();
    final bridge = _bridgePrefs(prefs);
    final raw = bridge[platform];
    final map = raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};
    final credentials = <String, String>{};
    for (final entry in map.entries) {
      if (const {'enabled', 'agentId'}.contains(entry.key)) continue;
      final value = entry.value?.toString() ?? '';
      if (value.trim().isNotEmpty) credentials[entry.key] = value.trim();
    }
    return BridgeSourceConfig(
      platform: platform,
      enabled: map['enabled'] == true,
      agentId: map['agentId']?.toString(),
      credentials: credentials,
    );
  }

  void _writeConfig(BridgeSourceConfig config) {
    final prefs = preferences.getPreferences();
    final bridge = _bridgePrefs(prefs);
    bridge[config.platform] = {
      'enabled': config.enabled,
      if (config.agentId != null && config.agentId!.trim().isNotEmpty)
        'agentId': config.agentId!.trim(),
      ...config.credentials,
    };
    prefs['bridge'] = bridge;
    preferences.savePreferences(prefs);
  }

  Map<String, dynamic> _bridgePrefs(Map<String, dynamic> prefs) {
    final raw = prefs['bridge'];
    if (raw is Map) return raw.cast<String, dynamic>();
    return <String, dynamic>{};
  }
}

class BridgeSourceConfig {
  const BridgeSourceConfig({
    required this.platform,
    this.enabled = false,
    this.agentId,
    this.credentials = const {},
  });

  final String platform;
  final bool enabled;
  final String? agentId;
  final Map<String, String> credentials;

  String get label => switch (platform) {
    'feishu' || 'lark' => '飞书/Lark',
    'qq' => 'QQ',
    _ => platform,
  };

  bool get configured => switch (platform) {
    'feishu' || 'lark' =>
      (credentials['appId'] ?? '').isNotEmpty &&
          (credentials['appSecret'] ?? '').isNotEmpty,
    'qq' =>
      (credentials['appID'] ?? '').isNotEmpty &&
          ((credentials['appSecret'] ?? '').isNotEmpty ||
              (credentials['token'] ?? '').isNotEmpty),
    _ => false,
  };

  BridgeSourceConfig normalized() {
    final cleanCreds = <String, String>{};
    for (final entry in credentials.entries) {
      final value = entry.value.trim();
      if (value.isNotEmpty) cleanCreds[entry.key] = value;
    }
    return BridgeSourceConfig(
      platform: platform == 'lark' ? 'feishu' : platform,
      enabled: enabled,
      agentId: agentId?.trim().isEmpty == true ? null : agentId?.trim(),
      credentials: cleanCreds,
    );
  }

  BridgeSourceConfig copyWith({
    bool? enabled,
    String? agentId,
    Map<String, String>? credentials,
  }) => BridgeSourceConfig(
    platform: platform,
    enabled: enabled ?? this.enabled,
    agentId: agentId ?? this.agentId,
    credentials: credentials ?? this.credentials,
  );

  Map<String, dynamic> toJson() => {
    'platform': platform,
    'label': label,
    'enabled': enabled,
    'configured': configured,
    if (agentId != null) 'agentId': agentId,
    'credentials': credentials,
  };
}

class BridgeSourceStatus {
  const BridgeSourceStatus({
    required this.platform,
    required this.state,
    this.error,
  });

  final String platform;
  final String state; // connected / disconnected / disabled / error
  final String? error;

  Map<String, dynamic> toJson() => {
    'platform': platform,
    'state': state,
    if (error != null) 'error': error,
  };
}

const _platforms = ['feishu', 'qq'];
