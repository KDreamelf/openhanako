import '../llm/provider.dart';
import '../llm/tool_format/prompt_tool.dart';
import 'windows_ops_capabilities.dart';
import 'windows_ops_client.dart';

class WindowsOpsToolNames {
  const WindowsOpsToolNames._();

  static const captureRegion = 'windows_capture_region';
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
  ) {
    return switch (name) {
      WindowsOpsToolNames.captureRegion => client.call(
        'screen.capture_region',
        params: _captureRegionParams(arguments),
      ),
      WindowsOpsToolNames.uiaTree => client.call(
        'uia.tree',
        params: _uiaParams(arguments),
      ),
      WindowsOpsToolNames.uiaInvoke => client.call(
        'uia.invoke',
        params: _uiaParams(arguments),
      ),
      WindowsOpsToolNames.ocrRecognize => client.call(
        'ocr.recognize',
        params: _ocrParams(arguments),
      ),
      WindowsOpsToolNames.uiParse => client.call(
        'ui.parse_base64',
        params: _uiParseParams(arguments),
      ),
      _ => throw ArgumentError.value(name, 'name', '未知 Windows 操作工具'),
    };
  }
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

Map<String, dynamic> _uiParseParams(Map<String, dynamic> args) {
  final imageBase64 = args['image_base64'];
  if (imageBase64 is! String || imageBase64.isEmpty) {
    throw ArgumentError.value(
      imageBase64,
      'image_base64',
      '界面识别工具需要 image_base64',
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
  description: '截取 Windows 屏幕局部区域，返回 PNG 的 base64 数据。',
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
    },
    'required': <String>['x', 'y', 'width', 'height'],
  },
);

const _uiaTreeTool = _ToolSpec(
  name: WindowsOpsToolNames.uiaTree,
  description: '读取 Windows UI Automation 控件树，用于理解当前桌面或指定窗口的控件结构。',
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
  description: '使用本地 OCR 模型识别图片文字。只有 OCR bundle 和推理运行链就绪时才会注册。',
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
    },
    'required': <String>['image_base64'],
  },
);

const _uiParseTool = _ToolSpec(
  name: WindowsOpsToolNames.uiParse,
  description: '使用本地界面识别模型解析截图中的可交互元素。只有模型实际可运行时才会注册。',
  parameters: <String, dynamic>{
    'type': 'object',
    'additionalProperties': false,
    'properties': <String, dynamic>{
      'image_base64': <String, dynamic>{'type': 'string'},
      'return_annotated_image': <String, dynamic>{'type': 'boolean'},
      'box_threshold': <String, dynamic>{'type': 'number'},
      'iou_threshold': <String, dynamic>{'type': 'number'},
      'use_paddleocr': <String, dynamic>{'type': 'boolean'},
      'ocr_text_threshold': <String, dynamic>{'type': 'number'},
      'imgsz': <String, dynamic>{'type': 'integer'},
      'batch_size': <String, dynamic>{'type': 'integer'},
      'use_local_semantics': <String, dynamic>{'type': 'boolean'},
    },
    'required': <String>['image_base64'],
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
