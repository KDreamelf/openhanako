import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/windows_ops/windows_ops.dart';

void main() {
  test('只注册通过能力探测的 Windows 操作工具', () {
    const capabilities = WindowsOpsCapabilities(
      sidecar: true,
      screenCapture: true,
      inputMouse: true,
      inputKeyboard: true,
      uiaTree: true,
      uiaInvoke: true,
      ocr: false,
      uiParsing: false,
    );

    final tools = WindowsOpsToolRegistry.buildTools(capabilities);
    final names = tools.map((tool) => tool.name).toSet();

    expect(names, contains(WindowsOpsToolNames.captureRegion));
    expect(names, contains(WindowsOpsToolNames.mouseMove));
    expect(names, contains(WindowsOpsToolNames.mouseClick));
    expect(names, contains(WindowsOpsToolNames.textInput));
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
      inputMouse: false,
      inputKeyboard: false,
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

  test('鼠标和键盘能力分别注册真实输入工具', () {
    const capabilities = WindowsOpsCapabilities(
      sidecar: true,
      screenCapture: false,
      inputMouse: true,
      inputKeyboard: true,
      uiaTree: false,
      uiaInvoke: false,
      ocr: false,
      uiParsing: false,
    );

    final names = WindowsOpsToolRegistry.buildTools(
      capabilities,
    ).map((tool) => tool.name).toList();

    expect(names, [
      WindowsOpsToolNames.mouseMove,
      WindowsOpsToolNames.mouseClick,
      WindowsOpsToolNames.textInput,
    ]);
  });

  test('界面识别工具支持直接传截图区域并默认返回压缩摘要', () {
    const capabilities = WindowsOpsCapabilities(
      sidecar: true,
      screenCapture: true,
      inputMouse: false,
      inputKeyboard: false,
      uiaTree: false,
      uiaInvoke: false,
      ocr: false,
      uiParsing: true,
    );

    final tool = WindowsOpsToolRegistry.buildTools(
      capabilities,
    ).singleWhere((tool) => tool.name == WindowsOpsToolNames.uiParse);
    final properties = tool.parameters['properties'] as Map<String, dynamic>;

    expect(tool.parameters.containsKey('required'), isFalse);
    expect(properties.keys, containsAll(['x', 'y', 'width', 'height']));
    expect(properties.keys, containsAll(['max_elements', 'include_raw']));
  });

  test('截图工具默认省略 base64，避免污染上下文', () {
    final compact = WindowsOpsToolOutputFormatter.compactCaptureRegion(const {
      'mime_type': 'image/png',
      'encoding': 'base64',
      'width': 100,
      'height': 80,
      'data': 'abcdef',
    }, const {});

    expect(compact['format'], 'compact_windows_capture_v1');
    expect(compact['base64_chars'], 6);
    expect(compact.containsKey('image_base64'), isFalse);
  });

  test('界面识别结果会压缩为文字概览和图标推理候选', () {
    final compact = WindowsOpsToolOutputFormatter.compactUiParse(const {
      'available': true,
      'engine': 'rust-yolo-rs+ocrs',
      'screen_info': {'width': 400, 'height': 300},
      'parsed_content_list': [
        {
          'id': 1,
          'kind': 'icon',
          'label': '保存',
          'bbox': {'x': 10, 'y': 20, 'width': 24, 'height': 24},
          'confidence': 0.82,
        },
        {
          'id': 2,
          'kind': 'text',
          'label': '保存',
          'text': '保存',
          'bbox': {'x': 40, 'y': 18, 'width': 48, 'height': 20},
        },
      ],
      'label_coordinates': [],
      'ocr_text': {
        'line_count': 1,
        'word_count': 1,
        'text': '保存',
        'lines': [
          {
            'text': '保存',
            'bbox': {'x': 40, 'y': 18, 'width': 48, 'height': 20},
          },
        ],
      },
    }, const {});

    expect(compact['format'], 'compact_windows_ui_observation_v1');
    expect(compact.containsKey('parsed_content_list'), isFalse);
    final candidates = compact['action_candidates'] as List<dynamic>;
    expect(candidates, hasLength(1));
    final first = candidates.first as Map<String, dynamic>;
    expect(first['description'], contains('附近文字：保存'));
    expect(first['inference'], containsPair('class', 'icon'));
    expect(first['center'], {'x': 22, 'y': 32});
  });

  test('UIA 树压缩会省略低价值字段并保留可交互节点', () {
    final compact = WindowsOpsToolOutputFormatter.compactUiaTree(const {
      'root': 'desktop',
      'view': 'control',
      'max_depth': 2,
      'max_nodes': 40,
      'tree': {
        'name': '桌面',
        'control_type': 50033,
        'is_enabled': true,
        'is_offscreen': false,
        'bounding_rect': {'left': 0, 'top': 0, 'width': 800, 'height': 600},
        'process_id': 123,
        'framework_id': 'Win32',
        'children': [
          {
            'name': '确定',
            'automation_id': 'okButton',
            'control_type': 50000,
            'is_enabled': true,
            'is_offscreen': false,
            'bounding_rect': {'left': 10, 'top': 20, 'width': 80, 'height': 30},
            'children': [],
          },
        ],
      },
    }, const {});

    expect(compact['format'], 'compact_windows_uia_tree_v1');
    final nodes = compact['nodes'] as List<dynamic>;
    expect(nodes, hasLength(2));
    final button = nodes.last as Map<String, dynamic>;
    expect(button['role'], 'button');
    expect(button['interactive'], isTrue);
    expect(button.containsKey('process_id'), isFalse);
    expect(button.containsKey('framework_id'), isFalse);
  });
}
