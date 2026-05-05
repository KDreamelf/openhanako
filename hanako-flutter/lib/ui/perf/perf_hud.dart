import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 内置 PerfHUD（参考 flutter-migration-plan/性能优化复盘-20260207.md §5.4）。
///
/// 输出 `FPS / build / raster`，FPS 基于 FramePhase.vsyncStart 间隔计算。
/// debug + profile 模式自动显示，release 隐藏。
///
/// 使用方法：用 `Stack` + `Positioned` 叠在主页面右上角，或者放进任何 widget tree。
class PerfHud extends StatefulWidget {
  const PerfHud({super.key, this.windowSize = 60});
  final int windowSize;

  @override
  State<PerfHud> createState() => _PerfHudState();
}

class _PerfHudState extends State<PerfHud> {
  final _samples = <_FrameSample>[];
  Timer? _refreshTimer;
  String _text = '...';

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _refreshTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _recompute(),
    );
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final vsync = t.timestampInMicroseconds(FramePhase.vsyncStart);
      final buildMs = t.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = t.rasterDuration.inMicroseconds / 1000.0;
      _samples.add(_FrameSample(
        vsyncMicros: vsync,
        buildMs: buildMs,
        rasterMs: rasterMs,
      ));
      while (_samples.length > widget.windowSize) {
        _samples.removeAt(0);
      }
    }
  }

  void _recompute() {
    if (_samples.length < 2) return;

    final intervals = <double>[];
    for (var i = 1; i < _samples.length; i++) {
      final d = (_samples[i].vsyncMicros - _samples[i - 1].vsyncMicros) / 1e6;
      if (d > 0) intervals.add(d);
    }
    if (intervals.isEmpty) return;

    final avgInterval = intervals.reduce((a, b) => a + b) / intervals.length;
    final fps = 1.0 / avgInterval;

    intervals.sort();
    // 间隔越大 FPS 越低 → p5fps 用上 95% 分位的 interval
    final p5fps = 1.0 /
        intervals[(intervals.length * 0.95)
            .clamp(0, intervals.length - 1)
            .toInt()];
    final p95fps = 1.0 /
        intervals[(intervals.length * 0.05)
            .clamp(0, intervals.length - 1)
            .toInt()];

    final avgBuild =
        _samples.map((s) => s.buildMs).reduce((a, b) => a + b) /
            _samples.length;
    final avgRaster =
        _samples.map((s) => s.rasterMs).reduce((a, b) => a + b) /
            _samples.length;

    final text =
        'fps ${fps.toStringAsFixed(1)} (p5 ${p5fps.toStringAsFixed(1)} / p95 ${p95fps.toStringAsFixed(1)})\n'
        'build ${avgBuild.toStringAsFixed(2)}ms · raster ${avgRaster.toStringAsFixed(2)}ms';
    if (text != _text && mounted) {
      setState(() => _text = text);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kReleaseMode) return const SizedBox.shrink();
    return RepaintBoundary(
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            _text,
            style: const TextStyle(
              color: Colors.greenAccent,
              fontFamily: 'monospace',
              fontSize: 11,
              height: 1.25,
            ),
          ),
        ),
      ),
    );
  }
}

class _FrameSample {
  final int vsyncMicros;
  final double buildMs;
  final double rasterMs;
  const _FrameSample({
    required this.vsyncMicros,
    required this.buildMs,
    required this.rasterMs,
  });
}
