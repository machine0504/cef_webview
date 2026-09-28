import 'dart:collection';
import 'dart:ui' show FontFeature, FramePhase;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 性能探针浮层：统计宿主 Flutter 帧（含 CEF 外部纹理合成）的 build / raster
/// 耗时与估算 FPS，用于 CEF 渲染管线升级（软件 OSR → GPU 零拷贝）前后的相对
/// 基线对比。
///
/// 用法：叠在 [CefWebviewWidget] 之上（Stack），在同样的页面 / 操作下记录升级
/// 前后的读数即可横向比较。
///
/// 注意：此处测量的是「Flutter 侧栅格化」的整体流畅度，反映的是上屏这一段
/// （纹理合成 + 光栅）的开销；CEF native 侧 OnPaint/OnFrame 的精确帧率与单帧
/// BGRA→RGBA 转换耗时属于原生管线，会在 Phase 2 随 MethodChannel 扩展一个
/// debug 事件后并入本浮层。
class PerfOverlay extends StatefulWidget {
  const PerfOverlay({
    super.key,
    this.sampleSize = 90,
    this.alignment = Alignment.topRight,
  });

  /// 滑动窗口保留的帧数（约 1.5 秒 @60fps）。
  final int sampleSize;

  /// 浮层对齐位置。
  final Alignment alignment;

  @override
  State<PerfOverlay> createState() => _PerfOverlayState();
}

class _PerfOverlayState extends State<PerfOverlay> {
  final Queue<FrameTiming> _window = Queue<FrameTiming>();
  bool _visible = true;

  double _fps = 0;
  double _avgBuildMs = 0;
  double _avgRasterMs = 0;
  double _maxTotalMs = 0;
  int _jank = 0; // 窗口内超过 ~16.7ms 的帧数

  int _lastReportUs = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _window.addLast(t);
      while (_window.length > widget.sampleSize) {
        _window.removeFirst();
      }
    }
    if (_window.length < 2) return;

    // 节流刷新（~4 次/秒），避免 setState 自身污染测量与增加负载。
    final nowUs =
        timings.last.timestampInMicroseconds(FramePhase.rasterFinish);
    if (nowUs - _lastReportUs < 250000) return;
    _lastReportUs = nowUs;

    int buildSum = 0;
    int rasterSum = 0;
    int maxTotal = 0;
    int jank = 0;
    for (final t in _window) {
      buildSum += t.buildDuration.inMicroseconds;
      rasterSum += t.rasterDuration.inMicroseconds;
      final total = t.totalSpan.inMicroseconds;
      if (total > maxTotal) maxTotal = total;
      if (total > 16700) jank++;
    }
    final n = _window.length;
    final firstVsync =
        _window.first.timestampInMicroseconds(FramePhase.vsyncStart);
    final lastVsync =
        _window.last.timestampInMicroseconds(FramePhase.vsyncStart);
    final spanUs = (lastVsync - firstVsync).abs();
    final fps = spanUs > 0 ? (n - 1) * 1e6 / spanUs : 0.0;

    if (!mounted) return;
    setState(() {
      _fps = fps;
      _avgBuildMs = buildSum / n / 1000.0;
      _avgRasterMs = rasterSum / n / 1000.0;
      _maxTotalMs = maxTotal / 1000.0;
      _jank = jank;
    });
  }

  Color get _fpsColor {
    if (_fps >= 55) return Colors.greenAccent;
    if (_fps >= 30) return Colors.amberAccent;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: widget.alignment,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: _visible
            ? _buildPanel()
            : IconButton.filledTonal(
                onPressed: () => setState(() => _visible = true),
                icon: const Icon(Icons.speed, size: 18),
                tooltip: '显示性能探针',
              ),
      ),
    );
  }

  Widget _buildPanel() {
    TextStyle line(Color c) => TextStyle(
          color: c,
          fontSize: 12,
          fontFeatures: const [FontFeature.tabularFigures()],
          fontFamilyFallback: const ['monospace'],
        );
    return Material(
      color: Colors.black.withOpacity(0.62),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('性能探针 (Flutter 上屏)', style: line(Colors.white70)),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => setState(() => _visible = false),
                  child: const Icon(Icons.close, size: 14, color: Colors.white54),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('FPS      ${_fps.toStringAsFixed(1)}', style: line(_fpsColor)),
            Text('build    ${_avgBuildMs.toStringAsFixed(2)} ms',
                style: line(Colors.white)),
            Text('raster   ${_avgRasterMs.toStringAsFixed(2)} ms',
                style: line(Colors.white)),
            Text('maxFrame ${_maxTotalMs.toStringAsFixed(1)} ms',
                style: line(Colors.white70)),
            Text('jank     $_jank / ${_window.length}',
                style: line(_jank > 0 ? Colors.amberAccent : Colors.white70)),
          ],
        ),
      ),
    );
  }
}
