// Windows 标题栏的浅/深主题同步。
//
// Flutter 桌面应用默认使用 OS 提供的 native title bar — 它的"最小化 / 最大化 /
// 关闭"按钮颜色取决于 Windows 的 immersive dark/light 设置，不会自动跟随
// MaterialApp 的 themeMode。当 app 用浅色背景但系统标题栏处于深色模式时，
// 三个按钮在浅色背景上几乎不可见。
//
// 这里通过 DWM 属性把标题栏切到匹配的明暗，并显式设置 caption/text 颜色。
// 只切 DWMWA_USE_IMMERSIVE_DARK_MODE 在透明/浅色窗口背景下不够稳定，可能出现
// "白底 + 白色 caption glyph" 的低对比组合。
//
// 调用方在 [HanakoApp.build] 里 `addPostFrameCallback` 触发；
// 我们在内部用进程 ID + EnumWindows 找到主 HWND 并缓存，主题切换时复用。

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' show Brightness;

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

int? _cachedHwnd;
bool? _lastAppliedDark;

int _rgbToColorRef(int rgb) {
  final r = (rgb >> 16) & 0xFF;
  final g = (rgb >> 8) & 0xFF;
  final b = rgb & 0xFF;
  return (b << 16) | (g << 8) | r;
}

void _setDwmIntAttribute(int hwnd, int attribute, int value) {
  final pointer = calloc<Int32>()..value = value;
  try {
    DwmSetWindowAttribute(hwnd, attribute, pointer.cast(), sizeOf<Int32>());
  } finally {
    calloc.free(pointer);
  }
}

void _setDwmColorAttribute(int hwnd, int attribute, int rgb) {
  final pointer = calloc<Uint32>()..value = _rgbToColorRef(rgb);
  try {
    DwmSetWindowAttribute(hwnd, attribute, pointer.cast(), sizeOf<Uint32>());
  } finally {
    calloc.free(pointer);
  }
}

int? _findMainHwnd() {
  if (!Platform.isWindows) return null;
  if (_cachedHwnd != null && IsWindow(_cachedHwnd!) != 0) {
    return _cachedHwnd;
  }
  final pid = GetCurrentProcessId();
  int found = 0;

  int callback(int hwnd, int lparam) {
    if (found != 0) return FALSE;
    if (IsWindowVisible(hwnd) == 0) return TRUE;
    final wpid = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, wpid);
      if (wpid.value == pid) {
        final owner = GetWindow(hwnd, GW_OWNER);
        if (owner == 0) {
          found = hwnd;
          return FALSE;
        }
      }
    } finally {
      calloc.free(wpid);
    }
    return TRUE;
  }

  final cb = NativeCallable<WNDENUMPROC>.isolateLocal(
    callback,
    exceptionalReturn: 0,
  );
  try {
    EnumWindows(cb.nativeFunction, 0);
  } finally {
    cb.close();
  }
  if (found != 0) {
    _cachedHwnd = found;
    return found;
  }
  return null;
}

/// 把 Windows 标题栏（最小化/最大化/关闭）切到匹配的明暗。
/// 同一亮度状态不会重复调用 API。
void applyWindowsTitleBarBrightness(bool dark) {
  if (!Platform.isWindows) return;
  // 如果 cache 的窗口已经销毁，丢弃缓存。
  if (_cachedHwnd != null && IsWindow(_cachedHwnd!) == 0) {
    _cachedHwnd = null;
    _lastAppliedDark = null;
  }
  final hwnd = _findMainHwnd();
  if (hwnd == null) return;
  if (_lastAppliedDark == dark) return;

  unawaited(
    windowManager
        .setBrightness(dark ? Brightness.dark : Brightness.light)
        .catchError((_) {}),
  );

  const dwmwaBorderColor = 34;
  const dwmwaCaptionColor = 35;
  const dwmwaTextColor = 36;
  const dwmwaUseImmersiveDarkMode = 20;
  final captionRgb = dark ? 0x06080F : 0xF7FAF8;
  final textRgb = dark ? 0xEDF1F7 : 0x0E1A1F;
  final borderRgb = dark ? 0x1B2336 : 0xD5DDE2;
  try {
    _setDwmIntAttribute(hwnd, dwmwaUseImmersiveDarkMode, dark ? 1 : 0);
    _setDwmColorAttribute(hwnd, dwmwaCaptionColor, captionRgb);
    _setDwmColorAttribute(hwnd, dwmwaTextColor, textRgb);
    _setDwmColorAttribute(hwnd, dwmwaBorderColor, borderRgb);
    _lastAppliedDark = dark;
    // 强制 frame 重绘 — 否则标题栏颜色不会立即生效。
    const swpNoSize = 0x0001;
    const swpNoMove = 0x0002;
    const swpNoZorder = 0x0004;
    const swpFrameChanged = 0x0020;
    SetWindowPos(
      hwnd,
      0,
      0,
      0,
      0,
      0,
      swpNoSize | swpNoMove | swpNoZorder | swpFrameChanged,
    );
  } catch (_) {}
}
