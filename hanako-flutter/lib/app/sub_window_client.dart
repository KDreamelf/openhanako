import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 子窗口的 IPC 客户端：通过 [DesktopMultiWindow.invokeMethod] 调主窗口业务。
class SubWindowEngineClient {
  static Future<Object?> call(String api, {Map<String, dynamic>? payload}) {
    return DesktopMultiWindow.invokeMethod(0, 'business.invoke', {
      'api': api,
      'payload': payload ?? const {},
    });
  }

  static Future<List<Map<String, dynamic>>> listAgents() async {
    final raw = await call('agents.list');
    return (raw as List).cast<Map<String, dynamic>>();
  }

  static Future<List<Map<String, dynamic>>> listSessions() async {
    final raw = await call('sessions.list');
    return (raw as List).cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>> readPreferences() async {
    final raw = await call('preferences.read');
    return (raw as Map).cast<String, dynamic>();
  }

  static Future<void> writePreferences(Map<String, dynamic> data) async {
    await call('preferences.write', payload: {'data': data});
  }

  static Future<Map<String, dynamic>> readConfig() async {
    final raw = await call('config.read');
    return (raw as Map).cast<String, dynamic>();
  }

  static Future<Map<String, String>> homePaths() async {
    final raw = await call('home.paths');
    return (raw as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  static Future<Map<String, dynamic>> runtimeInfo() async {
    final raw = await call('runtime.info');
    return (raw as Map).cast<String, dynamic>();
  }
}

/// 仅在子窗口 ProviderScope 用：业务调用走 IPC 而不是直接 engine。
final subWindowClientProvider = Provider<SubWindowEngineClient>((_) {
  return SubWindowEngineClient();
});
