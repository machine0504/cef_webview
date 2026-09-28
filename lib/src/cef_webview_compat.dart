/// 通用兼容垫片：把页面侧三种历史发消息写法统一映射到 CEF 的
/// `window.cefBridge.callHandler(name, payload)`，业务页面与 H5 / 模板无需改动。
///
/// 覆盖以下三种发送写法（按出现顺序）：
///   1. `window.flutter_inappwebview.callHandler(name, ...args)`
///      —— flutter_inappwebview 时代的写法（toolbox / 报告助手 / Quill / 公告等）。
///   2. `window.flutterBridge.sendMessage(type, data)`
///      —— OnlyOffice 文件预览模板 (`file_preview_template.dart`) 的写法。
///   3. `window.chrome.webview.postMessage({type, data})`
///      —— Windows 端 WebView2 原生 API 写法（部分模板兜底）。
///
/// 注入时机：页面 `onPageFinished` 后第一时间 `evaluateJavascript(kCefCompatShimJs)`。
/// 垫片自身幂等（`window.__cef_webview_compat__`），多次注入安全。
///
/// 上行 (JS→Dart) 走 `CefWebviewController.onJsMessage` / `addJavaScriptHandler`。
/// 下行 (Dart→JS) 仍用 `controller.evaluateJavascript('window.handleFlutterMessage(...)')` 等。
///
/// 内含 [kCefFileMimeFixJs]（不依赖 `cefBridge`，注入即生效）。
const String kCefCompatShimJs = kCefFileMimeFixJs +
    '''
(function(){
  if (window.__cef_webview_compat__) return;
  function run(){
    var b = window.cefBridge;
    if (!b || !b.callHandler) return false;
    window.__cef_webview_compat__ = 1;

    // 1) flutter_inappwebview.callHandler(name, ...args)
    window.flutter_inappwebview = window.flutter_inappwebview || {};
    if (!window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler = function(name){
        var a = Array.prototype.slice.call(arguments, 1);
        return b.callHandler(name, a.length <= 1 ? a[0] : a);
      };
    }

    // 2) flutterBridge.sendMessage(type, data)
    window.flutterBridge = window.flutterBridge || {};
    if (typeof window.flutterBridge.sendMessage !== 'function') {
      window.flutterBridge.sendMessage = function(type, data){
        try { return b.callHandler(type, data); } catch(e){ console.error(e); }
      };
    }

    // 3) chrome.webview.postMessage({type, data} | string)
    window.chrome = window.chrome || {};
    if (!window.chrome.webview || typeof window.chrome.webview.postMessage !== 'function') {
      window.chrome.webview = window.chrome.webview || {};
      window.chrome.webview.postMessage = function(msg){
        try {
          if (msg && typeof msg === 'object') {
            return b.callHandler(msg.type || 'postMessage', msg.data);
          }
          return b.callHandler('postMessage', msg);
        } catch(e){ console.error(e); }
      };
    }
    return true;
  }
  if (run()) return;
  // cefBridge 注入可能略晚于本脚本：轮询补装，最多 ~2.5s 后放弃。
  var n = 0;
  var timer = setInterval(function(){ if (run() || ++n > 50) clearInterval(timer); }, 50);
})();
''';

/// 按文件扩展名把 `File.type` 回正为标准 MIME。
///
/// 起因：装了 WPS Office 的机器（统信 UOS / 麒麟等国产桌面默认预装）会把 Office
/// 文档的系统 MIME 改写成私有类型——WPS 既装 `/usr/share/mime/packages/wps-office-*.xml`，
/// 又会在每次启动时重写 `~/.local/share/mime/packages/Override.xml`（该目录正是默认
/// 的 `XDG_DATA_HOME`，优先级最高），于是 `xdg-mime query filetype x.docx` 返回
/// `application/wps-office.docx`；也有被 zip magic 抢成 `application/zip` 的情形。
///
/// Chromium 由扩展名取 MIME 的顺序是「内置主表 → 系统库 → 内置次表」
/// （`net/base/mime_util.cc` 的 `GetMimeTypeFromExtensionHelper`），而 Office 各格式
/// 只登记在**次表**里（注释原文：types "we also want to allow the OS to override"），
/// 系统库因此能覆盖它们。结果 `<input type=file>` 交给页面的 `File.type` 是 WPS 私有
/// 类型，页面按标准 MIME 白名单校验就会判「文件类型不支持」。
///
/// 修法：在 `File.prototype` 上遮蔽一层 `type` getter（原 getter 在 `Blob.prototype`），
/// 命中扩展名表时返回标准值，否则原样透传。Windows 装 WPS 后注册表同样被改写，故不
/// 限平台生效；`Blob` 不受影响（`file.slice()` 的分片仍是空 type）。
///
/// 注意这只纠正 JS 侧可见的 `File.type`；上传请求真正的 Content-Type 由 C++ 层决定。
const String kCefFileMimeFixJs = '''
(function(){
  if (window.__cef_webview_mime_fix__) return;
  try {
    var d = Object.getOwnPropertyDescriptor(Blob.prototype, 'type');
    if (!d || typeof d.get !== 'function') return;
    var STD = {
      doc: 'application/msword',
      dot: 'application/msword',
      docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      xls: 'application/vnd.ms-excel',
      xlt: 'application/vnd.ms-excel',
      xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ppt: 'application/vnd.ms-powerpoint',
      pot: 'application/vnd.ms-powerpoint',
      pps: 'application/vnd.ms-powerpoint',
      pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      pdf: 'application/pdf',
      rtf: 'application/rtf',
      csv: 'text/csv',
      txt: 'text/plain',
      md: 'text/markdown',
      xml: 'text/xml',
      json: 'application/json',
      jpg: 'image/jpeg',
      jpeg: 'image/jpeg',
      png: 'image/png',
      gif: 'image/gif',
      bmp: 'image/bmp',
      webp: 'image/webp',
      tif: 'image/tiff',
      tiff: 'image/tiff',
      zip: 'application/zip'
    };
    Object.defineProperty(File.prototype, 'type', {
      configurable: true,
      enumerable: false,
      get: function(){
        var raw = d.get.call(this);
        var name = typeof this.name === 'string' ? this.name : '';
        var i = name.lastIndexOf('.');
        if (i < 0 || i === name.length - 1) return raw;
        return STD[name.slice(i + 1).toLowerCase()] || raw;
      }
    });
    window.__cef_webview_mime_fix__ = 1;
  } catch (e) {
    console.error('[cef_webview] File.type 归一化失败', e);
  }
})();
''';
