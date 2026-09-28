import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'cef_input.dart';
import 'cef_webview_manager.dart';
import 'models/cef_load_error.dart';
import 'models/cef_navigation_state.dart';
import 'models/cef_settings.dart';

/// JS → Dart 消息回调签名。`handler` 为页面调用的处理器名，`data` 为载荷。
typedef CefJsMessageHandler = void Function(String handler, dynamic data);

/// 单个 OSR 浏览器实例的控制器。
///
/// 生命周期：[create] → 使用（[loadUrl]/[goBack]/[evaluateJavascript] …）→ [dispose]。
/// 创建成功后 [textureId] 即为 Flutter `Texture` widget 需要的纹理 ID。
class CefWebviewController {
  CefWebviewController._(this.browserId, this.textureId,
      {this.bitmapMode = false});

  /// 测试专用：构造一个不连接真实 CEF 的控制器。其方法调用仍经过
  /// [CefWebview.channel]，测试里用 mock handler 捕获并校验「事件 → 通道调用」。
  @visibleForTesting
  factory CefWebviewController.forTest({int browserId = 1, int textureId = 1}) =>
      CefWebviewController._(browserId, textureId);

  /// 原生侧 CEF 浏览器 ID（CefBrowser::GetIdentifier）。
  final int browserId;

  /// Flutter 外部纹理 ID，交给 `Texture(textureId: ...)` 渲染 OSR 画面。
  /// [bitmapMode] 为 true 时它不是纹理 ID，而是 native 位图槽编号。
  final int textureId;

  /// 是否走「位图 + ui.Image」显示路径。
  ///
  /// Flutter 软件渲染器（`FLUTTER_LINUX_RENDERER=software`）下外部纹理在 embedder 层
  /// 整体不可用，`Texture` widget 只会显示空白，必须改由 [CefBitmapView] 经 FFI 拉帧。
  /// 由 native 在 createBrowser 时告知，不在 Dart 侧猜测。
  final bool bitmapMode;

  final ValueNotifier<CefNavigationState> navigation =
      ValueNotifier<CefNavigationState>(const CefNavigationState());

  /// 当前鼠标指针形状，随网页悬停元素变化（链接=手型 / 文本=I 形 / 缩放手柄等）。
  /// OSR 下由原生 `onCursorChange` 事件驱动；[CefWebviewWidget] 的 MouseRegion
  /// 监听它以显示对应指针（默认箭头）。
  final ValueNotifier<MouseCursor> cursor =
      ValueNotifier<MouseCursor>(SystemMouseCursors.basic);

  final _loadErrorCtrl = StreamController<CefLoadError>.broadcast();
  final _jsMessageCtrl = StreamController<({String handler, dynamic data})>.broadcast();
  final _titleCtrl = StreamController<String>.broadcast();
  final _newWindowCtrl = StreamController<String>.broadcast();

  /// 加载失败事件（含证书错误聚合）。
  Stream<CefLoadError> get onLoadError => _loadErrorCtrl.stream;

  /// 页面 JS 通过 `window.cefBridge.postMessage` 发来的消息。
  Stream<({String handler, dynamic data})> get onJsMessage =>
      _jsMessageCtrl.stream;

  Stream<String> get onTitleChanged => _titleCtrl.stream;

  /// 页面试图打开新窗口/新标签（target=_blank、window.open）时的目标 URL。
  /// OSR 下默认不自动开新窗口，交由业务决定（通常再走一次链接拦截）。
  Stream<String> get onNewWindowRequested => _newWindowCtrl.stream;

  final Map<String, CefJsMessageHandler> _handlers = {};
  bool _disposed = false;

  /// 内部：IME 组字光标位置变化（逻辑像素，相对 webview 左上角）。
  /// 由 [CefWebviewWidget] 监听以把系统输入法候选框定位到光标处。
  void Function(int x, int y, int width, int height)? onImeCursorRect;

  /// 创建一个 OSR 浏览器实例。
  ///
  /// [width]/[height] 为逻辑像素，[devicePixelRatio] 用于 HiDPI 缩放，
  /// 原生侧据此分配 width*dpr × height*dpr 的 BGRA 离屏缓冲。
  static Future<CefWebviewController> create({
    required String url,
    required int width,
    required int height,
    double devicePixelRatio = 1.0,
    CefBrowserSettings settings = const CefBrowserSettings(),
  }) async {
    await CefWebview.ensureInitialized();

    final settingsMap = settings.toMap();
    // 帧率：显式配置优先，否则跟随显示器刷新率（见 _resolveWindowlessFrameRate）。
    settingsMap['windowlessFrameRate'] =
        _resolveWindowlessFrameRate(settings.windowlessFrameRate);

    final result = await CefWebview.channel.invokeMethod<Map>('createBrowser', {
      'url': url,
      'width': width,
      'height': height,
      'dpr': devicePixelRatio,
      'settings': settingsMap,
    });

    if (result == null) {
      throw StateError('CEF createBrowser 返回空结果');
    }
    final browserId = (result['browserId'] as num).toInt();
    final textureId = (result['textureId'] as num).toInt();
    final bitmapMode = result['bitmapMode'] == true;

    final controller = CefWebviewController._(browserId, textureId,
        bitmapMode: bitmapMode);
    CefWebview.registerController(browserId, controller);
    return controller;
  }

  /// 解析 OSR 帧率（fps）：显式配置（clamp 1~60）优先；否则「跟随显示器刷新率」——
  /// 取所有在线显示器中的最高刷新率，clamp 到 CEF OSR 支持的 30~60；查询失败兜底 60。
  static int _resolveWindowlessFrameRate(int? configured) {
    if (configured != null && configured > 0) {
      return configured.clamp(1, 60);
    }
    try {
      var hz = 0.0;
      for (final d in ui.PlatformDispatcher.instance.displays) {
        if (d.refreshRate.isFinite && d.refreshRate > hz) hz = d.refreshRate;
      }
      if (hz > 0) return hz.round().clamp(30, 60);
    } catch (_) {}
    return 60;
  }

  /// 以一段 HTML 字符串创建 OSR 浏览器。
  ///
  /// 内部把 [html] 写入临时目录的 `index.html` 并以 `file://` 加载——这样
  /// HTML 内引用的相对资源（放到同一临时目录即可）能正常解析，等价于
  /// inappwebview 的 `htmlContent + baseUrl`。返回的临时目录路径见
  /// [lastHtmlDir]，调用方可把资源拷进去（在加载前用 [createWithHtml] 之前自备，
  /// 或加载后 reload）。
  static Future<CefWebviewController> createWithHtml({
    required String html,
    required int width,
    required int height,
    double devicePixelRatio = 1.0,
    CefBrowserSettings settings = const CefBrowserSettings(),
  }) async {
    final url = await _writeTempHtml(html);
    final controller = await create(
      url: url,
      width: width,
      height: height,
      devicePixelRatio: devicePixelRatio,
      settings: settings,
    );
    controller._lastHtmlDir = _lastHtmlDirStatic;
    return controller;
  }

  /// 最近一次写入的临时 HTML 所在目录（用于把相对资源拷贝到旁边）。
  String? get lastHtmlDir => _lastHtmlDir;
  String? _lastHtmlDir;
  static String? _lastHtmlDirStatic;

  static Future<String> _writeTempHtml(String html) async {
    final dir = await Directory.systemTemp.createTemp('cef_html_');
    _lastHtmlDirStatic = dir.path;
    final file = File('${dir.path}${Platform.pathSeparator}index.html');
    await file.writeAsString(html, encoding: utf8);
    return file.uri.toString();
  }

  // ----- 导航控制 ------------------------------------------------------

  Future<void> loadUrl(String url) =>
      _invoke('loadUrl', {'url': url});

  /// 加载一段 HTML 字符串（替换当前内容）。内部写临时文件并 `file://` 加载，
  /// 语义同 [createWithHtml]。
  Future<void> loadHtmlString(String html) async {
    final url = await _writeTempHtml(html);
    _lastHtmlDir = _lastHtmlDirStatic;
    await loadUrl(url);
  }

  Future<void> reload() => _invoke('reload');

  Future<void> stopLoad() => _invoke('stopLoad');

  Future<void> goBack() => _invoke('goBack');

  Future<void> goForward() => _invoke('goForward');

  /// 执行一段 JS。返回值通过页面回调通道异步取回，这里仅触发执行。
  Future<void> evaluateJavascript(String source) =>
      _invoke('evaluateJavascript', {'source': source});

  /// 注册一个 JS handler：页面调用 `window.cefBridge.callHandler(name, payload)`
  /// 时会触发 [callback]。
  void addJavaScriptHandler(String name, CefJsMessageHandler callback) {
    _handlers[name] = callback;
  }

  void removeJavaScriptHandler(String name) => _handlers.remove(name);

  // ----- 视图 / 输入（由 CefWebviewWidget 调用）-------------------------

  Future<void> resize(int width, int height, double dpr) =>
      _invoke('resize', {'width': width, 'height': height, 'dpr': dpr});

  Future<void> setVisible(bool visible) =>
      _invoke('setVisible', {'visible': visible});

  Future<void> sendMouseMove(double x, double y,
          {bool leave = false, int modifiers = 0}) =>
      _invoke('mouseMove',
          {'x': x, 'y': y, 'leave': leave, 'modifiers': modifiers});

  /// [button]: 0=left 1=middle 2=right；[down] 按下/抬起；[clickCount] 连击数。
  Future<void> sendMouseButton(
    double x,
    double y, {
    required int button,
    required bool down,
    int clickCount = 1,
    int modifiers = 0,
  }) =>
      _invoke('mouseButton', {
        'x': x,
        'y': y,
        'button': button,
        'down': down,
        'clickCount': clickCount,
        'modifiers': modifiers,
      });

  Future<void> sendMouseWheel(double x, double y, double dx, double dy,
          {int modifiers = 0}) =>
      _invoke('mouseWheel',
          {'x': x, 'y': y, 'deltaX': dx, 'deltaY': dy, 'modifiers': modifiers});

  // ----- 拖拽上传（把 OS 文件拖入 webview）--------------------------------
  // 坐标与鼠标一致：逻辑像素（DIP），相对 webview 左上角，原生零换算。
  // CEF OSR 的拖拽数据在 [dragTargetDragEnter] 时提供（[paths] 为被拖文件的
  // 绝对路径，CEF 按路径自行读盘，网页得到的是带正确 name/size/type 的真 File）；
  // [dragTargetDrop] 不再携带数据，用的就是 enter 时设置的那份。

  /// 拖拽进入：携带被拖文件的绝对路径列表。
  Future<void> dragTargetDragEnter(double x, double y,
          {List<String> paths = const <String>[], int modifiers = 0}) =>
      _invoke('dragTargetDragEnter',
          {'x': x, 'y': y, 'paths': paths, 'modifiers': modifiers});

  /// 拖拽悬停移动。
  Future<void> dragTargetDragOver(double x, double y, {int modifiers = 0}) =>
      _invoke('dragTargetDragOver', {'x': x, 'y': y, 'modifiers': modifiers});

  /// 拖拽离开（未落下即移出）。
  Future<void> dragTargetDragLeave() => _invoke('dragTargetDragLeave');

  /// 落下：在 enter 设定的落点/数据上完成 drop。
  Future<void> dragTargetDrop(double x, double y, {int modifiers = 0}) =>
      _invoke('dragTargetDrop', {'x': x, 'y': y, 'modifiers': modifiers});

  /// 转发键盘事件。[type]: 0=rawKeyDown 1=keyUp 2=char。
  Future<void> sendKey({
    required int type,
    required int windowsKeyCode,
    required int nativeKeyCode,
    int modifiers = 0,
    int character = 0,
  }) =>
      _invoke('key', {
        'type': type,
        'windowsKeyCode': windowsKeyCode,
        'nativeKeyCode': nativeKeyCode,
        'modifiers': modifiers,
        'character': character,
      });

  // ----- IME（输入法组字）------------------------------------------------

  /// 设置预编辑（组字中）文本。[selectionStart]/[selectionEnd] 为组字串内的
  /// 光标/选区位置，传 -1 表示置于串末尾。
  Future<void> imeSetComposition(
    String text, {
    int selectionStart = -1,
    int selectionEnd = -1,
  }) =>
      _invoke('imeSetComposition', {
        'text': text,
        'selectionStart': selectionStart,
        'selectionEnd': selectionEnd,
      });

  /// 提交最终文本（组字完成，等价于把候选词上屏）。
  Future<void> imeCommitText(String text) =>
      _invoke('imeCommitText', {'text': text});

  /// 结束当前组字会话。
  Future<void> imeFinishComposing({bool keepSelection = true}) =>
      _invoke('imeFinishComposing', {'keepSelection': keepSelection});

  /// 取消当前组字（丢弃预编辑内容）。
  Future<void> imeCancelComposition() => _invoke('imeCancelComposition');

  Future<void> setFocus(bool focused) =>
      _invoke('setFocus', {'focused': focused});

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    CefWebview.unregisterController(browserId);
    try {
      await _invoke('closeBrowser');
    } catch (_) {
      // 退出过程中通道可能已失效，忽略。
    }
    await _loadErrorCtrl.close();
    await _jsMessageCtrl.close();
    await _titleCtrl.close();
    await _newWindowCtrl.close();
    navigation.dispose();
    cursor.dispose();
  }

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? extra]) {
    if (_disposed) return Future.value(null);
    return CefWebview.channel.invokeMethod<T>(method, {
      'browserId': browserId,
      ...?extra,
    });
  }

  // ----- C++ → Dart 回调（由 CefWebview 路由进来）-----------------------

  Future<dynamic> handleNativeCall(String method, Map args) async {
    switch (method) {
      case 'onLoadingStateChange':
        navigation.value = navigation.value.copyWith(
          isLoading: args['isLoading'] as bool? ?? false,
          canGoBack: args['canGoBack'] as bool? ?? false,
          canGoForward: args['canGoForward'] as bool? ?? false,
          progress: (args['progress'] as num?)?.toDouble(),
        );
        break;
      case 'onAddressChange':
        navigation.value =
            navigation.value.copyWith(url: args['url'] as String? ?? '');
        break;
      case 'onTitleChange':
        final title = args['title'] as String? ?? '';
        navigation.value = navigation.value.copyWith(title: title);
        _titleCtrl.add(title);
        break;
      case 'onLoadError':
        _loadErrorCtrl.add(CefLoadError.fromMap(args));
        break;
      case 'onJsMessage':
        final handler = args['handler'] as String? ?? '';
        final data = args['data'];
        _jsMessageCtrl.add((handler: handler, data: data));
        _handlers[handler]?.call(handler, data);
        break;
      case 'onBeforePopup':
        // 新窗口请求：返回 true 表示已处理（阻止 CEF 默认弹窗）。
        _newWindowCtrl.add(args['targetUrl'] as String? ?? '');
        return true;
      case 'onImeCursorRect':
        onImeCursorRect?.call(
          (args['x'] as num?)?.toInt() ?? 0,
          (args['y'] as num?)?.toInt() ?? 0,
          (args['width'] as num?)?.toInt() ?? 0,
          (args['height'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'onCursorChange':
        cursor.value =
            cefCursorToFlutter((args['cursorType'] as num?)?.toInt() ?? 0);
        break;
    }
    return null;
  }
}
