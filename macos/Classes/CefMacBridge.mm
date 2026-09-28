#import "CefMacBridge.h"
#import "CefMacTexture.h"

#include <map>
#include <string>
#include <vector>

#include <pwd.h>
#include <unistd.h>

#include "common/cef_browser_manager.h"
#include "common/cef_webview_app.h"
#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

// ===========================================================================
// C++ 纹理桥接 / 事件回传（macOS 实现）
// ===========================================================================
namespace {

class MacTextureBridge : public cef_webview::FlutterTextureBridge {
 public:
  MacTextureBridge(NSObject<FlutterTextureRegistry>* registry)
      : registry_(registry) {}

  int64_t CreateTexture(int /*w*/, int /*h*/) override {
    CefMacTexture* tex = [[CefMacTexture alloc] init];
    int64_t id = [registry_ registerTexture:tex];
    tex.textureId = id;
    textures_[id] = tex;
    return id;
  }
  void OnFrame(int64_t id, const void* buffer, int w, int h) override {
    auto it = textures_.find(id);
    if (it == textures_.end()) return;
    [it->second updateWithBuffer:buffer width:w height:h];
    [registry_ textureFrameAvailable:id];
  }
  // GPU 路径：shared_handle 即 CEF 交付的 IOSurfaceRef，直接包成 CVPixelBuffer 呈现。
  void OnAcceleratedFrame(
      int64_t id, const cef_webview::AcceleratedFrameInfo& info) override {
    auto it = textures_.find(id);
    if (it == textures_.end()) return;
    IOSurfaceRef surface = static_cast<IOSurfaceRef>(info.shared_handle);
    if (!surface) return;
    [it->second updateWithIOSurface:surface width:info.width height:info.height];
    [registry_ textureFrameAvailable:id];
  }
  void ResizeTexture(int64_t, int, int) override {}
  void DisposeTexture(int64_t id) override {
    auto it = textures_.find(id);
    if (it == textures_.end()) return;
    [registry_ unregisterTexture:id];
    textures_.erase(it);
  }

 private:
  NSObject<FlutterTextureRegistry>* registry_;
  std::map<int64_t, CefMacTexture*> textures_;
};

class MacEventSink : public cef_webview::CefEventSink {
 public:
  MacEventSink(FlutterMethodChannel* channel) : channel_(channel) {}
  void OnLoadingStateChange(int id, bool l, bool b, bool f, double p) override {
    [channel_ invokeMethod:@"onLoadingStateChange"
                 arguments:@{@"browserId" : @(id), @"isLoading" : @(l),
                             @"canGoBack" : @(b), @"canGoForward" : @(f),
                             @"progress" : @(p)}];
  }
  void OnAddressChange(int id, const std::string& url) override {
    [channel_ invokeMethod:@"onAddressChange"
                 arguments:@{@"browserId" : @(id),
                             @"url" : @(url.c_str())}];
  }
  void OnTitleChange(int id, const std::string& t) override {
    [channel_ invokeMethod:@"onTitleChange"
                 arguments:@{@"browserId" : @(id), @"title" : @(t.c_str())}];
  }
  void OnLoadError(int id, int c, const std::string& t,
                   const std::string& u) override {
    [channel_ invokeMethod:@"onLoadError"
                 arguments:@{@"browserId" : @(id), @"errorCode" : @(c),
                             @"errorText" : @(t.c_str()),
                             @"failedUrl" : @(u.c_str())}];
  }
  void OnJsMessage(int id, const std::string& h,
                   const std::string& d) override {
    [channel_ invokeMethod:@"onJsMessage"
                 arguments:@{@"browserId" : @(id), @"handler" : @(h.c_str()),
                             @"data" : @(d.c_str())}];
  }
  void OnBeforePopup(int id, const std::string& u) override {
    [channel_ invokeMethod:@"onBeforePopup"
                 arguments:@{@"browserId" : @(id),
                             @"targetUrl" : @(u.c_str())}];
  }
  void OnGlobalError(const std::string& m) override {
    [channel_ invokeMethod:@"onCefError" arguments:@{@"message" : @(m.c_str())}];
  }
  void OnCursorChange(int id, int cursor_type) override {
    [channel_ invokeMethod:@"onCursorChange"
                 arguments:@{@"browserId" : @(id),
                             @"cursorType" : @(cursor_type)}];
  }

 private:
  FlutterMethodChannel* channel_;
};

NSString* DictStr(NSDictionary* d, NSString* k) {
  id v = d[k];
  return [v isKindOfClass:[NSString class]] ? v : @"";
}
int DictInt(NSDictionary* d, NSString* k) {
  id v = d[k];
  return [v isKindOfClass:[NSNumber class]] ? [v intValue] : 0;
}
double DictDouble(NSDictionary* d, NSString* k) {
  id v = d[k];
  return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 0.0;
}
bool DictBool(NSDictionary* d, NSString* k, bool def = false) {
  id v = d[k];
  return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : def;
}
std::vector<std::string> DictStrList(NSDictionary* d, NSString* k) {
  std::vector<std::string> out;
  id v = d[k];
  if ([v isKindOfClass:[NSArray class]]) {
    for (id item in (NSArray*)v) {
      if ([item isKindOfClass:[NSString class]])
        out.push_back(((NSString*)item).UTF8String);
    }
  }
  return out;
}
// 从 CEF accept_filters 提取扩展名（不含点）。只取以 '.' 开头的项，
// 兼容组合形式 "Image|.png;.jpg"（按 '|'/';' 切分）；MIME("image/*") 跳过。
std::vector<std::string> ParseExts(const std::vector<std::string>& filters) {
  std::vector<std::string> out;
  for (const auto& f : filters) {
    std::string cur;
    auto flush = [&out, &cur]() {
      if (cur.size() >= 2 && cur[0] == '.') out.push_back(cur.substr(1));
      cur.clear();
    };
    for (char c : f) {
      if (c == '|' || c == ';')
        flush();
      else
        cur.push_back(c);
    }
    flush();
  }
  return out;
}

}  // namespace

// CEF framework 是否已加载（cef_load_library 进程内仅需成功一次）。
static bool g_cef_loaded = false;

// ===========================================================================
@implementation CefMacBridge {
  MacTextureBridge* _texBridge;
  MacEventSink* _sink;
  NSTimer* _pumpTimer;
  BOOL _initialized;
}

- (instancetype)initWithRegistry:(NSObject<FlutterTextureRegistry>*)registry
                         channel:(FlutterMethodChannel*)channel {
  if (self = [super init]) {
    _texBridge = new MacTextureBridge(registry);
    _sink = new MacEventSink(channel);
    _initialized = NO;
  }
  return self;
}

- (void)dealloc {
  [_pumpTimer invalidate];
  delete _texBridge;
  delete _sink;
}

- (BOOL)loadCefLibrary {
  // 运行期下载架构下，framework 路径在 initialize 时才确定（依赖 cefRoot），
  // 故真正加载延后到 ensureInitialized。此处保留接口兼容，返回 YES。
  return YES;
}

// 与 Dart cef_runtime_manager.dart 的 _baseDir 公式一致：
//   $HOME/Library/Application Support/cef_webview/cef/<safeVer>
// 仅当 .ready 与 framework 二进制都存在时返回该目录；否则 nil。
- (NSString*)realHomeDirectory {
  passwd* pw = getpwuid(getuid());
  if (pw && pw->pw_dir && pw->pw_dir[0]) {
    return [NSString stringWithUTF8String:pw->pw_dir];
  }
  return NSHomeDirectory();
}

- (NSString*)downloadedCefDir {
  NSString* dir = [[self realHomeDirectory] stringByAppendingPathComponent:
      @"Library/Application Support/cef_webview/cef/"
      @"144.0.29-g0b1a012-chromium-144.0.7559.256"];
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* ready = [dir stringByAppendingPathComponent:@".ready"];
  NSString* fwBin = [dir stringByAppendingPathComponent:
      @"Chromium Embedded Framework.framework/Chromium Embedded Framework"];
  if ([fm fileExistsAtPath:ready] && [fm fileExistsAtPath:fwBin]) return dir;
  return nil;
}

- (void)ensureInitialized:(NSDictionary*)args {
  if (_initialized) return;

  cef_webview::CefInitConfig config;
  config.locale = DictStr(args, @"locale").length ? DictStr(args, @"locale").UTF8String : "zh-CN";
  config.user_agent_suffix = DictStr(args, @"userAgentSuffix").UTF8String;
  config.log_severity = DictInt(args, @"logSeverity");
  config.remote_debugging_port = DictInt(args, @"remoteDebuggingPort");
  config.persist_session_cookies = DictBool(args, @"persistSessionCookies", true);
  // GPU 零拷贝：开启后 CEF 走 OnAcceleratedPaint，交付 IOSurface（见 MacTextureBridge）。
  config.gpu_shared_texture = DictBool(args, @"gpuSharedTexture", false);
  // 透传额外命令行开关（此前 macOS 漏传，一并补齐，与 Windows 对齐）。
  {
    id sw = args[@"extraCommandLineSwitches"];
    if ([sw isKindOfClass:[NSDictionary class]]) {
      for (id key in (NSDictionary*)sw) {
        if (![key isKindOfClass:[NSString class]]) continue;
        id val = ((NSDictionary*)sw)[key];
        std::string k = ((NSString*)key).UTF8String;
        std::string v = [val isKindOfClass:[NSString class]]
                            ? ((NSString*)val).UTF8String
                            : std::string();
        config.extra_switches.emplace_back(k, v);
      }
    }
  }

  NSString* cache = DictStr(args, @"cachePath");
  if (!cache.length) {
    NSString* support = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    cache = [support stringByAppendingPathComponent:@"cef_webview/cache"];
  }
  config.cache_path = cache.UTF8String;

  // 运行时 framework 目录（在线下载/本地缓存优先）：
  // 1) Dart 传入 cefRoot（manifest 下载落地目录）；
  // 2) 探测 Application Support；3) 回退 .app 内嵌（旧 dev 兼容）。
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* bundleParent = [[NSBundle mainBundle] privateFrameworksPath];
  NSString* bundleFwBin = [bundleParent stringByAppendingPathComponent:
      @"Chromium Embedded Framework.framework/Chromium Embedded Framework"];
  NSString* cefRoot = DictStr(args, @"cefRoot");
  if (!cefRoot.length) cefRoot = [self downloadedCefDir];
  NSString* fwParent = bundleParent;
  if (cefRoot.length) {
    fwParent = cefRoot;
  } else if ([fm fileExistsAtPath:bundleFwBin]) {
    fwParent = bundleParent;
  }
  NSString* fw = [fwParent stringByAppendingPathComponent:
                               @"Chromium Embedded Framework.framework"];

  // 子进程 Helper 继承此环境变量以定位 framework（沙箱下 $HOME 不可靠）。
  setenv("CEF_WEBVIEW_ROOT", fwParent.UTF8String, 1);

  // 运行期动态加载 framework（cef_load_library 进程内仅需成功一次）。
  // 未就绪（未下载）则安全降级：保持未初始化，App 正常运行，由 UI 引导下载。
  if (!g_cef_loaded) {
    NSString* fwBin =
        [fw stringByAppendingPathComponent:@"Chromium Embedded Framework"];
    if (cef_load_library(fwBin.UTF8String) != 1) {
      NSLog(@"[cef_webview] 加载 CEF framework 失败: %@（运行时未下载？）", fwBin);
      return;
    }
    g_cef_loaded = true;
  }

  config.framework_dir = fw.UTF8String;
  config.resources_dir =
      [fw stringByAppendingPathComponent:@"Resources"].UTF8String;
  config.locales_dir = config.resources_dir;
  // Helper 应用随 App 一起打包并签名（薄壳，不含 CEF；其 main 同样用 cef_load_library
  // 加载下载目录里的 framework）。见 docs/PACKAGING.md。
  NSString* helper = [[[NSBundle mainBundle] privateFrameworksPath]
      stringByAppendingPathComponent:
          @"cef_webview Helper.app/Contents/MacOS/cef_webview Helper"];
  config.subprocess_path = helper.UTF8String;

  // macOS 用外部消息泵（external_message_pump=true）：注册“立即泵”调度回调。CEF 从
  // 任意线程调用 OnScheduleMessagePumpWork；delay<=0 表示有待处理工作需尽快泵，切主线程
  // 立即泵一次以降低导航/输入延迟。delay>0（空闲唤醒）交由下方 60fps 心跳定时器兜底，
  // 不在此调度延迟 timer——避免“立即泵被随后的延迟调度取消”导致页面加载停滞（转圈）。
  // 必须在 CefInitialize（Initialize 内部）之前设置，因为初始化过程即可能回调它。
  cef_webview::CefWebviewApp::SetScheduleMessagePumpWorkCallback(
      [](int64_t delay_ms) {
        if (delay_ms > 0) return;  // 空闲唤醒由心跳定时器兜底
        dispatch_async(dispatch_get_main_queue(), ^{
          cef_webview::CefBrowserManager::Instance().DoMessageLoopWork();
        });
      });

  CefMainArgs main_args(0, nullptr);
  _initialized = cef_webview::CefBrowserManager::Instance().Initialize(
      main_args, config, _texBridge, _sink);

  if (_initialized) {
    // 心跳定时器（60fps）驱动 CefDoMessageLoopWork：保证浏览器网络/渲染/JS 定时器
    // 任务持续推进（否则页面一直转圈加载不出）。external_message_pump=true 下 CEF 不再
    // 安装自己的 CFRunLoop observer，故定时器泵不会触发 nesting_level_ CHECK 崩溃。
    // OnScheduleMessagePumpWork 的立即泵与本心跳互补：前者降延迟，后者保证进度。
    _pumpTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                 repeats:YES
                                                   block:^(NSTimer* t) {
      cef_webview::CefBrowserManager::Instance().DoMessageLoopWork();
    }];

    // <input type=file>：OSR + 空父窗口下 CEF 自带框在 macOS 弹不出来，改用系统
    // 原生 NSOpenPanel/NSSavePanel。beginWithCompletionHandler 为非阻塞异步，
    // 主线程 runloop（含上面的泵定时器）继续运行，不会造成整窗"无响应"。
    cef_webview::CefBrowserManager::Instance().SetFileDialogProvider(
        [](const cef_webview::FileDialogRequest& req,
           cef_webview::CefBrowserManager::FileDialogDoneCallback done) {
          const bool save = (req.mode == 3);
          const bool folder = (req.mode == 2);
          const bool multiple = req.multiple;
          NSString* title = req.title.empty() ? nil : @(req.title.c_str());
          NSString* defName =
              req.default_path.empty() ? nil : @(req.default_path.c_str());
          std::vector<std::string> exts = ParseExts(req.accept_filters);
          NSMutableArray<NSString*>* types = nil;
          if (!exts.empty()) {
            types = [NSMutableArray array];
            for (const auto& e : exts) [types addObject:@(e.c_str())];
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            if (save) {
              NSSavePanel* panel = [NSSavePanel savePanel];
              if (title) panel.title = title;
              if (defName) panel.nameFieldStringValue = defName.lastPathComponent;
              if (types) panel.allowedFileTypes = types;
              [panel beginWithCompletionHandler:^(NSModalResponse r) {
                std::vector<std::string> paths;
                if (r == NSModalResponseOK && panel.URL)
                  paths.push_back(panel.URL.path.UTF8String);
                done(paths);
              }];
            } else {
              NSOpenPanel* panel = [NSOpenPanel openPanel];
              panel.allowsMultipleSelection = multiple;
              panel.canChooseDirectories = folder;
              panel.canChooseFiles = !folder;
              if (title) panel.title = title;
              if (types && !folder) panel.allowedFileTypes = types;
              [panel beginWithCompletionHandler:^(NSModalResponse r) {
                std::vector<std::string> paths;
                if (r == NSModalResponseOK) {
                  for (NSURL* u in panel.URLs)
                    paths.push_back(u.path.UTF8String);
                }
                done(paths);
              }];
            }
          });
        });
  } else {
    NSLog(@"[cef_webview] CefInitialize 失败（framework=%@ helper=%@）", fw,
          helper);
  }
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSDictionary* a =
      [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
  NSString* method = call.method;
  auto& mgr = cef_webview::CefBrowserManager::Instance();

  if ([method isEqualToString:@"initialize"]) {
    [self ensureInitialized:a];
    if (_initialized)
      result(nil);
    else
      result([FlutterError errorWithCode:@"INIT_FAILED"
                                 message:@"CefInitialize 失败"
                                 details:nil]);
    return;
  }

  if ([method isEqualToString:@"createBrowser"]) {
    cef_webview::BrowserOptions opts;
    NSDictionary* s = [a[@"settings"] isKindOfClass:[NSDictionary class]]
                          ? a[@"settings"] : @{};
    opts.transparent = DictBool(s, @"transparent");
    opts.enable_javascript = DictBool(s, @"enableJavaScript", true);
    opts.background_color = (uint32_t)DictInt(s, @"backgroundColor");
    NSString* enc = DictStr(s, @"defaultEncoding");
    if (enc.length) opts.default_encoding = enc.UTF8String;
    opts.user_agent = DictStr(s, @"userAgent").UTF8String;
    opts.windowless_frame_rate = DictInt(s, @"windowlessFrameRate");

    cef_webview::CreateResult res = mgr.CreateBrowser(
        DictStr(a, @"url").UTF8String, DictInt(a, @"width"),
        DictInt(a, @"height"), (float)DictDouble(a, @"dpr"), opts);
    if (!res.ok) {
      result([FlutterError errorWithCode:@"CREATE_FAILED"
                                 message:@"CreateBrowserSync 返回空"
                                 details:nil]);
      return;
    }
    result(@{@"browserId" : @(res.browser_id),
             @"textureId" : @(res.texture_id)});
    return;
  }

  int bid = DictInt(a, @"browserId");
  if ([method isEqualToString:@"loadUrl"]) {
    mgr.LoadUrl(bid, DictStr(a, @"url").UTF8String);
  } else if ([method isEqualToString:@"reload"]) {
    mgr.Reload(bid);
  } else if ([method isEqualToString:@"stopLoad"]) {
    mgr.StopLoad(bid);
  } else if ([method isEqualToString:@"goBack"]) {
    mgr.GoBack(bid);
  } else if ([method isEqualToString:@"goForward"]) {
    mgr.GoForward(bid);
  } else if ([method isEqualToString:@"resize"]) {
    mgr.Resize(bid, DictInt(a, @"width"), DictInt(a, @"height"),
               (float)DictDouble(a, @"dpr"));
  } else if ([method isEqualToString:@"setVisible"]) {
    mgr.SetVisible(bid, DictBool(a, @"visible", true));
  } else if ([method isEqualToString:@"setFocus"]) {
    mgr.SetFocus(bid, DictBool(a, @"focused", true));
  } else if ([method isEqualToString:@"evaluateJavascript"]) {
    mgr.EvaluateJavascript(bid, DictStr(a, @"source").UTF8String);
  } else if ([method isEqualToString:@"mouseMove"]) {
    mgr.SendMouseMove(bid, DictDouble(a, @"x"), DictDouble(a, @"y"),
                      DictBool(a, @"leave"));
  } else if ([method isEqualToString:@"mouseButton"]) {
    mgr.SendMouseButton(bid, DictDouble(a, @"x"), DictDouble(a, @"y"),
                        DictInt(a, @"button"), DictBool(a, @"down"),
                        DictInt(a, @"clickCount"), DictInt(a, @"modifiers"));
  } else if ([method isEqualToString:@"mouseWheel"]) {
    mgr.SendMouseWheel(bid, DictDouble(a, @"x"), DictDouble(a, @"y"),
                       DictDouble(a, @"deltaX"), DictDouble(a, @"deltaY"));
  } else if ([method isEqualToString:@"dragTargetDragEnter"]) {
    mgr.DragTargetDragEnter(bid, DictDouble(a, @"x"), DictDouble(a, @"y"),
                            DictStrList(a, @"paths"), DictInt(a, @"modifiers"));
  } else if ([method isEqualToString:@"dragTargetDragOver"]) {
    mgr.DragTargetDragOver(bid, DictDouble(a, @"x"), DictDouble(a, @"y"),
                           DictInt(a, @"modifiers"));
  } else if ([method isEqualToString:@"dragTargetDragLeave"]) {
    mgr.DragTargetDragLeave(bid);
  } else if ([method isEqualToString:@"dragTargetDrop"]) {
    mgr.DragTargetDrop(bid, DictDouble(a, @"x"), DictDouble(a, @"y"),
                       DictInt(a, @"modifiers"));
  } else if ([method isEqualToString:@"key"]) {
    mgr.SendKey(bid, DictInt(a, @"type"), DictInt(a, @"windowsKeyCode"),
                DictInt(a, @"nativeKeyCode"), DictInt(a, @"modifiers"),
                DictInt(a, @"character"));
  } else if ([method isEqualToString:@"imeSetComposition"]) {
    mgr.ImeSetComposition(bid, DictStr(a, @"text").UTF8String,
                          DictInt(a, @"selectionStart"),
                          DictInt(a, @"selectionEnd"));
  } else if ([method isEqualToString:@"imeCommitText"]) {
    mgr.ImeCommitText(bid, DictStr(a, @"text").UTF8String);
  } else if ([method isEqualToString:@"imeFinishComposing"]) {
    mgr.ImeFinishComposing(bid, DictBool(a, @"keepSelection", true));
  } else if ([method isEqualToString:@"imeCancelComposition"]) {
    mgr.ImeCancelComposition(bid);
  } else if ([method isEqualToString:@"closeBrowser"]) {
    mgr.CloseBrowser(bid);
  } else if ([method isEqualToString:@"shutdown"]) {
    [_pumpTimer invalidate];
    _pumpTimer = nil;
    mgr.Shutdown();
    _initialized = NO;
  } else {
    result(FlutterMethodNotImplemented);
    return;
  }
  result(nil);
}

@end
