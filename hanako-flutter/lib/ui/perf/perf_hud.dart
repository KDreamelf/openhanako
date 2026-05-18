import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../design/design.dart';

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
    final c = Theme.of(context).colorScheme;
    final fps = _samples.isEmpty ? null : _samples.last;
    final fpsGood = fps != null && fps.buildMs < 16.6 && fps.rasterMs < 16.6;
    final accent = fpsGood ? c.primary : c.tertiary;
    return RepaintBoundary(
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.surface.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: accent.withValues(alpha: 0.30),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.6),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 7),
              Text(
                _text,
                style: TextStyle(
                  color: c.onSurface.withValues(alpha: 0.78),
                  fontFamilyFallback: DS.monoFallback,
                  fontSize: 10.5,
                  height: 1.3,
                  letterSpacing: 0.2,
                ),
              ),
            ],
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
