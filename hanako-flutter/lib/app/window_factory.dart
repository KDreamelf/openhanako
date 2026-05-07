import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

import '../ui/settings/settings_window.dart';

/// 桌面窗口工厂。
///
/// 设置页直接在主窗口内打开，避免 settings 子 Engine 无法访问主窗口
/// ProviderScope 导致空白窗口或关闭崩溃。编辑器、浏览器仍保留多窗口形态。
class WindowFactory {
  WindowFactory._();

  static bool _settingsRouteOpen = false;

  static Future<void> openSettings(
    BuildContext context, {
    String? section,
  }) async {
    if (_settingsRouteOpen) return;
    _settingsRouteOpen = true;
    try {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SettingsWindow()));
    } finally {
      _settingsRouteOpen = false;
    }
  }

  static Future<int> openEditor({required String filePath}) async {
    final win = await DesktopMultiWindow.createWindow(
      jsonEncode({'route': 'editor', 'filePath': filePath}),
    );
    win
      ..setFrame(const Offset(160, 160) & const Size(1100, 700))
      ..setTitle('编辑 · 幻宙01')
      ..show();
    return win.windowId;
  }

  static Future<int> openBrowser({required String url}) async {
    final win = await DesktopMultiWindow.createWindow(
      jsonEncode({'route': 'browser', 'url': url}),
    );
    win
      ..setFrame(const Offset(200, 200) & const Size(1100, 800))
      ..setTitle('浏览器 · 幻宙01')
      ..show();
    return win.windowId;
  }
}
