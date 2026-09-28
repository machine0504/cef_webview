#include "cef_webview_plugin.h"

#include <flutter/standard_method_codec.h>

#include <tmmintrin.h>  // SSSE3 _mm_shuffle_epi8

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <string>
#include <thread>

#include <shobjidl.h>  // IFileOpenDialog / IFileSaveDialog（系统原生文件框）

#include "common/cef_browser_manager.h"
#include "include/cef_app.h"

namespace cef_webview {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

// --------------------------------------------------------------------------
// EncodableValue 取值小工具
// --------------------------------------------------------------------------
namespace {

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0,
                              nullptr, nullptr);
  std::string s(n, 0);
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), s.data(), n,
                      nullptr, nullptr);
  return s;
}

std::string ExeDir() {
  wchar_t buf[MAX_PATH] = {0};
  GetModuleFileNameW(nullptr, buf, MAX_PATH);
  std::wstring p(buf);
  size_t pos = p.find_last_of(L"\\/");
  return WideToUtf8(pos == std::wstring::npos ? L"." : p.substr(0, pos));
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
  std::wstring w(n, 0);
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), w.data(), n);
  return w;
}

std::string LocalAppData() {
  wchar_t* p = nullptr;
  size_t len = 0;
  std::string out;
  if (_wdupenv_s(&p, &len, L"LOCALAPPDATA") == 0 && p) {
    out = WideToUtf8(p);
    free(p);
  }
  return out;
}

// CEF 运行时下载目录（与 Dart cef_runtime_manager.dart 的 _baseDir 公式一致）：
//   %LOCALAPPDATA%\cef_webview\cef\<safeVer>
// 仅当 .ready 与 libcef.dll 都存在时返回；否则空串（回退 exe 同目录，开发期随包）。
const char* kCefSafeVersion = "144.0.29-g0b1a012-chromium-144.0.7559.256";

std::string DownloadedCefDir() {
  std::string la = LocalAppData();
  if (la.empty()) return std::string();
  std::string dir = la + "\\cef_webview\\cef\\" + kCefSafeVersion;
  if (GetFileAttributesA((dir + "\\.ready").c_str()) == INVALID_FILE_ATTRIBUTES)
    return std::string();
  if (GetFileAttributesA((dir + "\\libcef.dll").c_str()) ==
      INVALID_FILE_ATTRIBUTES)
    return std::string();
  return dir;
}

const EncodableValue* Find(const EncodableMap& m, const char* key) {
  auto it = m.find(EncodableValue(std::string(key)));
  return it == m.end() ? nullptr : &it->second;
}
std::string GetString(const EncodableMap& m, const char* key) {
  const EncodableValue* v = Find(m, key);
  if (v) {
    if (auto p = std::get_if<std::string>(v)) return *p;
  }
  return {};
}
int64_t GetInt(const EncodableMap& m, const char* key) {
  const EncodableValue* v = Find(m, key);
  if (v) {
    if (auto p = std::get_if<int32_t>(v)) return *p;
    if (auto p = std::get_if<int64_t>(v)) return *p;
    if (auto p = std::get_if<double>(v)) return (int64_t)*p;
  }
  return 0;
}
double GetDouble(const EncodableMap& m, const char* key) {
  const EncodableValue* v = Find(m, key);
  if (v) {
    if (auto p = std::get_if<double>(v)) return *p;
    if (auto p = std::get_if<int32_t>(v)) return *p;
    if (auto p = std::get_if<int64_t>(v)) return (double)*p;
  }
  return 0.0;
}
bool GetBool(const EncodableMap& m, const char* key, bool def = false) {
  const EncodableValue* v = Find(m, key);
  if (v) {
    if (auto p = std::get_if<bool>(v)) return *p;
  }
  return def;
}
std::vector<std::string> GetStringList(const EncodableMap& m, const char* key) {
  std::vector<std::string> out;
  const EncodableValue* v = Find(m, key);
  if (v) {
    if (auto list = std::get_if<EncodableList>(v)) {
      for (const auto& item : *list) {
        if (auto s = std::get_if<std::string>(&item)) out.push_back(*s);
      }
    }
  }
  return out;
}
// CEF 消息泵驱动：用「独立线程定时 PostMessage 自定义消息」替代 WM_TIMER。
//
// WM_TIMER 是最低优先级、只在消息队列空闲时才投递的消息；在繁忙/复杂的宿主应用
// （大量插件 + SSE + 频繁 UI）里会被长时间饿死 → CEF 不被泵动 → 渲染子进程连接
// 超时 → FATAL 崩溃（示例项目空闲所以不触发）。自定义 PostMessage 消息会被平台
// 线程按序正常处理，不受「队列空闲才投递」限制，等价于 Linux 的可靠 g_timeout_add。
constexpr UINT WM_CEF_PUMP = WM_USER + 1;
std::atomic<bool> g_pumpPending{false};  // 是否已有一条待处理的泵消息（合并去重）
std::atomic<bool> g_pumpRunning{false};  // 泵线程运行标志
std::thread g_pumpThread;                // 定时投递泵消息的线程

LRESULT CALLBACK PumpWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_CEF_PUMP) {
    g_pumpPending.store(false, std::memory_order_release);
    CefBrowserManager::Instance().DoMessageLoopWork();
    return 0;
  }
  return DefWindowProc(hwnd, msg, wp, lp);
}

// 从 CEF accept_filters 提取扩展名（不含点）。只取以 '.' 开头的项，兼容组合形式
// "Image|.png;.jpg"（按 '|'/';' 切分）；MIME("image/*") 跳过。
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

// 在当前（独立）线程用系统原生文件框呈现选择；结果 UTF-8 写入 out（空=取消）。
// 必须在独立线程调用：其内部模态循环会阻塞本线程，放在平台线程会卡死 CEF 泵。
void ShowWin32FileDialog(HWND owner, const FileDialogRequest& req,
                         std::vector<std::string>* out) {
  const bool save = (req.mode == 3);
  const bool folder = (req.mode == 2);
  const bool multiple = req.multiple;

  HRESULT hr_init =
      CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  IFileDialog* dialog = nullptr;
  HRESULT hr =
      CoCreateInstance(save ? CLSID_FileSaveDialog : CLSID_FileOpenDialog,
                       nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (SUCCEEDED(hr) && dialog) {
    DWORD opts = 0;
    dialog->GetOptions(&opts);
    opts |= FOS_FORCEFILESYSTEM;
    if (folder) opts |= FOS_PICKFOLDERS;
    if (multiple && !save) opts |= FOS_ALLOWMULTISELECT;
    dialog->SetOptions(opts);

    if (!req.title.empty()) dialog->SetTitle(Utf8ToWide(req.title).c_str());

    // 过滤器（仅文件模式）：扩展名合并为「支持的文件」+「所有文件」。
    // pattern 须在 Show() 期间保持存活（COMDLG_FILTERSPEC 只存指针）。
    std::wstring pattern;
    if (!folder) {
      for (const auto& e : ParseExts(req.accept_filters)) {
        if (!pattern.empty()) pattern += L";";
        pattern += L"*.";
        pattern += Utf8ToWide(e);
      }
    }
    COMDLG_FILTERSPEC specs[2];
    if (!pattern.empty()) {
      specs[0] = {L"支持的文件", pattern.c_str()};
      specs[1] = {L"所有文件", L"*.*"};
      dialog->SetFileTypes(2, specs);
    }

    if (SUCCEEDED(dialog->Show(owner))) {
      auto append_item = [out](IShellItem* item) {
        PWSTR path = nullptr;
        if (item && SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) &&
            path) {
          out->push_back(WideToUtf8(path));
          CoTaskMemFree(path);
        }
      };
      IFileOpenDialog* open_dlg = nullptr;
      if (!save && SUCCEEDED(dialog->QueryInterface(IID_PPV_ARGS(&open_dlg))) &&
          open_dlg) {
        IShellItemArray* items = nullptr;
        if (SUCCEEDED(open_dlg->GetResults(&items)) && items) {
          DWORD count = 0;
          items->GetCount(&count);
          for (DWORD i = 0; i < count; ++i) {
            IShellItem* item = nullptr;
            if (SUCCEEDED(items->GetItemAt(i, &item)) && item) {
              append_item(item);
              item->Release();
            }
          }
          items->Release();
        }
        open_dlg->Release();
      } else {
        IShellItem* item = nullptr;
        if (SUCCEEDED(dialog->GetResult(&item)) && item) {
          append_item(item);
          item->Release();
        }
      }
    }
    dialog->Release();
  }
  if (SUCCEEDED(hr_init)) CoUninitialize();
}

}  // namespace

// --------------------------------------------------------------------------
// 注册
// --------------------------------------------------------------------------
void CefWebviewPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<CefWebviewPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

CefWebviewPlugin::CefWebviewPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      textures_(registrar->texture_registrar()) {
  channel_ = std::make_shared<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "cef_webview",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

CefWebviewPlugin::~CefWebviewPlugin() {
  g_pumpRunning.store(false);
  if (g_pumpThread.joinable()) g_pumpThread.join();
  if (pump_hwnd_) {
    DestroyWindow(pump_hwnd_);
    pump_hwnd_ = nullptr;
  }
  // 清除屏幕原点提供者（其捕获了 registrar_，避免插件销毁后悬挂调用）。
  CefBrowserManager::Instance().SetScreenOriginProvider(nullptr);
  if (initialized_) CefBrowserManager::Instance().Shutdown();
}

// --------------------------------------------------------------------------
// 消息泵：HWND_MESSAGE 隐藏窗口 + 独立线程定时 PostMessage（可靠驱动，不被饿死）
// --------------------------------------------------------------------------
void CefWebviewPlugin::StartPump() {
  if (g_pumpRunning.load()) return;  // 已在运行
  static const wchar_t* kClass = L"CefWebviewPumpWindow";
  WNDCLASSW wc = {};
  wc.lpfnWndProc = PumpWndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kClass;
  RegisterClassW(&wc);
  pump_hwnd_ = CreateWindowExW(0, kClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                               nullptr, GetModuleHandle(nullptr), nullptr);

  // 独立线程每 ~16ms 向泵窗口 PostMessage 一条 WM_CEF_PUMP（已挂起则跳过，合并去重），
  // 平台线程在自己的消息循环里处理它并调用 CefDoMessageLoopWork——不受 WM_TIMER
  // 「队列空闲才投递」的限制，宿主繁忙时也能稳定驱动 CEF（修复渲染子进程连接超时崩溃）。
  g_pumpRunning.store(true);
  const HWND hwnd = pump_hwnd_;
  g_pumpThread = std::thread([hwnd]() {
    while (g_pumpRunning.load(std::memory_order_acquire)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(16));
      if (!g_pumpPending.exchange(true, std::memory_order_acq_rel)) {
        PostMessageW(hwnd, WM_CEF_PUMP, 0, 0);
      }
    }
  });
}

void CefWebviewPlugin::EnsureInitialized(const EncodableMap& args) {
  if (initialized_) return;

  CefInitConfig config;
  config.locale = GetString(args, "locale");
  if (config.locale.empty()) config.locale = "zh-CN";
  config.user_agent_suffix = GetString(args, "userAgentSuffix");
  config.log_severity = (int)GetInt(args, "logSeverity");
  config.remote_debugging_port = (int)GetInt(args, "remoteDebuggingPort");
  config.persist_session_cookies = GetBool(args, "persistSessionCookies", true);
  // GPU 零拷贝：开启后 CEF 走 OnAcceleratedPaint 交付 D3D11 共享句柄（见
  // OnAcceleratedFrame + GpuSurfaceTexture）。config 会驱动 SetGpuEnabled(不注入
  // disable-gpu) 与 window_info.shared_texture_enabled（见 CefBrowserManager）。
  config.gpu_shared_texture = GetBool(args, "gpuSharedTexture", false);
  gpu_ = config.gpu_shared_texture;

  // 运行时目录：优先 Dart 传入的 cefRoot；否则按 Windows 公式探测下载目录；
  // 否则回退 exe 同目录（开发期随包）。
  std::string cefRoot = GetString(args, "cefRoot");
  if (cefRoot.empty()) cefRoot = DownloadedCefDir();
  if (cefRoot.empty()) cefRoot = ExeDir();

  // libcef.dll 采用 delay-load（见 CMakeLists 的 /DELAYLOAD:libcef.dll）：在首次调用
  // CEF 导出符号前，把运行时目录加入 DLL 搜索路径，使非 exe 同目录的 libcef.dll 可加载。
  SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  AddDllDirectory(Utf8ToWide(cefRoot).c_str());

  // 缓存/Cookie 必须写到用户可写目录（exe 同目录在 Program Files 下只读）。
  std::string cache = GetString(args, "cachePath");
  if (cache.empty()) {
    std::string la = LocalAppData();
    cache = (la.empty() ? ExeDir() : la) + "\\cef_webview\\cache";
  }
  config.cache_path = cache;

  // 子进程随「下载包」分发，与 libcef.dll 同在 cefRoot（exe 同目录是其默认 DLL 搜索路径）。
  config.subprocess_path = cefRoot + "\\cef_webview_subprocess.exe";
  config.resources_dir = cefRoot;
  // 语言包在 cefRoot\locales\ 子目录（与 Linux 端一致）。CEF 144 的运行时包把
  // *.pak 语言文件放进 locales\；若指向 cefRoot 根，CefInitialize 期间加载不到
  // locale pak 会直接 FATAL(int3/0x80000003)——表现为「启动即闪退」。
  config.locales_dir = cefRoot + "\\locales";

  if (const EncodableValue* sw = Find(args, "extraCommandLineSwitches")) {
    if (auto m = std::get_if<EncodableMap>(sw)) {
      for (auto& kv : *m) {
        if (auto k = std::get_if<std::string>(&kv.first)) {
          std::string val;
          if (auto vv = std::get_if<std::string>(&kv.second)) val = *vv;
          config.extra_switches.emplace_back(*k, val);
        }
      }
    }
  }

  CefMainArgs main_args(GetModuleHandle(nullptr));
  initialized_ = CefBrowserManager::Instance().Initialize(
      main_args, config, this, this);
  if (initialized_) {
    StartPump();
    // 提供窗口客户区屏幕原点，供 OSR 把视图坐标换算到屏幕坐标
    // （GetScreenPoint，用于原生弹层 / 输入法窗口定位）。
    flutter::PluginRegistrarWindows* reg = registrar_;
    CefBrowserManager::Instance().SetScreenOriginProvider(
        [reg](int* x, int* y) -> bool {
          if (!reg || !reg->GetView()) return false;
          HWND hwnd = reg->GetView()->GetNativeWindow();
          if (!hwnd) return false;
          HWND root = GetAncestor(hwnd, GA_ROOT);
          if (!root) root = hwnd;
          POINT p = {0, 0};
          if (!ClientToScreen(root, &p)) return false;
          *x = p.x;
          *y = p.y;
          return true;
        });

    // <input type=file>：OSR + 空父窗口下 CEF 自带框不可靠，改用系统原生
    // IFileOpenDialog/IFileSaveDialog。在独立线程弹框（其模态循环会阻塞该线程），
    // 平台消息泵线程不受影响；结果经 done 回传（handler 内会切回 CEF UI 线程）。
    CefBrowserManager::Instance().SetFileDialogProvider(
        [reg](const FileDialogRequest& req,
              CefBrowserManager::FileDialogDoneCallback done) {
          HWND owner = nullptr;
          if (reg && reg->GetView()) {
            HWND h = reg->GetView()->GetNativeWindow();
            if (h) {
              HWND root = GetAncestor(h, GA_ROOT);
              owner = root ? root : h;
            }
          }
          FileDialogRequest r = req;
          std::thread([owner, r, done]() {
            std::vector<std::string> paths;
            ShowWin32FileDialog(owner, r, &paths);
            done(paths);
          }).detach();
        });
  }
}

// --------------------------------------------------------------------------
// 方法分发
// --------------------------------------------------------------------------
void CefWebviewPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  EncodableMap empty;
  const EncodableMap& a = args ? *args : empty;
  const std::string& method = call.method_name();
  auto& mgr = CefBrowserManager::Instance();

  if (method == "initialize") {
    EnsureInitialized(a);
    if (initialized_)
      result->Success();
    else
      result->Error("INIT_FAILED", "CefInitialize 失败");
    return;
  }

  if (method == "createBrowser") {
    BrowserOptions opts;
    if (const EncodableValue* s = Find(a, "settings")) {
      if (auto sm = std::get_if<EncodableMap>(s)) {
        opts.transparent = GetBool(*sm, "transparent");
        opts.enable_javascript = GetBool(*sm, "enableJavaScript", true);
        opts.background_color = (uint32_t)GetInt(*sm, "backgroundColor");
        std::string enc = GetString(*sm, "defaultEncoding");
        if (!enc.empty()) opts.default_encoding = enc;
        opts.user_agent = GetString(*sm, "userAgent");
        opts.windowless_frame_rate = (int)GetInt(*sm, "windowlessFrameRate");
      }
    }
    CreateResult res = mgr.CreateBrowser(
        GetString(a, "url"), (int)GetInt(a, "width"), (int)GetInt(a, "height"),
        (float)GetDouble(a, "dpr"), opts);
    if (!res.ok) {
      result->Error("CREATE_FAILED", "CreateBrowserSync 返回空");
      return;
    }
    EncodableMap r;
    r[EncodableValue("browserId")] = EncodableValue(res.browser_id);
    r[EncodableValue("textureId")] = EncodableValue(res.texture_id);
    result->Success(EncodableValue(r));
    return;
  }

  const int id = (int)GetInt(a, "browserId");
  if (method == "loadUrl") {
    mgr.LoadUrl(id, GetString(a, "url"));
  } else if (method == "reload") {
    mgr.Reload(id);
  } else if (method == "stopLoad") {
    mgr.StopLoad(id);
  } else if (method == "goBack") {
    mgr.GoBack(id);
  } else if (method == "goForward") {
    mgr.GoForward(id);
  } else if (method == "resize") {
    mgr.Resize(id, (int)GetInt(a, "width"), (int)GetInt(a, "height"),
               (float)GetDouble(a, "dpr"));
  } else if (method == "setVisible") {
    mgr.SetVisible(id, GetBool(a, "visible", true));
  } else if (method == "setFocus") {
    mgr.SetFocus(id, GetBool(a, "focused", true));
  } else if (method == "evaluateJavascript") {
    mgr.EvaluateJavascript(id, GetString(a, "source"));
  } else if (method == "mouseMove") {
    mgr.SendMouseMove(id, GetDouble(a, "x"), GetDouble(a, "y"),
                      GetBool(a, "leave"), (int)GetInt(a, "modifiers"));
  } else if (method == "mouseButton") {
    mgr.SendMouseButton(id, GetDouble(a, "x"), GetDouble(a, "y"),
                        (int)GetInt(a, "button"), GetBool(a, "down"),
                        (int)GetInt(a, "clickCount"),
                        (int)GetInt(a, "modifiers"));
  } else if (method == "mouseWheel") {
    mgr.SendMouseWheel(id, GetDouble(a, "x"), GetDouble(a, "y"),
                       GetDouble(a, "deltaX"), GetDouble(a, "deltaY"),
                       (int)GetInt(a, "modifiers"));
  } else if (method == "dragTargetDragEnter") {
    mgr.DragTargetDragEnter(id, GetDouble(a, "x"), GetDouble(a, "y"),
                            GetStringList(a, "paths"),
                            (int)GetInt(a, "modifiers"));
  } else if (method == "dragTargetDragOver") {
    mgr.DragTargetDragOver(id, GetDouble(a, "x"), GetDouble(a, "y"),
                           (int)GetInt(a, "modifiers"));
  } else if (method == "dragTargetDragLeave") {
    mgr.DragTargetDragLeave(id);
  } else if (method == "dragTargetDrop") {
    mgr.DragTargetDrop(id, GetDouble(a, "x"), GetDouble(a, "y"),
                       (int)GetInt(a, "modifiers"));
  } else if (method == "key") {
    mgr.SendKey(id, (int)GetInt(a, "type"), (int)GetInt(a, "windowsKeyCode"),
                (int)GetInt(a, "nativeKeyCode"), (int)GetInt(a, "modifiers"),
                (int)GetInt(a, "character"));
  } else if (method == "imeSetComposition") {
    mgr.ImeSetComposition(id, GetString(a, "text"),
                          (int)GetInt(a, "selectionStart"),
                          (int)GetInt(a, "selectionEnd"));
  } else if (method == "imeCommitText") {
    mgr.ImeCommitText(id, GetString(a, "text"));
  } else if (method == "imeFinishComposing") {
    mgr.ImeFinishComposing(id, GetBool(a, "keepSelection", true));
  } else if (method == "imeCancelComposition") {
    mgr.ImeCancelComposition(id);
  } else if (method == "closeBrowser") {
    mgr.CloseBrowser(id);
  } else if (method == "shutdown") {
    g_pumpRunning.store(false);
    if (g_pumpThread.joinable()) g_pumpThread.join();
    if (pump_hwnd_) {
      DestroyWindow(pump_hwnd_);
      pump_hwnd_ = nullptr;
    }
    mgr.Shutdown();
    initialized_ = false;
  } else {
    result->NotImplemented();
    return;
  }
  result->Success();
}

// --------------------------------------------------------------------------
// FlutterTextureBridge（PixelBufferTexture）
// --------------------------------------------------------------------------
int64_t CefWebviewPlugin::CreateTexture(int width, int height) {
  auto entry = std::make_unique<TextureEntry>();
  TextureEntry* e = entry.get();
  e->width = width;
  e->height = height;

  // GPU 模式：GpuSurfaceTexture(DxgiSharedHandle)。Flutter raster 线程回调取当前
  // CEF 共享句柄，ANGLE 打开该共享资源直接采样——零 CPU 拷贝上屏。帧到达前返回
  // nullptr（Flutter 允许，不显示直到首帧）。
  if (gpu_) {
    e->variant = std::make_unique<flutter::TextureVariant>(
        flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
            [e](size_t /*w*/, size_t /*h*/)
                -> const FlutterDesktopGpuSurfaceDescriptor* {
              std::lock_guard<std::mutex> lock(e->mutex);
              if (!e->shared_handle) return nullptr;
              e->gpu_desc.struct_size =
                  sizeof(FlutterDesktopGpuSurfaceDescriptor);
              e->gpu_desc.handle = e->shared_handle;
              e->gpu_desc.width = e->gpu_desc.visible_width = e->gpu_w;
              e->gpu_desc.height = e->gpu_desc.visible_height = e->gpu_h;
              e->gpu_desc.format = kFlutterDesktopPixelFormatBGRA8888;
              e->gpu_desc.release_callback = nullptr;
              e->gpu_desc.release_context = nullptr;
              return &e->gpu_desc;
            }));
    int64_t id = textures_->RegisterTexture(e->variant.get());
    e->id = id;
    entries_[id] = std::move(entry);
    return id;
  }

  e->variant = std::make_unique<flutter::TextureVariant>(
      flutter::PixelBufferTexture(
          [e](size_t /*w*/, size_t /*h*/) -> const FlutterDesktopPixelBuffer* {
            std::lock_guard<std::mutex> lock(e->mutex);
            if (e->dirty) {
              std::swap(e->pending, e->present);
              e->width = e->pending_w;
              e->height = e->pending_h;
              e->dirty = false;
            }
            if (e->present.empty()) return nullptr;
            e->fb.buffer = e->present.data();
            e->fb.width = e->width;
            e->fb.height = e->height;
            e->fb.release_callback = nullptr;
            e->fb.release_context = nullptr;
            return &e->fb;
          }));

  int64_t id = textures_->RegisterTexture(e->variant.get());
  e->id = id;
  entries_[id] = std::move(entry);
  return id;
}

void CefWebviewPlugin::OnFrame(int64_t texture_id, const void* buffer,
                               int width, int height) {
  auto it = entries_.find(texture_id);
  if (it == entries_.end()) return;
  TextureEntry* e = it->second.get();
  const uint8_t* src = static_cast<const uint8_t*>(buffer);
  const size_t n = (size_t)width * height;
  {
    std::lock_guard<std::mutex> lock(e->mutex);
    const size_t bytes = n * 4;
    e->pending.resize(bytes);
    uint8_t* dst = e->pending.data();
    // BGRA -> RGBA：用 SSSE3 一次处理 4 个像素（16 字节），仅交换 B/R 通道。
    // 标量逐字节循环在大窗口 + Debug 下单帧可达 ~100ms，会把平台线程占满导致
    // 持续重绘页面"未响应"；shuffle 版本约快一个数量级。
    const __m128i shuffle =
        _mm_setr_epi8(2, 1, 0, 3, 6, 5, 4, 7, 10, 9, 8, 11, 14, 13, 12, 15);
    size_t i = 0;
    for (; i + 16 <= bytes; i += 16) {
      __m128i v = _mm_loadu_si128(reinterpret_cast<const __m128i*>(src + i));
      v = _mm_shuffle_epi8(v, shuffle);
      _mm_storeu_si128(reinterpret_cast<__m128i*>(dst + i), v);
    }
    for (; i + 4 <= bytes; i += 4) {  // 尾部不足 16 字节
      dst[i + 0] = src[i + 2];
      dst[i + 1] = src[i + 1];
      dst[i + 2] = src[i + 0];
      dst[i + 3] = src[i + 3];
    }
    e->pending_w = width;
    e->pending_h = height;
    e->dirty = true;
  }
  textures_->MarkTextureFrameAvailable(texture_id);
}

void CefWebviewPlugin::OnAcceleratedFrame(int64_t texture_id,
                                          const AcceleratedFrameInfo& info) {
  auto it = entries_.find(texture_id);
  if (it == entries_.end()) return;
  TextureEntry* e = it->second.get();
  {
    std::lock_guard<std::mutex> lock(e->mutex);
    e->shared_handle = info.shared_handle;  // D3D11 共享 HANDLE（Windows）
    e->gpu_w = static_cast<size_t>(info.width);
    e->gpu_h = static_cast<size_t>(info.height);
  }
  textures_->MarkTextureFrameAvailable(texture_id);
}

void CefWebviewPlugin::ResizeTexture(int64_t, int, int) {}

void CefWebviewPlugin::DisposeTexture(int64_t texture_id) {
  auto it = entries_.find(texture_id);
  if (it == entries_.end()) return;
  textures_->UnregisterTexture(texture_id);
  entries_.erase(it);
}

// --------------------------------------------------------------------------
// CefEventSink（C++ → Dart，运行在平台线程，可直接 InvokeMethod）
// --------------------------------------------------------------------------
void CefWebviewPlugin::InvokeEvent(const std::string& method,
                                   EncodableMap args) {
  channel_->InvokeMethod(method,
                         std::make_unique<EncodableValue>(std::move(args)));
}

void CefWebviewPlugin::OnLoadingStateChange(int id, bool loading, bool back,
                                            bool fwd, double progress) {
  InvokeEvent("onLoadingStateChange",
              {{EncodableValue("browserId"), EncodableValue(id)},
               {EncodableValue("isLoading"), EncodableValue(loading)},
               {EncodableValue("canGoBack"), EncodableValue(back)},
               {EncodableValue("canGoForward"), EncodableValue(fwd)},
               {EncodableValue("progress"), EncodableValue(progress)}});
}
void CefWebviewPlugin::OnAddressChange(int id, const std::string& url) {
  InvokeEvent("onAddressChange",
              {{EncodableValue("browserId"), EncodableValue(id)},
               {EncodableValue("url"), EncodableValue(url)}});
}
void CefWebviewPlugin::OnTitleChange(int id, const std::string& title) {
  InvokeEvent("onTitleChange",
              {{EncodableValue("browserId"), EncodableValue(id)},
               {EncodableValue("title"), EncodableValue(title)}});
}
void CefWebviewPlugin::OnLoadError(int id, int code, const std::string& text,
                                   const std::string& url) {
  InvokeEvent("onLoadError",
              {{EncodableValue("browserId"), EncodableValue(id)},
               {EncodableValue("errorCode"), EncodableValue(code)},
               {EncodableValue("errorText"), EncodableValue(text)},
               {EncodableValue("failedUrl"), EncodableValue(url)}});
}
void CefWebviewPlugin::OnJsMessage(int id, const std::string& handler,
                                   const std::string& data_json) {
  InvokeEvent("onJsMessage",
              {{EncodableValue("browserId"), EncodableValue(id)},
               {EncodableValue("handler"), EncodableValue(handler)},
               {EncodableValue("data"), EncodableValue(data_json)}});
}
void CefWebviewPlugin::OnBeforePopup(int id, const std::string& target_url) {
  InvokeEvent("onBeforePopup",
              {{EncodableValue("browserId"), EncodableValue(id)},
               {EncodableValue("targetUrl"), EncodableValue(target_url)}});
}
void CefWebviewPlugin::OnGlobalError(const std::string& message) {
  InvokeEvent("onCefError",
              {{EncodableValue("message"), EncodableValue(message)}});
}
void CefWebviewPlugin::OnImeCursorRect(int id, int x, int y, int width,
                                       int height) {
  InvokeEvent("onImeCursorRect",
              {{EncodableValue("browserId"), EncodableValue(id)},
               {EncodableValue("x"), EncodableValue(x)},
               {EncodableValue("y"), EncodableValue(y)},
               {EncodableValue("width"), EncodableValue(width)},
               {EncodableValue("height"), EncodableValue(height)}});
}
void CefWebviewPlugin::OnCursorChange(int id, int cursor_type) {
  InvokeEvent("onCursorChange",
              {{EncodableValue("browserId"), EncodableValue(id)},
               {EncodableValue("cursorType"), EncodableValue(cursor_type)}});
}

}  // namespace cef_webview
