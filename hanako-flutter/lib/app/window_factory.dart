import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

/// 子窗口工厂。
/// 参考 flutter-migration-plan/02-多窗口实现方案.md：每个子窗口独立 Flutter
/// Engine / Isolate，业务调用通过 IPC `business.invoke` 走主窗口。
class WindowFactory {
  WindowFactory._();

  static Future<int> openSettings({String? section}) async {
    final win = await DesktopMultiWindow.createWindow(jsonEncode({
      'route': 'settings',
      if (section != null) 'section': section,
    }));
    win
      ..setFrame(const Offset(120, 120) & const Size(960, 720))
      ..setTitle('设置 · Hanako')
      ..center()
      ..show();
    return win.windowId;
  }

  static Future<int> openEditor({required String filePath}) async {
    final win = await DesktopMultiWindow.createWindow(jsonEncode({
      'route': 'editor',
      'filePath': filePath,
    }));
    win
      ..setFrame(const Offset(160, 160) & const Size(1100, 700))
      ..setTitle('编辑 · Hanako')
      ..show();
    return win.windowId;
  }

  static Future<int> openBrowser({required String url}) async {
    final win = await DesktopMultiWindow.createWindow(jsonEncode({
      'route': 'browser',
      'url': url,
    }));
    win
      ..setFrame(const Offset(200, 200) & const Size(1100, 800))
      ..setTitle('浏览器 · Hanako')
      ..show();
    return win.windowId;
  }
}
