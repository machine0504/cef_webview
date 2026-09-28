import 'dart:async';

import 'package:flutter/material.dart';

import 'cef_runtime_manager.dart';
import 'cef_webview_manager.dart';

/// 包裹任何「使用 CEF」的内容：当 CEF 运行时未就绪时显示温馨提示与下载入口；
/// 就绪且本进程已初始化后显示 [child]。在所有用到内嵌浏览器的地方包一层即可，
/// 满足「在所有使用 CEF 的地方打温馨提示，下载完成后重启即可使用」。
///
/// 前置：App 启动早期调用一次
/// `CefRuntimeManager.instance.configure(manifestUrl: 'https://.../manifest.json')`。
///
/// ```dart
/// CefRuntimeGate(child: CefWebviewWidget(controller: controller))
/// ```
class CefRuntimeGate extends StatefulWidget {
  const CefRuntimeGate({
    super.key,
    required this.child,
    this.placeholderBuilder,
  });

  /// CEF 就绪后展示的真实内容（通常是 webview）。
  final Widget child;

  /// 自定义未就绪占位。回调提供当前状态与触发下载的方法；为空时用内置中文占位。
  final Widget Function(
    BuildContext context,
    CefRuntimeState state,
    Future<void> Function() startDownload,
  )? placeholderBuilder;

  @override
  State<CefRuntimeGate> createState() => _CefRuntimeGateState();
}

class _CefRuntimeGateState extends State<CefRuntimeGate> {
  late CefRuntimeState _state;
  StreamSubscription<CefRuntimeState>? _sub;

  @override
  void initState() {
    super.initState();
    _state = CefRuntimeManager.instance.state;
    _sub = CefRuntimeManager.instance.stream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    // 启动探测（不自动下载）。
    CefRuntimeManager.instance.resolveReadyRoot();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _download() => CefRuntimeManager.instance.download();

  @override
  Widget build(BuildContext context) {
    // 本进程已成功初始化（上次已下载、本次启动加载成功）→ 直接显示内容。
    if (CefWebview.isInitialized) return widget.child;
    if (widget.placeholderBuilder != null) {
      return widget.placeholderBuilder!(context, _state, _download);
    }
    return _DefaultPlaceholder(state: _state, onDownload: _download);
  }
}

class _DefaultPlaceholder extends StatelessWidget {
  const _DefaultPlaceholder({required this.state, required this.onDownload});

  final CefRuntimeState state;
  final Future<void> Function() onDownload;

  @override
  Widget build(BuildContext context) {
    late final Widget body;
    switch (state.status) {
      case CefRuntimeStatus.downloading:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_download_outlined, size: 48),
          const SizedBox(height: 12),
          Text('正在下载浏览器组件… ${(state.progress * 100).toStringAsFixed(0)}%'),
          const SizedBox(height: 12),
          SizedBox(
            width: 240,
            child: LinearProgressIndicator(
                value: state.progress > 0 ? state.progress : null),
          ),
        ]);
        break;
      case CefRuntimeStatus.verifying:
      case CefRuntimeStatus.extracting:
        body = Column(mainAxisSize: MainAxisSize.min, children: const [
          Icon(Icons.settings_suggest_outlined, size: 48),
          SizedBox(height: 12),
          Text('正在校验并安装浏览器组件…'),
        ]);
        break;
      case CefRuntimeStatus.ready:
        // 运行时已就绪，但本进程启动时尚未加载（下载发生在本次运行中）→ 引导重启。
        body = Column(mainAxisSize: MainAxisSize.min, children: const [
          Icon(Icons.check_circle_outline, size: 48),
          SizedBox(height: 12),
          Text('浏览器组件已就绪，请重启应用后使用。', textAlign: TextAlign.center),
        ]);
        break;
      case CefRuntimeStatus.error:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 12),
          Text('浏览器组件下载失败：${state.message ?? ''}',
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {
              onDownload();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ]);
        break;
      case CefRuntimeStatus.unknown:
      case CefRuntimeStatus.notInstalled:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.public_off, size: 48),
          const SizedBox(height: 12),
          const Text('需要下载浏览器组件后才能显示网页内容。',
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {
              onDownload();
            },
            icon: const Icon(Icons.download),
            label: const Text('立即下载'),
          ),
        ]);
        break;
    }
    return Center(child: Padding(padding: const EdgeInsets.all(24), child: body));
  }
}

/// 放在标签栏右侧的「下载浏览器组件」入口：订阅运行时状态，未就绪时显示下载按钮，
/// 下载中显示进度，就绪后隐藏。点击触发下载，完成后提示重启。
class CefDownloadButton extends StatefulWidget {
  const CefDownloadButton({super.key, this.compact = true});

  /// 紧凑模式（仅图标 + 小进度），适合标签栏。
  final bool compact;

  @override
  State<CefDownloadButton> createState() => _CefDownloadButtonState();
}

class _CefDownloadButtonState extends State<CefDownloadButton> {
  late CefRuntimeState _state;
  StreamSubscription<CefRuntimeState>? _sub;

  @override
  void initState() {
    super.initState();
    _state = CefRuntimeManager.instance.state;
    _sub = CefRuntimeManager.instance.stream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    CefRuntimeManager.instance.resolveReadyRoot();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;

    // 本进程已可用：无需展示入口。
    if (CefWebview.isInitialized) return const SizedBox.shrink();

    switch (s.status) {
      case CefRuntimeStatus.downloading:
        final pct = (s.progress * 100).toStringAsFixed(0);
        return Tooltip(
          message: '正在下载浏览器组件 $pct%',
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, value: s.progress > 0 ? s.progress : null),
          ),
        );
      case CefRuntimeStatus.verifying:
      case CefRuntimeStatus.extracting:
        return const Tooltip(
          message: '正在安装浏览器组件…',
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        );
      case CefRuntimeStatus.ready:
        return const Tooltip(
          message: '浏览器组件已就绪，请重启应用后使用',
          child: Icon(Icons.check_circle, size: 22),
        );
      case CefRuntimeStatus.error:
      case CefRuntimeStatus.unknown:
      case CefRuntimeStatus.notInstalled:
        final label = s.status == CefRuntimeStatus.error ? '下载失败，点击重试' : '下载浏览器组件';
        if (widget.compact) {
          return IconButton(
            tooltip: label,
            icon: const Icon(Icons.download_for_offline_outlined),
            onPressed: () => CefRuntimeManager.instance.download(),
          );
        }
        return TextButton.icon(
          icon: const Icon(Icons.download_for_offline_outlined),
          label: Text(label),
          onPressed: () => CefRuntimeManager.instance.download(),
        );
    }
  }
}
