import 'dart:convert';

import '../llm/provider.dart';
import '../llm/tool_format/prompt_tool.dart';
import 'windows_ops_capabilities.dart';
import 'windows_ops_client.dart';

class WindowsOpsToolNames {
  const WindowsOpsToolNames._();

  static const captureRegion = 'windows_capture_region';
  static const mouseMove = 'windows_mouse_move';
  static const mouseClick = 'windows_mouse_click';
  static const textInput = 'windows_text_input';
  static const uiaTree = 'windows_uia_tree';
  static const uiaInvoke = 'windows_uia_invoke';
  static const ocrRecognize = 'windows_ocr_recognize';
  static const uiParse = 'windows_ui_parse';
}

class WindowsOpsToolRegistry {
  const WindowsOpsToolRegistry._();

  static List<Tool> buildTools(WindowsOpsCapabilities capabilities) {
    return _buildToolSpecs(capabilities)
        .map(
          (tool) => Tool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters,
          ),
        )
        .toList(growable: false);
  }

  static List<ToolSchema> buildPromptToolSchemas(
    WindowsOpsCapabilities capabilities,
  ) {
    return _buildToolSpecs(capabilities)
        .map(
          (tool) => ToolSchema(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters,
          ),
        )
        .toList(growable: false);
  }

  static List<_ToolSpec> _buildToolSpecs(WindowsOpsCapabilities capabilities) {
    if (!capabilities.sidecar) {
      return const <_ToolSpec>[];
    }

    final tools = <_ToolSpec>[];
    if (capabilities.screenCapture) {
      tools.add(_captureRegionTool);
    }
    if (capabilities.inputMouse) {
      tools.add(_mouseMoveTool);
      tools.add(_mouseClickTool);
    }
    if (capabilities.inputKeyboard) {
      tools.add(_textInputTool);
    }
    if (capabilities.uiaTree) {
      tools.add(_uiaTreeTool);
    }
    if (capabilities.uiaInvoke) {
      tools.add(_uiaInvokeTool);
    }
    if (capabilities.ocr) {
      tools.add(_ocrRecognizeTool);
    }
    if (capabilities.uiParsing) {
      tools.add(_uiParseTool);
    }
    return tools;
  }
}

class WindowsOpsToolExecutor {
  WindowsOpsToolExecutor(this.client);

  final WindowsOpsClient client;

  Future<Map<String, dynamic>> execute(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    switch (name) {
      case WindowsOpsToolNames.captureRegion:
        final result = await client.call(
          'screen.capture_region',
          params: _captureRegionParams(arguments),
        );
        return WindowsOpsToolOutputFormatter.compactCaptureRegion(
          result,
          arguments,
        );
      case WindowsOpsToolNames.mouseMove:
        return client.call(
          'input.mouse_move',
          params: _mouseMoveParams(arguments),
        );
      case WindowsOpsToolNames.mouseClick:
        return client.call(
          'input.mouse_click',
          params: _mouseClickParams(arguments),
        );
      case WindowsOpsToolNames.textInput:
        return client.call('input.text', params: _textInputParams(arguments));
      case WindowsOpsToolNames.uiaTree:
        final result = await client.call(
          'uia.tree',
          params: _uiaParams(arguments),
        );
        return WindowsOpsToolOutputFormatter.compactUiaTree(result, arguments);
      case WindowsOpsToolNames.uiaInvoke:
        return client.call('uia.invoke', params: _uiaParams(arguments));
      case WindowsOpsToolNames.ocrRecognize:
        final result = await client.call(
          'ocr.recognize',
          params: _ocrParams(arguments),
        );
        return WindowsOpsToolOutputFormatter.compactOcr(result, arguments);
      case WindowsOpsToolNames.uiParse:
        final result = await client.call(
          'ui.parse_base64',
          params: await _uiParseParams(arguments, client),
        );
        return WindowsOpsToolOutputFormatter.compactUiParse(result, arguments);
      default:
        throw ArgumentError.value(name, 'name', '未知 Windows 操作工具');
    }
  }
}

Map<String, dynamic> _mouseMoveParams(Map<String, dynamic> args) {
  return <String, dynamic>{'x': _intArg(args, 'x'), 'y': _intArg(args, 'y')};
}

Map<String, dynamic> _mouseClickParams(Map<String, dynamic> args) {
  final button = (args['button']?.toString().trim().isEmpty ?? true)
      ? 'left'
      : args['button'].toString().trim();
  final clicks = args.containsKey('clicks') && args['clicks'] != null
      ? _intArg(args, 'clicks')
      : 1;
  final params = <String, dynamic>{
    'x': _intArg(args, 'x'),
    'y': _intArg(args, 'y'),
    'button': button,
    'clicks': clicks,
  };
  if (args.containsKey('interval_ms') && args['interval_ms'] != null) {
    params['interval_ms'] = _intArg(args, 'interval_ms');
  }
  return params;
}

Map<String, dynamic> _textInputParams(Map<String, dynamic> args) {
  final text = args['text'];
  if (text is! String || text.isEmpty) {
    throw ArgumentError.value(text, 'text', '文本输入工具需要非空 text');
  }
  return <String, dynamic>{
    'text': text,
    'press_enter': args['press_enter'] == true,
  };
}

Map<String, dynamic> _captureRegionParams(Map<String, dynamic> args) {
  return <String, dynamic>{
    'x': _intArg(args, 'x'),
    'y': _intArg(args, 'y'),
    'width': _intArg(args, 'width'),
    'height': _intArg(args, 'height'),
  };
}

Map<String, dynamic> _uiaParams(Map<String, dynamic> args) {
  final params = <String, dynamic>{};
  for (final key in const [
    'root',
    'view',
    'point',
    'hwnd',
    'selector',
    'max_depth',
    'max_nodes',
  ]) {
    if (args.containsKey(key) && args[key] != null) {
      params[key] = args[key];
    }
  }
  return params;
}

Map<String, dynamic> _ocrParams(Map<String, dynamic> args) {
  final imageBase64 = args['image_base64'];
  if (imageBase64 is! String || imageBase64.isEmpty) {
    throw ArgumentError.value(
      imageBase64,
      'image_base64',
      'OCR 工具需要 image_base64',
    );
  }
  final params = <String, dynamic>{'image_base64': imageBase64};
  for (final key in const ['language', 'model_path']) {
    if (args.containsKey(key) && args[key] != null) {
      params[key] = args[key];
    }
  }
  return params;
}

Future<Map<String, dynamic>> _uiParseParams(
  Map<String, dynamic> args,
  WindowsOpsClient client,
) async {
  final imageBase64 = await _uiParseImageBase64(args, client);
  if (imageBase64.isEmpty) {
    throw ArgumentError.value(
      imageBase64,
      'image_base64',
      '界面识别工具需要 image_base64 或 x/y/width/height',
    );
  }
  final params = <String, dynamic>{
    'image_base64': imageBase64,
    'return_annotated_image': args['return_annotated_image'] == true,
  };
  for (final key in const [
    'box_threshold',
    'iou_threshold',
    'use_paddleocr',
    'ocr_text_threshold',
    'imgsz',
    'batch_size',
    'use_local_semantics',
  ]) {
    if (args.containsKey(key) && args[key] != null) {
      params[key] = args[key];
    }
  }
  return params;
}

Future<String> _uiParseImageBase64(
  Map<String, dynamic> args,
  WindowsOpsClient client,
) async {
  final imageBase64 = args['image_base64'];
  if (imageBase64 is String && imageBase64.isNotEmpty) {
    return imageBase64;
  }
  if (!_hasCaptureRegion(args)) {
    return '';
  }
  final png = await client.captureRegionPng(
    x: _intArg(args, 'x'),
    y: _intArg(args, 'y'),
    width: _intArg(args, 'width'),
    height: _intArg(args, 'height'),
  );
  return base64Encode(png);
}

bool _hasCaptureRegion(Map<String, dynamic> args) {
  return args.containsKey('x') &&
      args.containsKey('y') &&
      args.containsKey('width') &&
      args.containsKey('height');
}

int _intArg(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  throw ArgumentError.value(value, key, '参数必须是整数');
}

class WindowsOpsToolOutputFormatter {
  const WindowsOpsToolOutputFormatter._();

  static Map<String, dynamic> compactCaptureRegion(
    Map<String, dynamic> result,
    Map<String, dynamic> args,
  ) {
    final includeImage = args['include_image_base64'] == true;
    final compact = <String, dynamic>{
      'format': 'compact_windows_capture_v1',
      'mime_type': result['mime_type'],
      'width': result['width'],
      'height': result['height'],
      'encoding': result['encoding'],
      'base64_chars': result['data'] is String
          ? (result['data'] as String).length
          : 0,
      'note': includeImage
          ? '已按请求返回 image_base64。'
          : '默认省略 image_base64，避免污染上下文；需要视觉理解时优先调用 windows_ui_parse 并直接传 x/y/width/height。',
    };
    if (includeImage) compact['image_base64'] = result['data'];
    return compact;
  }

  static Map<String, dynamic> compactOcr(
    Map<String, dynamic> result,
    Map<String, dynamic> args,
  ) {
    if (args['include_raw'] == true) return result;
    final maxLines = _boundedInt(
      args['max_lines'],
      defaultValue: 40,
      min: 1,
      max: 200,
    );
    final lines = _listValue(result['lines'])
        .map(_compactOcrLine)
        .where((line) => _stringValue(line['text']).isNotEmpty)
        .take(maxLines)
        .toList(growable: false);
    final compact = <String, dynamic>{
      'format': 'compact_windows_ocr_v1',
      'available': result['available'] == true,
      'engine': result['engine'],
      'line_count': result['line_count'],
      'word_count': result['word_count'],
      'text': result['text'],
      'lines': lines,
    };
    if (args['include_words'] == true) {
      compact['words'] = _listValue(result['words'])
          .map(_compactOcrWord)
          .where((word) => _stringValue(word['text']).isNotEmpty)
          .take(200)
          .toList(growable: false);
    }
    return compact;
  }

  static Map<String, dynamic> compactUiParse(
    Map<String, dynamic> result,
    Map<String, dynamic> args,
  ) {
    if (args['include_raw'] == true) return result;
    final screen = _mapValue(result['screen_info']);
    final rawElements = _listValue(result['parsed_content_list']);
    final icons = rawElements
        .where((item) => _mapValue(item)['kind'] == 'icon')
        .map(_compactUiElement)
        .toList(growable: false);
    final textElements = rawElements
        .where((item) => _mapValue(item)['kind'] == 'text')
        .map(_compactUiElement)
        .where((item) => _stringValue(item['text']).isNotEmpty)
        .toList(growable: false);
    final maxElements = _boundedInt(
      args['max_elements'],
      defaultValue: 60,
      min: 1,
      max: 300,
    );
    final maxTextLines = _boundedInt(
      args['max_text_lines'],
      defaultValue: 40,
      min: 1,
      max: 200,
    );
    final ocrText = _mapValue(result['ocr_text']);
    final textLines = _listValue(ocrText['lines'])
        .map(_compactOcrLine)
        .where((line) => _stringValue(line['text']).isNotEmpty)
        .take(maxTextLines)
        .toList(growable: false);
    final allElements = <Map<String, dynamic>>[
      ...icons,
      ...textElements,
    ].take(maxElements).toList(growable: false);
    final compact = <String, dynamic>{
      'format': 'compact_windows_ui_observation_v1',
      'available': result['available'] == true,
      'engine': result['engine'],
      'screen': {'width': screen['width'], 'height': screen['height']},
      'summary': {
        'element_count': rawElements.length,
        'icon_candidate_count': icons.length,
        'text_line_count': ocrText['line_count'],
        'returned_element_count': allElements.length,
      },
      'overview': _uiOverview(screen, icons, textLines),
      'action_candidates': icons.take(maxElements).toList(growable: false),
      'text_lines': textLines,
      'elements': allElements,
      'hints': const [
        'action_candidates 来自本地图标检测模型，适合配合 center 坐标点击。',
        'description 会把图标检测结果和附近 OCR 文本合并成较高密度说明。',
      ],
    };
    if (result['annotated_image_base64'] is String &&
        args['return_annotated_image'] == true) {
      compact['annotated_image_base64'] = result['annotated_image_base64'];
    }
    final warnings = _listValue(result['warnings']);
    if (warnings.isNotEmpty) compact['warnings'] = warnings;
    return compact;
  }

  static Map<String, dynamic> compactUiaTree(
    Map<String, dynamic> result,
    Map<String, dynamic> args,
  ) {
    if (args['include_raw'] == true) return result;
    final tree = _mapValue(result['tree']);
    final rawStats = _UiaStats();
    final nodes = <Map<String, dynamic>>[];
    _flattenUiaTree(tree, nodes, rawStats, depth: 0);
    final maxCompactNodes = _boundedInt(
      args['compact_max_nodes'],
      defaultValue: 80,
      min: 1,
      max: 300,
    );
    final kept = nodes.take(maxCompactNodes).toList(growable: false);
    return <String, dynamic>{
      'format': 'compact_windows_uia_tree_v1',
      'source': {
        'root': result['root'],
        'view': result['view'],
        'max_depth': result['max_depth'],
        'max_nodes': result['max_nodes'],
      },
      'summary': {
        'raw_node_count': rawStats.rawNodes,
        'visible_node_count': rawStats.visibleNodes,
        'named_node_count': rawStats.namedNodes,
        'interactive_candidate_count': rawStats.interactiveCandidates,
        'returned_node_count': kept.length,
      },
      'overview': _uiaOverview(kept),
      'interactive_candidates': kept
          .where((node) => node['interactive'] == true)
          .take(30)
          .toList(growable: false),
      'nodes': kept,
      'hints': const [
        '已省略 process_id、framework_id、空字段和大部分容器噪声。',
        '需要调试原始 UIA 树时传 include_raw=true。',
      ],
    };
  }
}

class _UiaStats {
  int rawNodes = 0;
  int visibleNodes = 0;
  int namedNodes = 0;
  int interactiveCandidates = 0;
}

Map<String, dynamic> _compactUiElement(Object? value) {
  final element = _mapValue(value);
  final kind = _stringValue(element['kind']);
  final label = _stringValue(element['label']);
  final text = _stringValue(element['text']);
  final bbox = _compactBounds(element['bbox']);
  final center = _centerFromBounds(bbox);
  final confidence = _numValue(element['confidence']);
  final compact = <String, dynamic>{
    'id': element['id'],
    'kind': kind,
    'description': _uiElementDescription(kind, label, text, confidence),
    if (text.isNotEmpty) 'text': text,
    if (label.isNotEmpty && label != text) 'nearby_text': label,
    if (bbox.isNotEmpty) 'bounds': bbox,
    if (center.isNotEmpty) 'center': center,
  };
  if (kind == 'icon') {
    final inference = <String, dynamic>{
      'model': 'icon_detector',
      'class': 'icon',
    };
    if (confidence != null) {
      inference['confidence'] = confidence;
    }
    compact['inference'] = inference;
  }
  return compact;
}

String _uiElementDescription(
  String kind,
  String label,
  String text,
  num? confidence,
) {
  if (kind == 'text') {
    return text.isEmpty ? '文字区域' : '文字：$text';
  }
  final score = confidence == null
      ? ''
      : '，置信度 ${confidence.toStringAsFixed(2)}';
  if (label.isNotEmpty && label != 'icon') {
    return '图标/可点击候选，附近文字：$label$score';
  }
  return '图标/可点击候选（模型仅判断为 icon 类）$score';
}

List<String> _uiOverview(
  Map<String, dynamic> screen,
  List<Map<String, dynamic>> icons,
  List<Map<String, dynamic>> textLines,
) {
  final snippets = textLines
      .map((line) => _stringValue(line['text']))
      .where((text) => text.isNotEmpty)
      .take(8)
      .join(' / ');
  return <String>[
    '截图 ${screen['width'] ?? "?"}x${screen['height'] ?? "?"}，检测到 ${icons.length} 个图标/可点击候选。',
    if (snippets.isNotEmpty) '主要可见文字：$snippets',
  ];
}

Map<String, dynamic> _compactOcrLine(Object? value) {
  final line = _mapValue(value);
  final text = _stringValue(line['text']);
  final bbox = _compactBounds(line['bbox']);
  final center = _centerFromBounds(bbox);
  return <String, dynamic>{
    'text': text,
    if (bbox.isNotEmpty) 'bounds': bbox,
    if (center.isNotEmpty) 'center': center,
  };
}

Map<String, dynamic> _compactOcrWord(Object? value) {
  final word = _mapValue(value);
  final text = _stringValue(word['text']);
  final bbox = _compactBounds(word['bbox']);
  return <String, dynamic>{'text': text, if (bbox.isNotEmpty) 'bounds': bbox};
}

void _flattenUiaTree(
  Map<String, dynamic> node,
  List<Map<String, dynamic>> output,
  _UiaStats stats, {
  required int depth,
}) {
  if (node.isEmpty) return;
  stats.rawNodes++;
  final offscreen = node['is_offscreen'] == true;
  if (!offscreen) stats.visibleNodes++;
  final name = _stringValue(node['name']);
  final automationId = _stringValue(node['automation_id']);
  if (name.isNotEmpty || automationId.isNotEmpty) stats.namedNodes++;
  final role = _uiaRole(node);
  final interactive = _isInteractiveUiaRole(role);
  if (interactive && !offscreen) stats.interactiveCandidates++;
  if (_isUsefulUiaNode(node, role, depth)) {
    final bounds = _compactBounds(node['bounding_rect']);
    final center = _centerFromBounds(bounds);
    output.add(<String, dynamic>{
      'id': output.length + 1,
      'depth': depth,
      'role': role,
      if (name.isNotEmpty) 'name': name,
      if (automationId.isNotEmpty) 'automation_id': automationId,
      if (_stringValue(node['class_name']).isNotEmpty && name.isEmpty)
        'class_name': _stringValue(node['class_name']),
      if (bounds.isNotEmpty) 'bounds': bounds,
      if (center.isNotEmpty) 'center': center,
      if (node['is_enabled'] == false) 'enabled': false,
      if (offscreen) 'offscreen': true,
      if (interactive) 'interactive': true,
    });
  }
  for (final child in _listValue(node['children'])) {
    _flattenUiaTree(_mapValue(child), output, stats, depth: depth + 1);
  }
}

bool _isUsefulUiaNode(Map<String, dynamic> node, String role, int depth) {
  if (node['is_offscreen'] == true) return false;
  final name = _stringValue(node['name']);
  final automationId = _stringValue(node['automation_id']);
  final className = _stringValue(node['class_name']);
  final hasBounds = _compactBounds(node['bounding_rect']).isNotEmpty;
  if (depth == 0) return true;
  if (name.isNotEmpty || automationId.isNotEmpty) return true;
  if (_isInteractiveUiaRole(role)) return true;
  if (className.isNotEmpty && hasBounds) return true;
  return false;
}

String _uiaRole(Map<String, dynamic> node) {
  final localized = _stringValue(node['localized_control_type']);
  if (localized.isNotEmpty) return localized;
  final type = node['control_type'];
  final id = type is num ? type.toInt() : int.tryParse('$type');
  return _uiaControlTypeNames[id] ?? 'control_$type';
}

bool _isInteractiveUiaRole(String role) {
  final normalized = role.toLowerCase();
  return normalized.contains('button') ||
      normalized.contains('edit') ||
      normalized.contains('menu') ||
      normalized.contains('tab item') ||
      normalized.contains('hyperlink') ||
      normalized.contains('list item') ||
      normalized.contains('tree item') ||
      normalized.contains('check') ||
      normalized.contains('radio') ||
      normalized.contains('按钮') ||
      normalized.contains('编辑') ||
      normalized.contains('菜单') ||
      normalized.contains('选项卡') ||
      normalized.contains('链接') ||
      normalized.contains('列表项') ||
      normalized.contains('树项') ||
      normalized.contains('复选') ||
      normalized.contains('单选');
}

List<String> _uiaOverview(List<Map<String, dynamic>> nodes) {
  final named = nodes
      .where((node) => _stringValue(node['name']).isNotEmpty)
      .take(10)
      .map((node) => '${node['role']}：${node['name']}')
      .toList(growable: false);
  if (named.isEmpty) {
    return const ['UIA 没有返回高价值命名节点，建议改用 windows_ui_parse 观察截图。'];
  }
  return <String>['主要结构：${named.join(' / ')}'];
}

Map<String, dynamic> _compactBounds(Object? value) {
  final raw = _mapValue(value);
  if (raw.isEmpty) return const <String, dynamic>{};
  final x = _numValue(raw['x']) ?? _numValue(raw['left']);
  final y = _numValue(raw['y']) ?? _numValue(raw['top']);
  final width = _numValue(raw['width']);
  final height = _numValue(raw['height']);
  if (x == null || y == null || width == null || height == null) {
    return const <String, dynamic>{};
  }
  if (width <= 0 || height <= 0) return const <String, dynamic>{};
  return <String, dynamic>{
    'x': x.round(),
    'y': y.round(),
    'width': width.round(),
    'height': height.round(),
  };
}

Map<String, dynamic> _centerFromBounds(Map<String, dynamic> bounds) {
  final x = bounds['x'];
  final y = bounds['y'];
  final width = bounds['width'];
  final height = bounds['height'];
  if (x is! num || y is! num || width is! num || height is! num) {
    return const <String, dynamic>{};
  }
  return <String, dynamic>{
    'x': (x + width / 2).round(),
    'y': (y + height / 2).round(),
  };
}

int _boundedInt(
  Object? value, {
  required int defaultValue,
  required int min,
  required int max,
}) {
  final parsed = value is num ? value.toInt() : int.tryParse('$value');
  return (parsed ?? defaultValue).clamp(min, max);
}

String _stringValue(Object? value) {
  if (value == null) return '';
  return '$value'.trim();
}

num? _numValue(Object? value) {
  if (value is num) return value;
  return num.tryParse('$value');
}

Map<String, dynamic> _mapValue(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return const <String, dynamic>{};
}

List<Object?> _listValue(Object? value) {
  if (value is List) return value;
  return const <Object?>[];
}

const _uiaControlTypeNames = <int, String>{
  50000: 'button',
  50001: 'calendar',
  50002: 'checkbox',
  50003: 'combobox',
  50004: 'edit',
  50005: 'hyperlink',
  50006: 'image',
  50007: 'list_item',
  50008: 'list',
  50009: 'menu',
  50010: 'menu_bar',
  50011: 'menu_item',
  50012: 'progress_bar',
  50013: 'radio_button',
  50014: 'scroll_bar',
  50015: 'slider',
  50016: 'spinner',
  50017: 'status_bar',
  50018: 'tab',
  50019: 'tab_item',
  50020: 'text',
  50021: 'toolbar',
  50022: 'tooltip',
  50023: 'tree',
  50024: 'tree_item',
  50025: 'custom',
  50026: 'group',
  50027: 'thumb',
  50028: 'data_grid',
  50029: 'data_item',
  50030: 'document',
  50031: 'split_button',
  50032: 'window',
  50033: 'pane',
  50034: 'header',
  50035: 'header_item',
  50036: 'table',
  50037: 'title_bar',
  50038: 'separator',
  50039: 'semantic_zoom',
  50040: 'app_bar',
};

class _ToolSpec {
  const _ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

const _captureRegionTool = _ToolSpec(
  name: WindowsOpsToolNames.captureRegion,
  description:
      '截取 Windows 屏幕局部区域。默认只返回截图尺寸和体积摘要，避免 base64 污染上下文；需要原图时设置 include_image_base64=true。若目标是理解界面，优先直接调用 windows_ui_parse。',
  parameters: <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': <String, dynamic>{
      'x': <String, dynamic>{'type': 'integer', 'description': '左上角 X 坐标'},
      'y': <String, dynamic>{'type': 'integer', 'description': '左上角 Y 坐标'},
      'width': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 8192,
      },
      'height': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 8192,
      },
      'include_image_base64': <String, dynamic>{
        'type': 'boolean',
        'description': '是否返回 PNG base64。默认 false',
      },
    },
    'required': <String>['x', 'y', 'width', 'height'],
  },
);

const _mouseMoveTool = _ToolSpec(
  name: WindowsOpsToolNames.mouseMove,
  description: '把 Windows 鼠标指针移动到指定屏幕坐标。用于真实界面操作前的定位。',
  parameters: <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': <String, dynamic>{
      'x': <String, dynamic>{'type': 'integer', 'description': '屏幕 X 坐标'},
      'y': <String, dynamic>{'type': 'integer', 'description': '屏幕 Y 坐标'},
    },
    'required': <String>['x', 'y'],
  },
);

const _mouseClickTool = _ToolSpec(
  name: WindowsOpsToolNames.mouseClick,
  description: '移动鼠标并执行真实点击。适合配合截图、界面识别或 UIA 坐标操作。',
  parameters: <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': <String, dynamic>{
      'x': <String, dynamic>{'type': 'integer', 'description': '屏幕 X 坐标'},
      'y': <String, dynamic>{'type': 'integer', 'description': '屏幕 Y 坐标'},
      'button': <String, dynamic>{
        'type': 'string',
        'enum': <String>['left', 'right', 'middle'],
        'description': '鼠标按键，默认 left',
      },
      'clicks': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 5,
        'description': '点击次数，默认 1',
      },
      'interval_ms': <String, dynamic>{
        'type': 'integer',
        'minimum': 0,
        'maximum': 1000,
        'description': '多次点击间隔毫秒数',
      },
    },
    'required': <String>['x', 'y'],
  },
);

const _textInputTool = _ToolSpec(
  name: WindowsOpsToolNames.textInput,
  description: '向当前焦点控件输入文字，可选回车提交。使用前应先通过点击或 UIA 聚焦目标输入框。',
  parameters: <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': <String, dynamic>{
      'text': <String, dynamic>{'type': 'string', 'description': '要输入的文本'},
      'press_enter': <String, dynamic>{
        'type': 'boolean',
        'description': '输入后是否按回车',
      },
    },
    'required': <String>['text'],
  },
);

const _uiaTreeTool = _ToolSpec(
  name: WindowsOpsToolNames.uiaTree,
  description:
      '读取 Windows UI Automation 控件树，并返回压缩后的高密度控件摘要。默认省略 process_id、framework_id、空字段和容器噪声；需要调试原始树时设置 include_raw=true。',
  parameters: <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': <String, dynamic>{
      'root': <String, dynamic>{
        'type': 'string',
        'enum': <String>['desktop', 'focused'],
        'description': '根节点，默认 desktop',
      },
      'view': <String, dynamic>{
        'type': 'string',
        'enum': <String>['control', 'content', 'raw'],
        'description': 'UIA 视图，默认 control',
      },
      'point': _pointSchema,
      'hwnd': <String, dynamic>{'type': 'integer'},
      'max_depth': <String, dynamic>{
        'type': 'integer',
        'minimum': 0,
        'maximum': 12,
      },
      'max_nodes': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 5000,
      },
      'compact_max_nodes': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 300,
        'description': '压缩结果最多返回多少个高价值节点，默认 80',
      },
      'include_raw': <String, dynamic>{
        'type': 'boolean',
        'description': '是否返回 sidecar 原始 UIA 树。默认 false',
      },
    },
  },
);

const _uiaInvokeTool = _ToolSpec(
  name: WindowsOpsToolNames.uiaInvoke,
  description: '对 Windows UIA 元素执行 InvokePattern，会触发真实界面动作。',
  parameters: <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': <String, dynamic>{
      'root': <String, dynamic>{
        'type': 'string',
        'enum': <String>['desktop', 'focused'],
      },
      'view': <String, dynamic>{
        'type': 'string',
        'enum': <String>['control', 'content', 'raw'],
      },
      'point': _pointSchema,
      'hwnd': <String, dynamic>{'type': 'integer'},
      'selector': <String, dynamic>{
        'type': 'object',
        'additionalProperties': false,
        'properties': <String, dynamic>{
          'name': <String, dynamic>{'type': 'string'},
          'automation_id': <String, dynamic>{'type': 'string'},
          'class_name': <String, dynamic>{'type': 'string'},
          'localized_control_type': <String, dynamic>{'type': 'string'},
          'contains': <String, dynamic>{'type': 'string'},
        },
      },
      'max_depth': <String, dynamic>{
        'type': 'integer',
        'minimum': 0,
        'maximum': 12,
      },
      'max_nodes': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 5000,
      },
    },
  },
);

const _ocrRecognizeTool = _ToolSpec(
  name: WindowsOpsToolNames.ocrRecognize,
  description: '使用本地 OCR 模型识别图片文字，默认返回压缩后的文本行摘要。只有 OCR bundle 和推理运行链就绪时才会注册。',
  parameters: <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': <String, dynamic>{
      'image_base64': <String, dynamic>{
        'type': 'string',
        'description': '待识别图片的 base64 编码',
      },
      'language': <String, dynamic>{'type': 'string'},
      'model_path': <String, dynamic>{'type': 'string'},
      'max_lines': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 200,
        'description': '最多返回多少行 OCR 文字，默认 40',
      },
      'include_words': <String, dynamic>{
        'type': 'boolean',
        'description': '是否附带单词级识别结果。默认 false',
      },
      'include_raw': <String, dynamic>{
        'type': 'boolean',
        'description': '是否返回 sidecar 原始 OCR 结果。默认 false',
      },
    },
    'required': <String>['image_base64'],
  },
);

const _uiParseTool = _ToolSpec(
  name: WindowsOpsToolNames.uiParse,
  description:
      '使用本地界面识别模型和 OCR 解析截图，返回高密度界面观察摘要、可点击候选和主要文字。可直接传 x/y/width/height 截图区域，不必先调用截图工具返回 base64。',
  parameters: <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': <String, dynamic>{
      'image_base64': <String, dynamic>{
        'type': 'string',
        'description': '待解析图片 base64。也可以改传 x/y/width/height 让工具自动截图',
      },
      'x': <String, dynamic>{'type': 'integer', 'description': '截图区域左上角 X'},
      'y': <String, dynamic>{'type': 'integer', 'description': '截图区域左上角 Y'},
      'width': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 8192,
      },
      'height': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 8192,
      },
      'return_annotated_image': <String, dynamic>{'type': 'boolean'},
      'box_threshold': <String, dynamic>{'type': 'number'},
      'iou_threshold': <String, dynamic>{'type': 'number'},
      'use_paddleocr': <String, dynamic>{'type': 'boolean'},
      'ocr_text_threshold': <String, dynamic>{'type': 'number'},
      'imgsz': <String, dynamic>{'type': 'integer'},
      'batch_size': <String, dynamic>{'type': 'integer'},
      'use_local_semantics': <String, dynamic>{'type': 'boolean'},
      'max_elements': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 300,
        'description': '压缩结果最多返回多少个元素，默认 60',
      },
      'max_text_lines': <String, dynamic>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 200,
        'description': '最多返回多少行 OCR 文本，默认 40',
      },
      'include_raw': <String, dynamic>{
        'type': 'boolean',
        'description': '是否返回 sidecar 原始解析结果。默认 false',
      },
    },
  },
);

const _pointSchema = <String, dynamic>{
  'type': 'object',
  'additionalProperties': false,
  'properties': <String, dynamic>{
    'x': <String, dynamic>{'type': 'integer'},
    'y': <String, dynamic>{'type': 'integer'},
  },
  'required': <String>['x', 'y'],
};
