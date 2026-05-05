import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/windows_ops/windows_ops.dart';

void main() {
  test('只注册通过能力探测的 Windows 操作工具', () {
    const capabilities = WindowsOpsCapabilities(
      sidecar: true,
      screenCapture: true,
      uiaTree: true,
      uiaInvoke: true,
      ocr: false,
      uiParsing: false,
    );

    final tools = WindowsOpsToolRegistry.buildTools(capabilities);
    final names = tools.map((tool) => tool.name).toSet();

    expect(names, contains(WindowsOpsToolNames.captureRegion));
    expect(names, contains(WindowsOpsToolNames.uiaTree));
    expect(names, contains(WindowsOpsToolNames.uiaInvoke));
    expect(names, isNot(contains(WindowsOpsToolNames.ocrRecognize)));
    expect(names, isNot(contains(WindowsOpsToolNames.uiParse)));
  });

  test('边车不可用时不注册任何 Windows 操作工具', () {
    const capabilities = WindowsOpsCapabilities.unavailable();

    final tools = WindowsOpsToolRegistry.buildTools(capabilities);
    final promptTools = WindowsOpsToolRegistry.buildPromptToolSchemas(
      capabilities,
    );

    expect(tools, isEmpty);
    expect(promptTools, isEmpty);
  });

  test('OCR 与界面识别模型通过后才注册对应工具', () {
    const capabilities = WindowsOpsCapabilities(
      sidecar: true,
      screenCapture: false,
      uiaTree: false,
      uiaInvoke: false,
      ocr: true,
      uiParsing: true,
    );

    final names = WindowsOpsToolRegistry.buildTools(
      capabilities,
    ).map((tool) => tool.name).toList();

    expect(names, [
      WindowsOpsToolNames.ocrRecognize,
      WindowsOpsToolNames.uiParse,
    ]);
  });
}
