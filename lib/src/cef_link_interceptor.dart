import 'package:flutter/material.dart';

import 'cef_browser_window.dart';

/// 非白名单链接的处理回调（通常用于跳系统浏览器）。
typedef CefExternalLinkHandler = void Function(String url);

/// 全局链接拦截器：统一接管 App 内所有可点击的 http/https 链接。
///
/// 业务流程（对标微信桌面端）：
///  1. App 内任意可点击链接统一调用 [open]；
///  2. [open] 做白名单校验：命中 → 唤起内嵌浏览器独立窗口；
///     未命中 → 走 [onExternal]（可选跳系统浏览器，或直接拦截丢弃）。
class CefLinkInterceptor {
  CefLinkInterceptor._();
  static final CefLinkInterceptor instance = CefLinkInterceptor._();

  final List<_HostPattern> _whitelist = [];
  CefExternalLinkHandler? _onExternal;

  /// 未命中白名单时是否仍允许打开内嵌浏览器（false=严格白名单）。
  bool allowNonWhitelisted = false;

  /// 配置白名单与外链处理。
  ///
  /// [whitelist] 支持：
  ///  - 精确域名：`example.com`
  ///  - 通配子域：`example.com`
  ///  - 全量放行：`*`
  void configure({
    required List<String> whitelist,
    CefExternalLinkHandler? onExternal,
    bool allowNonWhitelisted = false,
  }) {
    _whitelist
      ..clear()
      ..addAll(whitelist.map(_HostPattern.parse));
    _onExternal = onExternal;
    this.allowNonWhitelisted = allowNonWhitelisted;
  }

  /// 是否为需要拦截的 http/https 链接。
  bool isHttpLink(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  /// 链接是否命中白名单。
  bool isWhitelisted(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return false;
    return _whitelist.any((p) => p.matches(uri.host));
  }

  /// 统一入口：根据白名单决定唤起内嵌浏览器还是走外链处理。
  ///
  /// 返回 true 表示已由内嵌浏览器接管。
  Future<bool> open(
    BuildContext context,
    String url, {
    String? title,
    bool asWindow = true,
  }) async {
    if (!isHttpLink(url)) {
      _onExternal?.call(url);
      return false;
    }

    final whitelisted = isWhitelisted(url);
    if (whitelisted || allowNonWhitelisted) {
      await CefBrowserWindow.open(
        context,
        initialUrl: url,
        title: title,
        asSeparateWindow: asWindow,
      );
      return true;
    }

    _onExternal?.call(url);
    return false;
  }

  /// 便捷方法：生成可直接挂到富文本 / 按钮上的点击回调。
  VoidCallback linkTap(BuildContext context, String url, {String? title}) {
    return () => open(context, url, title: title);
  }
}

/// 单条白名单域名模式。
class _HostPattern {
  _HostPattern._(this._matchAll, this._suffix, this._exact);

  final bool _matchAll;
  final String? _suffix; // `*.example.com` -> `.example.com`，同时匹配 `example.com`
  final String? _exact;

  factory _HostPattern.parse(String raw) {
    final p = raw.trim().toLowerCase();
    if (p == '*') return _HostPattern._(true, null, null);
    if (p.startsWith('*.')) {
      return _HostPattern._(false, p.substring(1), p.substring(2));
    }
    return _HostPattern._(false, null, p);
  }

  bool matches(String host) {
    host = host.toLowerCase();
    if (_matchAll) return true;
    if (_exact != null && host == _exact) return true;
    if (_suffix != null && host.endsWith(_suffix!)) return true;
    return false;
  }
}
