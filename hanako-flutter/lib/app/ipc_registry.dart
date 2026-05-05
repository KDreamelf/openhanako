import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

import '../core/engine.dart';

/// 主窗口 IPC handler 注册。
/// 子窗口通过 [DesktopMultiWindow.invokeMethod] 调用 `business.invoke` 触发。
class IpcRegistry {
  IpcRegistry(this.engine);
  final HanaEngine engine;

  void install() {
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      switch (call.method) {
        case 'business.invoke':
          final args = (call.arguments as Map).cast<String, dynamic>();
          final api = args['api'] as String;
          final payload = ((args['payload'] as Map?) ?? const {})
              .cast<String, dynamic>();
          return await _dispatch(api, payload);
        case 'bring_to_front':
          // 主窗口前置，由 main.dart 的 window_manager 处理；这里 no-op
          return null;
        default:
          throw MissingPluginException('Unknown IPC method: ${call.method}');
      }
    });
  }

  Future<Object?> _dispatch(String api, Map<String, dynamic> payload) async {
    switch (api) {
      case 'agents.list':
        final list = await engine.agentManager.listAgents();
        return list.map((a) => a.toJson()).toList();

      case 'agents.create':
        final a = await engine.agentManager.createAgent(
          name: payload['name'] as String,
          id: payload['id'] as String?,
          yuan: (payload['yuan'] as String?) ?? 'hanako',
        );
        return a.toJson();

      case 'agents.switch':
        await engine.agentManager.switchAgent(payload['id'] as String);
        engine.config.retarget(payload['id'] as String);
        return {'ok': true};

      case 'agents.delete':
        await engine.agentManager.deleteAgent(payload['id'] as String);
        return {'ok': true};

      case 'preferences.read':
        return engine.preferences.getPreferences();

      case 'preferences.write':
        engine.preferences.savePreferences(
          (payload['data'] as Map).cast<String, dynamic>(),
        );
        return {'ok': true};

      case 'sessions.list':
        final list = await engine.sessionCoordinator.listSessions();
        return list.map((e) => e.toJson()).toList();

      case 'config.read':
        return engine.config.read();

      case 'config.update':
        engine.config.updateConfig(
          (payload['data'] as Map).cast<String, dynamic>(),
        );
        return {'ok': true};

      case 'home.paths':
        return {
          'root': engine.home.root.path,
          'agentsDir': engine.home.agentsDir.path,
          'skillsDir': engine.home.skillsDir.path,
          'userDir': engine.home.userDir.path,
          'logsDir': engine.home.logsDir.path,
          'preferencesFile': engine.home.preferencesFile.path,
          'modelsJson': engine.home.modelsJson.path,
          'authJson': engine.home.authJson.path,
        };

      case 'runtime.info':
        return {
          'platform': Platform.operatingSystem,
          'platformVersion': Platform.operatingSystemVersion,
          'numberOfProcessors': Platform.numberOfProcessors,
          'localeName': Platform.localeName,
          'dartVersion': Platform.version,
        };

      default:
        throw ArgumentError('Unknown API: $api');
    }
  }
}
