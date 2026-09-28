import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cef_runtime_manager.dart';
import 'cef_webview_controller.dart';

/// CEF 全局初始化参数。
class CefInitOptions {
  const CefInitOptions({
    this.locale = 'zh-CN',
    this.userAgentSuffix,
    this.cachePath,
    this.logSeverity = CefLogSeverity.warning,
    this.remoteDebuggingPort = 0,
    this.persistSessionCookies = true,
    this.extraCommandLineSwitches = const {},
    this.gpuSharedTexture = false,
    this.cefRoot,
  });

  /// 界面语言，影响右键菜单 / 错误页等。
  final String locale;

  /// 追加到 UA 末尾的标识，便于服务端识别本应用。
  final String? userAgentSuffix;

  /// 磁盘缓存 / Cookie 持久化目录。null 时使用应用支持目录下的 `cef_cache`。
  final String? cachePath;

  final CefLogSeverity logSeverity;

  /// >0 时开启 DevTools 远程调试端口（localhost:port）。
  final int remoteDebuggingPort;

  final bool persistSessionCookies;

  /// 透传给 CEF 的额外命令行开关（key -> value，value 为空串表示无值开关）。
  ///
  /// 例如 Linux 下常用：`{'disable-gpu': '', 'disable-gpu-compositing': ''}`。
  final Map<String, String> extraCommandLineSwitches;

  /// 是否启用 GPU 零拷贝渲染（CEF `OnAcceleratedPaint` 共享纹理）。
  ///
  /// - macOS：IOSurface 直接作为 Flutter 纹理，跳过软件合成 + 每帧全画幅 CPU 拷贝，
  ///   复杂/动画页面显著降低掉帧。**已实现**。
  /// - Windows：D3D11 共享句柄（尚未实现，置 true 无效，仍走软件路径）。
  /// - Linux：暂不支持（参考主流实现同样保留软件路径）。
  ///
  /// 默认 false（软件 OSR，最稳）。仅在原生已实现加速路径的平台生效；未实现的平台
  /// 会忽略此开关继续走软件路径，因此置 true 不会导致其它平台黑屏。
  final bool gpuSharedTexture;

  /// 运行期 CEF 运行时目录（含 libcef / framework / 资源 / 子进程）。
  ///
  /// 为空时由 [CefWebview.ensureInitialized] 自动用 [CefRuntimeManager] 探测到的就绪
  /// 目录填充；若仍为空，则 native 回退到旧的「随包同目录/Bundle」查找（开发期可用）。
  final String? cefRoot;

  Map<String, dynamic> toMap() => {
        'locale': locale,
        'userAgentSuffix': userAgentSuffix,
        'cachePath': cachePath,
        'logSeverity': logSeverity.index,
        'remoteDebuggingPort': remoteDebuggingPort,
        'persistSessionCookies': persistSessionCookies,
        'extraCommandLineSwitches': extraCommandLineSwitches,
        'gpuSharedTexture': gpuSharedTexture,
        'cefRoot': cefRoot,
      };
}

enum CefLogSeverity { verbose, info, warning, error, disable }

/// CEF 运行时全局入口：负责一次性初始化、关闭，以及把原生侧
/// （C++ → Dart）的回调路由到对应的 [CefWebviewController]。
///
/// 三端共用同一套 MethodChannel 协议：
///  - Dart → C++：`channel.invokeMethod(...)`
///  - C++ → Dart：原生侧 `channel.invokeMethod(...)`，在此 [_onNativeCall] 分发。
class CefWebview {
  CefWebview._();

  /// 主通道：业务方法调用 + 原生回调。
  static const MethodChannel channel = MethodChannel('cef_webview');

  static bool _initialized = false;
  static Completer<void>? _initCompleter;

  static bool get isInitialized => _initialized;

  /// 浏览器实例路由表：browserId -> controller。
  static final Map<int, CefWebviewController> _controllers = {};

  /// 幂等初始化。CEF 多进程模型必须在创建任何浏览器之前、且在 Flutter
  /// 主隔离区初始化期间完成（详见 docs/LINUX_TROUBLESHOOTING.md）。
  static Future<void> ensureInitialized([CefInitOptions? options]) {
    if (_initialized) return Future.value();
    if (_initCompleter != null) return _initCompleter!.future;

    final completer = Completer<void>();
    _initCompleter = completer;

    channel.setMethodCallHandler(_onNativeCall);

    () async {
      try {
        final opts = options ?? const CefInitOptions();
        final map = opts.toMap();
        // 优先用显式传入的 cefRoot；否则用运行时管理器探测到的就绪目录。
        final root =
            opts.cefRoot ?? await CefRuntimeManager.instance.resolveReadyRoot();
        if (root != null) map['cefRoot'] = root;
        await channel.invokeMethod<void>('initialize', map);
        _initialized = true;
        completer.complete();
      } catch (e, st) {
        _initCompleter = null;
        completer.completeError(e, st);
      }
    }();

    return completer.future;
  }

  /// 关闭 CEF（应用退出前调用，确保子进程优雅退出）。
  static Future<void> shutdown() async {
    if (!_initialized) return;
    for (final c in _controllers.values.toList()) {
      await c.dispose();
    }
    _controllers.clear();
    await channel.invokeMethod<void>('shutdown');
    _initialized = false;
    _initCompleter = null;
  }

  // ----- 控制器注册（由 CefWebviewController 内部调用）-------------------

  static void registerController(int browserId, CefWebviewController c) {
    _controllers[browserId] = c;
  }

  static void unregisterController(int browserId) {
    _controllers.remove(browserId);
  }

  // ----- C++ → Dart 回调分发 -------------------------------------------

  static Future<dynamic> _onNativeCall(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    final browserId = (args['browserId'] as num?)?.toInt();

    // 无 browserId 的全局事件
    if (browserId == null) {
      if (call.method == 'onCefError') {
        debugPrint('❌ [CEF] 全局错误: ${args['message']}');
      }
      return null;
    }

    final controller = _controllers[browserId];
    if (controller == null) {
      // 浏览器已被销毁但仍有在途回调，安全忽略。
      return null;
    }
    return controller.handleNativeCall(call.method, args);
  }
}
