import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面集成：托盘 + 全局快捷键 + 主窗口默认值。
/// 参考 flutter-migration-plan/性能优化复盘-20260207.md §5.3 (Windows GPU)。
class DesktopSetup {
  DesktopSetup._();

  static final _DesktopLifecycle _lifecycle = _DesktopLifecycle();
  static bool _listenersInstalled = false;
  static bool _quitRequested = false;

  /// 在 runApp 之前调用，初始化主窗口默认值。
  static Future<void> initWindow() async {
    await windowManager.ensureInitialized();
    _installListeners();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1280, 800),
        minimumSize: Size(900, 600),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.normal,
        title: '幻宙01',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  /// 系统托盘。失败不阻塞。
  static Future<void> installTray({
    FutureOr<void> Function()? onOpenSettings,
  }) async {
    _lifecycle.onOpenSettings = onOpenSettings;
    try {
      final iconPath = Platform.isWindows
          ? 'windows/runner/resources/app_icon.ico'
          : 'assets/icons/app_icon.png';
      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('幻宙01');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show_main', label: '显示主窗口'),
            MenuItem(key: 'open_settings', label: '设置'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: '退出'),
          ],
        ),
      );
      await windowManager.setPreventClose(true);
    } catch (_) {
      // 托盘失败不阻塞启动
    }
  }

  static Future<void> showMainWindow() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  static Future<void> hideMainWindow() async {
    await windowManager.setSkipTaskbar(true);
    await windowManager.hide();
  }

  static Future<void> quitApp() async {
    if (_quitRequested) return;
    _quitRequested = true;
    if (Platform.isWindows) {
      exit(0);
    }
    try {
      await hotKeyManager.unregisterAll();
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    await windowManager.destroy();
  }

  /// 全局快捷键 Ctrl+Alt+= 快速切换模型（对齐 legacy 行为）。
  static Future<void> installHotkeys({
    required VoidCallback onQuickSwitchModel,
  }) async {
    try {
      await hotKeyManager.unregisterAll();
      await hotKeyManager.register(
        HotKey(
          key: PhysicalKeyboardKey.equal,
          modifiers: [HotKeyModifier.alt, HotKeyModifier.control],
          scope: HotKeyScope.system,
        ),
        keyDownHandler: (_) => onQuickSwitchModel(),
      );
    } catch (_) {
      // 部分平台/无权限时失败
    }
  }

  static void _installListeners() {
    if (_listenersInstalled) return;
    windowManager.addListener(_lifecycle);
    trayManager.addListener(_lifecycle);
    _listenersInstalled = true;
  }
}

class _DesktopLifecycle with WindowListener, TrayListener {
  FutureOr<void> Function()? onOpenSettings;

  @override
  void onWindowClose() {
    unawaited(_hideInsteadOfClose());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(DesktopSetup.showMainWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_main':
        unawaited(DesktopSetup.showMainWindow());
      case 'open_settings':
        unawaited(_openSettingsFromTray());
      case 'quit':
        unawaited(DesktopSetup.quitApp());
    }
  }

  Future<void> _hideInsteadOfClose() async {
    if (DesktopSetup._quitRequested) return;
    final shouldPreventClose = await windowManager.isPreventClose();
    if (shouldPreventClose) {
      await DesktopSetup.hideMainWindow();
    }
  }

  Future<void> _openSettingsFromTray() async {
    await DesktopSetup.showMainWindow();
    await onOpenSettings?.call();
  }
}
