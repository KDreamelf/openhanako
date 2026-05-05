import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class WindowsOpsClient {
  WindowsOpsClient({
    String? sidecarPath,
    Map<String, String>? environment,
    Directory? workingDirectory,
    Duration requestTimeout = const Duration(seconds: 30),
  }) : _sidecarPath = sidecarPath,
       _environment = environment,
       _workingDirectory = workingDirectory,
       _requestTimeout = requestTimeout;

  final String? _sidecarPath;
  final Map<String, String>? _environment;
  final Directory? _workingDirectory;
  final Duration _requestTimeout;

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 1;

  bool get isRunning => _process != null;

  Future<void> ensureStarted() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('WindowsOpsClient 仅在 Windows 上可用');
    }
    if (_process != null) {
      return;
    }

    final executable = await _resolveSidecarExecutable();
    final process = await Process.start(
      executable,
      const [],
      workingDirectory: _workingDirectory?.path,
      runInShell: false,
      includeParentEnvironment: true,
      environment: _environment,
    );

    _process = process;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleResponseLine, onDone: _handleProcessExit);
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[windows-ops] $line'));
  }

  Future<void> dispose() async {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Windows ops sidecar 已关闭'));
      }
    }
    _pending.clear();

    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;

    _process?.kill(ProcessSignal.sigterm);
    _process = null;
  }

  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic> params = const <String, dynamic>{},
  }) async {
    await ensureStarted();
    final process = _process;
    if (process == null) {
      throw StateError('Windows ops sidecar 未启动');
    }

    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    process.stdin.writeln(
      jsonEncode(<String, dynamic>{
        'id': id,
        'method': method,
        'params': params,
      }),
    );

    return completer.future.timeout(
      _requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('Windows ops 请求超时: $method');
      },
    );
  }

  Future<Map<String, dynamic>> ping() {
    return call('ping');
  }

  Future<Map<String, dynamic>> describeProtocol() {
    return call('protocol.describe');
  }

  Future<Uint8List> captureRegionPng({
    required int x,
    required int y,
    required int width,
    required int height,
  }) async {
    final result = await call(
      'screen.capture_region',
      params: <String, dynamic>{
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      },
    );
    final encoded = result['data'];
    if (encoded is! String || encoded.isEmpty) {
      throw StateError('screen.capture_region 未返回图像数据');
    }
    return base64Decode(encoded);
  }

  Future<Map<String, dynamic>> queryUiaTree({
    String? root,
    String? view,
    int? x,
    int? y,
    int? hwnd,
    int? maxDepth,
    int? maxNodes,
  }) {
    final params = <String, dynamic>{};
    if (root != null) {
      params['root'] = root;
    }
    if (view != null) {
      params['view'] = view;
    }
    if (x != null && y != null) {
      params['point'] = <String, dynamic>{'x': x, 'y': y};
    }
    if (hwnd != null) {
      params['hwnd'] = hwnd;
    }
    if (maxDepth != null) {
      params['max_depth'] = maxDepth;
    }
    if (maxNodes != null) {
      params['max_nodes'] = maxNodes;
    }
    return call('uia.tree', params: params);
  }

  Future<Map<String, dynamic>> invokeUia({
    Map<String, dynamic>? selector,
    String? root,
    String? view,
    int? x,
    int? y,
    int? hwnd,
    int? maxDepth,
    int? maxNodes,
  }) {
    final params = <String, dynamic>{};
    if (selector != null) {
      params['selector'] = selector;
    }
    if (root != null) {
      params['root'] = root;
    }
    if (view != null) {
      params['view'] = view;
    }
    if (x != null && y != null) {
      params['point'] = <String, dynamic>{'x': x, 'y': y};
    }
    if (hwnd != null) {
      params['hwnd'] = hwnd;
    }
    if (maxDepth != null) {
      params['max_depth'] = maxDepth;
    }
    if (maxNodes != null) {
      params['max_nodes'] = maxNodes;
    }
    return call('uia.invoke', params: params);
  }

  Future<Map<String, dynamic>> recognizeOcr({
    required Uint8List imageBytes,
    String? language,
    String? modelPath,
  }) {
    final params = <String, dynamic>{'image_base64': base64Encode(imageBytes)};
    if (language != null) {
      params['language'] = language;
    }
    if (modelPath != null) {
      params['model_path'] = modelPath;
    }
    return call('ocr.recognize', params: params);
  }

  Future<Map<String, dynamic>> ocrStatus({
    String? root,
    bool load = true,
  }) {
    final params = <String, dynamic>{};
    if (root != null) {
      params['root'] = root;
    }
    params['load'] = load;
    return call('ocr.status', params: params);
  }

  Future<Map<String, dynamic>> uiParserStatus({bool load = true}) {
    return call('ui.status', params: <String, dynamic>{'load': load});
  }

  Future<Map<String, dynamic>> parseUiBase64({
    required String imageBase64,
    bool returnAnnotatedImage = false,
    double? boxThreshold,
    double iouThreshold = 0.7,
    bool usePaddleOcr = false,
    double ocrTextThreshold = 0.8,
    int? imgsz,
    int batchSize = 64,
    bool useLocalSemantics = true,
  }) {
    final params = <String, dynamic>{
      'image_base64': imageBase64,
      'return_annotated_image': returnAnnotatedImage,
      'iou_threshold': iouThreshold,
      'use_paddleocr': usePaddleOcr,
      'ocr_text_threshold': ocrTextThreshold,
      'batch_size': batchSize,
      'use_local_semantics': useLocalSemantics,
    };
    if (boxThreshold != null) {
      params['box_threshold'] = boxThreshold;
    }
    if (imgsz != null) {
      params['imgsz'] = imgsz;
    }
    return call('ui.parse_base64', params: params);
  }

  void _handleResponseLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(line);
    } catch (err) {
      stderr.writeln('[windows-ops] 无法解析回包: $err');
      return;
    }

    if (decoded is! Map<String, dynamic>) {
      stderr.writeln('[windows-ops] 回包格式不正确: $line');
      return;
    }

    final id = decoded['id'];
    if (id is! int) {
      stderr.writeln('[windows-ops] 回包缺少 id: $line');
      return;
    }

    final completer = _pending.remove(id);
    if (completer == null) {
      return;
    }

    if (decoded['ok'] == true) {
      final result = decoded['result'];
      if (result is Map<String, dynamic>) {
        completer.complete(result);
      } else if (result is Map) {
        completer.complete(result.cast<String, dynamic>());
      } else {
        completer.complete(<String, dynamic>{});
      }
      return;
    }

    final error = decoded['error'];
    if (error is Map) {
      completer.completeError(
        WindowsOpsException(
          code: error['code']?.toString() ?? 'windows_ops_error',
          message: error['message']?.toString() ?? 'Windows ops sidecar 报错',
          details: error['details'],
        ),
      );
      return;
    }

    completer.completeError(
      const WindowsOpsException(
        code: 'windows_ops_error',
        message: 'Windows ops sidecar 报错',
      ),
    );
  }

  void _handleProcessExit() {
    final exception = WindowsOpsException(
      code: 'sidecar_exit',
      message: 'Windows ops sidecar 已退出',
    );
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(exception);
      }
    }
    _pending.clear();
    _process = null;
  }

  Future<String> _resolveSidecarExecutable() async {
    final explicit = _sidecarPath?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      final file = File(explicit);
      if (await file.exists()) {
        return file.path;
      }
      throw FileSystemException('找不到指定的 sidecar', explicit);
    }

    final exeName = 'hanako_windows_ops_sidecar.exe';
    final separator = Platform.pathSeparator;
    final appDir = _appDirectory().path;
    final currentDir = Directory.current.path;
    final candidates = <String>[
      ..._environmentCandidate(),
      [appDir, 'native', 'windows_ops', exeName].join(separator),
      [appDir, exeName].join(separator),
      [
        currentDir,
        'native',
        'windows_ops_sidecar',
        'target',
        'release',
        exeName,
      ].join(separator),
      [
        currentDir,
        'native',
        'windows_ops_sidecar',
        'target',
        'debug',
        exeName,
      ].join(separator),
      [
        currentDir,
        'build',
        'windows',
        'x64',
        'runner',
        'Release',
        'native',
        'windows_ops',
        exeName,
      ].join(separator),
    ];

    for (final candidate in candidates) {
      if (candidate.isEmpty) {
        continue;
      }
      if (await File(candidate).exists()) {
        return candidate;
      }
    }

    throw FileSystemException('未找到 Windows ops sidecar 可执行文件');
  }

  List<String> _environmentCandidate() {
    final value = Platform.environment['HANAKO_WINDOWS_OPS_SIDECAR_PATH'];
    if (value == null || value.trim().isEmpty) {
      return const <String>[];
    }
    return <String>[value.trim()];
  }

  Directory _appDirectory() {
    final executable = File(Platform.resolvedExecutable);
    return executable.parent;
  }
}

class WindowsOpsException implements Exception {
  const WindowsOpsException({
    required this.code,
    required this.message,
    this.details,
  });

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'WindowsOpsException($code): $message';
}
