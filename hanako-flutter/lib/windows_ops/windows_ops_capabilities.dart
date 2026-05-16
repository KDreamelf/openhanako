import 'dart:async';
import 'dart:io';

import 'windows_ops_client.dart';

class WindowsOpsCapabilities {
  const WindowsOpsCapabilities({
    required this.sidecar,
    required this.screenCapture,
    required this.inputMouse,
    required this.inputKeyboard,
    required this.uiaTree,
    required this.uiaInvoke,
    required this.ocr,
    required this.uiParsing,
    this.unavailableReasons = const <String, String>{},
  });

  const WindowsOpsCapabilities.unavailable({
    Map<String, String> unavailableReasons = const <String, String>{},
  }) : this(
         sidecar: false,
         screenCapture: false,
         inputMouse: false,
         inputKeyboard: false,
         uiaTree: false,
         uiaInvoke: false,
         ocr: false,
         uiParsing: false,
         unavailableReasons: unavailableReasons,
       );

  final bool sidecar;
  final bool screenCapture;
  final bool inputMouse;
  final bool inputKeyboard;
  final bool uiaTree;
  final bool uiaInvoke;
  final bool ocr;
  final bool uiParsing;
  final Map<String, String> unavailableReasons;

  bool get hasAnyTool =>
      screenCapture ||
      inputMouse ||
      inputKeyboard ||
      uiaTree ||
      uiaInvoke ||
      ocr ||
      uiParsing;

  List<String> get availableToolGroups {
    final groups = <String>[];
    if (screenCapture) groups.add('screen_capture');
    if (inputMouse || inputKeyboard) groups.add('input');
    if (uiaTree || uiaInvoke) groups.add('uia');
    if (ocr) groups.add('ocr');
    if (uiParsing) groups.add('ui_parsing');
    return groups;
  }
}

class WindowsOpsCapabilityProbe {
  WindowsOpsCapabilityProbe(
    this.client, {
    this.captureProbeSize = 1,
    this.captureProbeTimeout = const Duration(seconds: 5),
    this.uiaProbeTimeout = const Duration(seconds: 15),
    this.ocrProbeTimeout = const Duration(seconds: 15),
  });

  final WindowsOpsClient client;
  final int captureProbeSize;
  final Duration captureProbeTimeout;
  final Duration uiaProbeTimeout;
  final Duration ocrProbeTimeout;

  Future<WindowsOpsCapabilities> probe({String? ocrRoot}) async {
    final reasons = <String, String>{};

    if (!Platform.isWindows) {
      return const WindowsOpsCapabilities.unavailable(
        unavailableReasons: <String, String>{
          'sidecar': 'Windows 操作边车仅在 Windows 上启用',
        },
      );
    }

    Map<String, dynamic> ping;
    try {
      ping = await client.ping();
    } catch (err) {
      return WindowsOpsCapabilities.unavailable(
        unavailableReasons: <String, String>{'sidecar': _shortError(err)},
      );
    }

    final screenCapture = await _probeBool(
      'screen_capture',
      reasons,
      () => client
          .captureRegionPng(
            x: 0,
            y: 0,
            width: captureProbeSize,
            height: captureProbeSize,
          )
          .timeout(captureProbeTimeout),
    );

    final uiaTree = await _probeBool(
      'uia',
      reasons,
      () => client
          .queryUiaTree(
            root: 'desktop',
            view: 'control',
            maxDepth: 0,
            maxNodes: 1,
          )
          .timeout(uiaProbeTimeout),
    );
    final uiaInvoke =
        uiaTree && _nestedBool(ping, const ['capabilities', 'uia', 'invoke']);
    if (!uiaInvoke && uiaTree) {
      reasons['uia.invoke'] = '边车未声明 UIA InvokePattern 能力';
    }
    final inputMouse = _nestedBool(ping, const [
      'capabilities',
      'input',
      'mouse',
    ]);
    final inputKeyboard = _nestedBool(ping, const [
      'capabilities',
      'input',
      'keyboard',
    ]);
    if (!inputMouse) {
      reasons['input.mouse'] = '边车未声明鼠标输入能力';
    }
    if (!inputKeyboard) {
      reasons['input.keyboard'] = '边车未声明键盘输入能力';
    }

    final ocr = await _probeOcr(ocrRoot, reasons);
    final uiParsing = await _probeUiParser(reasons);

    return WindowsOpsCapabilities(
      sidecar: true,
      screenCapture: screenCapture,
      inputMouse: inputMouse,
      inputKeyboard: inputKeyboard,
      uiaTree: uiaTree,
      uiaInvoke: uiaInvoke,
      ocr: ocr,
      uiParsing: uiParsing,
      unavailableReasons: Map.unmodifiable(reasons),
    );
  }

  Future<bool> _probeOcr(String? root, Map<String, String> reasons) async {
    try {
      final status = await client
          .ocrStatus(root: root)
          .timeout(ocrProbeTimeout);
      final available = status['available'] == true;
      if (!available) {
        reasons['ocr'] = _ocrReason(status);
      }
      return available;
    } catch (err) {
      reasons['ocr'] = _shortError(err);
      return false;
    }
  }

  Future<bool> _probeUiParser(Map<String, String> reasons) async {
    try {
      final status = await client
          .uiParserStatus(load: true)
          .timeout(ocrProbeTimeout);
      final available = status['available'] == true;
      if (!available) {
        reasons['ui_parsing'] = _uiParserReason(status);
      }
      return available;
    } catch (err) {
      reasons['ui_parsing'] = _shortError(err);
      return false;
    }
  }

  Future<bool> _probeBool(
    String key,
    Map<String, String> reasons,
    Future<Object?> Function() run,
  ) async {
    try {
      await run();
      return true;
    } catch (err) {
      reasons[key] = _shortError(err);
      return false;
    }
  }
}

bool _nestedBool(Map<String, dynamic> value, List<String> path) {
  Object? current = value;
  for (final part in path) {
    if (current is! Map) {
      return false;
    }
    current = current[part];
  }
  return current == true;
}

String _ocrReason(Map<String, dynamic> status) {
  final error = status['error'];
  if (error is String && error.isNotEmpty) {
    return error;
  }

  final missing = status['missing'];
  if (missing is List && missing.isNotEmpty) {
    return 'OCR bundle 缺少文件: ${missing.take(3).join(', ')}';
  }

  final recognition = status['recognition'];
  if (recognition is Map) {
    final reason = recognition['reason'];
    if (reason is String && reason.isNotEmpty) {
      return reason;
    }
  }

  return 'OCR 未就绪';
}

String _uiParserReason(Map<String, dynamic> status) {
  final error = status['error'];
  if (error is String && error.isNotEmpty) {
    return error;
  }

  final missing = status['missing'];
  if (missing is List && missing.isNotEmpty) {
    return '界面识别模型缺少文件: ${missing.take(3).join(', ')}';
  }

  final dependencies = status['dependencies'];
  if (dependencies is Map && dependencies['ok'] == false) {
    final error = dependencies['error'];
    if (error is String && error.isNotEmpty) {
      return '界面识别模型依赖不可用: $error';
    }
    final missing = dependencies['missing'];
    if (missing is List && missing.isNotEmpty) {
      return '界面识别模型依赖不可用: ${missing.take(3).join(', ')}';
    }
    return '界面识别模型依赖不可用';
  }

  return '界面识别模型未就绪';
}

String _shortError(Object err) {
  if (err is WindowsOpsException) {
    return '${err.code}: ${err.message}';
  }
  if (err is TimeoutException) {
    return err.message ?? '请求超时';
  }
  if (err is FileSystemException) {
    return '${err.message}: ${err.path ?? ''}'.trim();
  }
  return err.toString();
}
