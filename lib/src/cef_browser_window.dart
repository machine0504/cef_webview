import 'dart:async';

import 'package:flutter/material.dart';

import 'cef_webview_controller.dart';
import 'cef_webview_widget.dart';
import 'models/cef_load_error.dart';

/// 内嵌浏览器“独立窗口”页面：地址栏 + 加载进度 + 前进/后退/刷新/关闭 + 错误页。
///
/// 在单 Flutter 引擎下，这里以全屏路由的形式呈现（对标微信内置浏览器的体验）。
/// 若需要真正的独立 OS 窗口，可结合 `desktop_multi_window` 在新窗口中挂载本组件，
/// 详见 docs/PACKAGING.md「多窗口」章节。
class CefBrowserWindow extends StatefulWidget {
  const CefBrowserWindow({
    super.key,
    required this.initialUrl,
    this.title,
    this.onClose,
  });

  final String initialUrl;
  final String? title;
  final VoidCallback? onClose;

  /// 打开内嵌浏览器。[asSeparateWindow] 预留：true 时走独立窗口（多窗口插件可用），
  /// 当前实现统一以全屏路由呈现。
  static Future<void> open(
    BuildContext context, {
    required String initialUrl,
    String? title,
    bool asSeparateWindow = true,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            CefBrowserWindow(initialUrl: initialUrl, title: title),
      ),
    );
  }

  @override
  State<CefBrowserWindow> createState() => _CefBrowserWindowState();
}

class _CefBrowserWindowState extends State<CefBrowserWindow> {
  CefWebviewController? _controller;
  final TextEditingController _addressCtrl = TextEditingController();
  StreamSubscription<CefLoadError>? _errSub;

  CefLoadError? _error;
  Object? _createError;

  @override
  void initState() {
    super.initState();
    _addressCtrl.text = widget.initialUrl;
    _createController();
  }

  Future<void> _createController() async {
    try {
      final size = MediaQuery.maybeOf(context)?.size ?? const Size(1024, 768);
      final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
      final c = await CefWebviewController.create(
        url: widget.initialUrl,
        width: size.width.round(),
        height: (size.height - _kChromeHeight).round(),
        devicePixelRatio: dpr,
      );
      _errSub = c.onLoadError.listen((e) {
        if (!e.isAborted && mounted) setState(() => _error = e);
      });
      c.navigation.addListener(_onNav);
      if (mounted) setState(() => _controller = c);
    } catch (e) {
      if (mounted) setState(() => _createError = e);
    }
  }

  void _onNav() {
    final nav = _controller?.navigation.value;
    if (nav == null) return;
    if (!_addressCtrl.text.contains(nav.url) && nav.url.isNotEmpty) {
      _addressCtrl.text = nav.url;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _errSub?.cancel();
    _controller?.navigation.removeListener(_onNav);
    _controller?.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  void _submitAddress(String value) {
    var url = value.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    setState(() => _error = null);
    _controller?.loadUrl(url);
  }

  void _close() {
    widget.onClose?.call();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final nav = _controller?.navigation.value;
    final theme = Theme.of(context);

    return Scaffold(
      body: Column(
        children: [
          _buildToolbar(theme),
          if (nav?.isLoading ?? false)
            LinearProgressIndicator(
              value: (nav!.progress > 0 && nav.progress < 1)
                  ? nav.progress
                  : null,
              minHeight: 2,
            )
          else
            const SizedBox(height: 2),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    final canBack = (_controller?.navigation.value.canGoBack) ?? false;
    final canFwd = (_controller?.navigation.value.canGoForward) ?? false;
    final loading = (_controller?.navigation.value.isLoading) ?? false;

    return Material(
      elevation: 1,
      child: Container(
        height: _kChromeHeight,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: '后退',
              onPressed: canBack ? _controller!.goBack : null,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              tooltip: '前进',
              onPressed: canFwd ? _controller!.goForward : null,
            ),
            IconButton(
              icon: Icon(loading ? Icons.close : Icons.refresh),
              tooltip: loading ? '停止' : '刷新',
              onPressed: _controller == null
                  ? null
                  : (loading ? _controller!.stopLoad : _controller!.reload),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: _addressCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceVariant.withOpacity(0.4),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  prefixIcon: const Icon(Icons.lock_outline, size: 16),
                ),
                onSubmitted: _submitAddress,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '关闭',
              onPressed: _close,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_createError != null) {
      return _ErrorView(
        title: '内嵌浏览器初始化失败',
        detail: '$_createError',
        onRetry: () {
          setState(() => _createError = null);
          _createController();
        },
      );
    }
    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        CefWebviewWidget(controller: _controller!),
        if (_error != null)
          _ErrorView(
            title: '网页无法打开',
            detail: '${_error!.errorText}\n(${_error!.errorCode})\n${_error!.failedUrl}',
            onRetry: () {
              setState(() => _error = null);
              _controller!.reload();
            },
          ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.title, required this.detail, this.onRetry});

  final String title;
  final String detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off,
              size: 64, color: Theme.of(context).disabledColor),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(detail,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 24),
          if (onRetry != null)
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
        ],
      ),
    );
  }
}

const double _kChromeHeight = 52;
