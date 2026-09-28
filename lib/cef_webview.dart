/// CEF 99 + OSR 离屏渲染 Flutter 桌面内嵌浏览器插件。
///
/// 三端（Windows / macOS / Linux）统一 API，Dart 业务层无需区分平台：
///
/// ```dart
/// // 1. 应用启动时初始化（main 中尽早调用）
/// await CefWebview.ensureInitialized();
///
/// // 2. 让全局链接拦截器接管 App 内 http/https 点击
/// CefLinkInterceptor.instance.configure(
///   whitelist: ['example.com', 'example.com'],
///   onExternal: (url) => launchUrl(Uri.parse(url)), // 非白名单可选跳系统浏览器
/// );
///
/// // 3. 用拦截器打开链接 —— 命中白名单则唤起内嵌浏览器独立窗口
/// CefLinkInterceptor.instance.open(context, 'https://example.com');
/// ```
library cef_webview;

export 'src/cef_webview_manager.dart'
    show CefWebview, CefInitOptions, CefLogSeverity;
export 'src/cef_runtime_manager.dart'
    show CefRuntimeManager, CefRuntimeState, CefRuntimeStatus;
export 'src/cef_runtime_gate.dart' show CefRuntimeGate, CefDownloadButton;
export 'src/cef_webview_controller.dart';
export 'src/cef_webview_widget.dart';
export 'src/cef_link_interceptor.dart';
export 'src/cef_browser_window.dart';
export 'src/cef_webview_compat.dart'
    show kCefCompatShimJs, kCefFileMimeFixJs;
export 'src/models/cef_navigation_state.dart';
export 'src/models/cef_load_error.dart';
export 'src/models/cef_settings.dart';
