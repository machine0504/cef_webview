#include "cef_browser_manager.h"

#include <atomic>

#include "include/cef_browser.h"
#include "include/cef_command_line.h"
#include "include/cef_drag_data.h"
#include "include/wrapper/cef_helpers.h"
#include "cef_webview_app.h"

namespace cef_webview {

namespace {
// 当前是否正处于 CEF 消息循环工作中（含 CreateBrowserSync 的嵌套循环）。
// 外部消息泵据此防重入：CefDoMessageLoopWork 不可重入调用，否则会卡死。
std::atomic<bool> g_message_loop_busy{false};

cef_log_severity_t MapLogSeverity(int v) {
  switch (v) {
    case 0: return LOGSEVERITY_VERBOSE;
    case 1: return LOGSEVERITY_INFO;
    case 2: return LOGSEVERITY_WARNING;
    case 3: return LOGSEVERITY_ERROR;
    default: return LOGSEVERITY_DISABLE;
  }
}

// Dart 侧 type：0=rawKeyDown 1=keyUp 2=char → CEF cef_key_event_type_t
cef_key_event_type_t MapKeyType(int t) {
  switch (t) {
    case 0: return KEYEVENT_RAWKEYDOWN;
    case 1: return KEYEVENT_KEYUP;
    case 2: return KEYEVENT_CHAR;
    default: return KEYEVENT_RAWKEYDOWN;
  }
}

cef_mouse_button_type_t MapButton(int b) {
  switch (b) {
    case 1: return MBT_MIDDLE;
    case 2: return MBT_RIGHT;
    default: return MBT_LEFT;
  }
}

#if defined(__APPLE__)
// macOS OSR 合成按键：编辑/导航键（退格/删除/方向/Home/End/翻页）在没有真实
// NSEvent 的情况下，Chromium 需要 macOS 原生虚拟键码 + 对应的 NSEvent 功能键
// 字符才会生成编辑命令（DeleteBackward / MoveLeft…）。Dart 侧统一传 Windows VK，
// 这里把它换算成 (macOS 虚拟键码, NSEvent 功能键字符)。未命中返回 false（普通字符
// 键走文本输入通道，不经此路径）。参考 cefclient browser_window_osr_mac 的 keyCode
// 与 characters 取值（如退格 keyCode=51、character=0x7F）。
bool MapMacEditingKey(int vk, int* mac_code, int* mac_char) {
  switch (vk) {
    case 0x08: *mac_code = 51;  *mac_char = 0x7F;   return true;  // Backspace
    case 0x2E: *mac_code = 117; *mac_char = 0xF728; return true;  // Delete(前向)
    case 0x25: *mac_code = 123; *mac_char = 0xF702; return true;  // Left
    case 0x27: *mac_code = 124; *mac_char = 0xF703; return true;  // Right
    case 0x26: *mac_code = 126; *mac_char = 0xF700; return true;  // Up
    case 0x28: *mac_code = 125; *mac_char = 0xF701; return true;  // Down
    case 0x24: *mac_code = 115; *mac_char = 0xF729; return true;  // Home
    case 0x23: *mac_code = 119; *mac_char = 0xF72B; return true;  // End
    case 0x21: *mac_code = 116; *mac_char = 0xF72C; return true;  // PageUp
    case 0x22: *mac_code = 121; *mac_char = 0xF72D; return true;  // PageDown
    default: return false;
  }
}
#endif
}  // namespace

CefBrowserManager& CefBrowserManager::Instance() {
  static CefBrowserManager instance;
  return instance;
}

int CefBrowserManager::ExecuteSubProcess(const CefMainArgs& main_args) {
  CefRefPtr<CefWebviewApp> app(new CefWebviewApp());
  return CefExecuteProcess(main_args, app.get(), nullptr);
}

void CefBrowserManager::SetBridges(FlutterTextureBridge* texture_bridge,
                                   CefEventSink* sink) {
  if (texture_bridge) texture_bridge_ = texture_bridge;
  if (sink) sink_ = sink;
}

bool CefBrowserManager::Initialize(const CefMainArgs& main_args,
                                   const CefInitConfig& config,
                                   FlutterTextureBridge* texture_bridge,
                                   CefEventSink* sink) {
  SetBridges(texture_bridge, sink);
  return InitializeCef(main_args, config);
}

bool CefBrowserManager::InitializeCef(const CefMainArgs& main_args,
                                      const CefInitConfig& config) {
  if (initialized_) return true;

  gpu_shared_texture_ = config.gpu_shared_texture;

  CefSettings settings;
  settings.no_sandbox = true;  // 简化分发；启用沙箱见 docs/LINUX_TROUBLESHOOTING.md
  settings.windowless_rendering_enabled = true;
  multi_threaded_ = false;
  settings.multi_threaded_message_loop = false;
#if defined(__APPLE__)
  // macOS：必须启用外部消息泵。否则 CEF 会安装自己的 MessagePumpCFRunLoop
  // EnterExitObserver，而宿主(Flutter) 的 NSApplication runloop 驱动该 observer
  // 时 CEF 的 nesting_level_ CHECK 会失败（message_pump_mac.mm: Check failed:
  // nesting_level_ != 0），导致启动即 EXC_BREAKPOINT 闪退。启用后由 CEF 通过
  // OnScheduleMessagePumpWork 回调请求主线程 DoMessageLoopWork（见 CefMacBridge）。
  settings.external_message_pump = true;
#else
  // Windows/Linux：由平台自有定时器(WM_TIMER / g_timeout_add)驱动 DoMessageLoopWork。
  settings.external_message_pump = false;
#endif
  settings.log_severity = MapLogSeverity(config.log_severity);
  settings.remote_debugging_port = config.remote_debugging_port;
  settings.persist_session_cookies = config.persist_session_cookies;

  if (!config.cache_path.empty())
    CefString(&settings.cache_path).FromString(config.cache_path);
  if (!config.locale.empty())
    CefString(&settings.locale).FromString(config.locale);
  if (!config.subprocess_path.empty())
    CefString(&settings.browser_subprocess_path)
        .FromString(config.subprocess_path);
  if (!config.framework_dir.empty())
    CefString(&settings.framework_dir_path).FromString(config.framework_dir);
  if (!config.resources_dir.empty())
    CefString(&settings.resources_dir_path).FromString(config.resources_dir);
  if (!config.locales_dir.empty())
    CefString(&settings.locales_dir_path).FromString(config.locales_dir);
  if (!config.user_agent_suffix.empty())
    CefString(&settings.user_agent_product)
        .FromString(config.user_agent_suffix);

#if defined(__linux__)
  // Linux：在 DEEPBIND 隔离加载的引擎库中实例化含多重继承的 CefApp 会在
  // CefInitialize 阶段触发异常崩溃；该平台改由 cef_engine_api.cc 走 argv 注入
  // 命令行开关，并不会走到这里（其有独立的 CefInitialize）。
  (void)config;
  initialized_ = CefInitialize(main_args, settings, nullptr, nullptr);
#else
  // Windows/macOS（直接链接 CEF，无 DEEPBIND 隔离）：浏览器进程必须使用
  // CefWebviewApp，否则其 OnBeforeCommandLineProcessing 不会被调用，
  // OSR 软件渲染/逐帧调度开关（disable-gpu / disable-gpu-compositing /
  // in-process-gpu / enable-begin-frame-scheduling）全部丢失 —— 表现为页面
  // 画了一点点后停止刷新、整窗"无响应"。Dart 侧 extraCommandLineSwitches
  // 也经此透传。
  CefWebviewApp::SetExtraSwitches(config.extra_switches);
  CefWebviewApp::SetGpuEnabled(config.gpu_shared_texture);
  CefRefPtr<CefWebviewApp> app(new CefWebviewApp());
  initialized_ = CefInitialize(main_args, settings, app, nullptr);
#endif
  return initialized_;
}

CreateResult CefBrowserManager::CreateBrowser(const std::string& url,
                                              int width,
                                              int height,
                                              float dpr,
                                              const BrowserOptions& options) {
  CreateResult result;
  if (!initialized_ || !texture_bridge_) return result;

  const int dev_w = static_cast<int>(width * dpr);
  const int dev_h = static_cast<int>(height * dpr);
  const int64_t texture_id = texture_bridge_->CreateTexture(dev_w, dev_h);
  if (texture_id < 0) return result;

  CefRefPtr<CefWebviewHandler> handler(
      new CefWebviewHandler(texture_bridge_, sink_, this, texture_id));
  handler->SetViewSize(width, height, dpr);

  CefWindowInfo window_info;
  window_info.SetAsWindowless(kNullWindowHandle);
  // GPU 加速模式：启用共享纹理，CEF 改走 OnAcceleratedPaint 输出 GPU 纹理句柄
  // （而非 OnPaint 的 CPU BGRA 帧）。软件模式保持 false。
  window_info.shared_texture_enabled = gpu_shared_texture_;

  CefBrowserSettings browser_settings;
  // OSR 帧率：由 Dart 侧 CefBrowserSettings.windowlessFrameRate 下发——显式配置或
  // 「跟随显示器刷新率」（见 CefWebviewController._resolveWindowlessFrameRate）。这里
  // 兜底并裁剪到 CEF OSR 支持的 1~60：60fps 更跟手但平台线程负载更高，低配机可在
  // Dart 侧调低。每帧 OnPaint 都要在平台线程做 BGRA→RGBA 转换并触发一次 Flutter 帧调度。
  int frame_rate = options.windowless_frame_rate;
  if (frame_rate <= 0) frame_rate = 60;
  if (frame_rate > 60) frame_rate = 60;
  browser_settings.windowless_frame_rate = frame_rate;
  if (options.transparent) {
    browser_settings.background_color = 0;  // 透明
  } else {
    browser_settings.background_color = options.background_color;
  }
  browser_settings.javascript = options.enable_javascript ? STATE_ENABLED
                                                          : STATE_DISABLED;
  if (!options.default_encoding.empty()) {
    CefString(&browser_settings.default_encoding)
        .FromString(options.default_encoding);
  }

  // 同步创建：立即拿到 browser 句柄与 id。CreateBrowserSync 内部可能跑嵌套消息
  // 循环，期间置忙标志，阻止外部泵重入 CefDoMessageLoopWork（否则整窗无响应）。
  g_message_loop_busy.store(true);
  CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
      window_info, handler, url, browser_settings, nullptr, nullptr);
  g_message_loop_busy.store(false);
  if (!browser) {
    texture_bridge_->DisposeTexture(texture_id);
    return result;
  }

  const int id = browser->GetIdentifier();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    Entry entry;
    entry.handler = handler;
    entry.browser = browser;
    entry.texture_id = texture_id;
    entry.logical_w = width;
    entry.logical_h = height;
    entry.dpr = dpr;
    browsers_[id] = entry;
  }

  result.ok = true;
  result.browser_id = id;
  result.texture_id = texture_id;
  return result;
}

CefBrowserManager::Entry* CefBrowserManager::FindEntry(int browser_id) {
  auto it = browsers_.find(browser_id);
  return it == browsers_.end() ? nullptr : &it->second;
}

CefRefPtr<CefBrowser> CefBrowserManager::FindBrowser(int browser_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  Entry* e = FindEntry(browser_id);
  return e ? e->browser : nullptr;
}

void CefBrowserManager::CloseBrowser(int browser_id) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (b) b->GetHost()->CloseBrowser(/*force_close=*/true);
}

void CefBrowserManager::LoadUrl(int browser_id, const std::string& url) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (b && b->GetMainFrame()) b->GetMainFrame()->LoadURL(url);
}

void CefBrowserManager::Reload(int browser_id) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (b) b->Reload();
}

void CefBrowserManager::StopLoad(int browser_id) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (b) b->StopLoad();
}

void CefBrowserManager::GoBack(int browser_id) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (b && b->CanGoBack()) b->GoBack();
}

void CefBrowserManager::GoForward(int browser_id) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (b && b->CanGoForward()) b->GoForward();
}

void CefBrowserManager::Resize(int browser_id, int width, int height,
                               float dpr) {
  CefRefPtr<CefBrowser> b;
  bool dpr_changed = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    Entry* e = FindEntry(browser_id);
    if (!e) return;
    dpr_changed = (e->dpr != dpr);
    e->logical_w = width;
    e->logical_h = height;
    e->dpr = dpr;
    e->handler->SetViewSize(width, height, dpr);
    b = e->browser;
    if (texture_bridge_) {
      texture_bridge_->ResizeTexture(e->texture_id,
                                     static_cast<int>(width * dpr),
                                     static_cast<int>(height * dpr));
    }
  }
  if (b) {
    if (dpr_changed) b->GetHost()->NotifyScreenInfoChanged();
    b->GetHost()->WasResized();
  }
}

void CefBrowserManager::SetVisible(int browser_id, bool visible) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  b->GetHost()->WasHidden(!visible);
  if (visible) b->GetHost()->Invalidate(PET_VIEW);
}

void CefBrowserManager::SetFocus(int browser_id, bool focused) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (b) b->GetHost()->SetFocus(focused);
}

void CefBrowserManager::SetScreenOriginProvider(ScreenOriginProvider provider) {
  screen_origin_provider_ = std::move(provider);
}

bool CefBrowserManager::GetScreenOrigin(int* x, int* y) {
  if (!screen_origin_provider_) return false;
  return screen_origin_provider_(x, y);
}

void CefBrowserManager::SetFileDialogProvider(FileDialogProvider provider) {
  file_dialog_provider_ = std::move(provider);
}

bool CefBrowserManager::RequestFileDialog(const FileDialogRequest& request,
                                          FileDialogDoneCallback done) {
  if (!file_dialog_provider_) return false;
  file_dialog_provider_(request, std::move(done));
  return true;
}

void CefBrowserManager::EvaluateJavascript(int browser_id,
                                           const std::string& source) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (b && b->GetMainFrame()) {
    b->GetMainFrame()->ExecuteJavaScript(source, b->GetMainFrame()->GetURL(),
                                         0);
  }
}

void CefBrowserManager::SendMouseMove(int browser_id, double x, double y,
                                      bool leave, int modifiers) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  CefMouseEvent ev;
  ev.x = static_cast<int>(x);
  ev.y = static_cast<int>(y);
  ev.modifiers = modifiers;  // 携带按键位修饰符，使按住拖拽（框选）生效
  b->GetHost()->SendMouseMoveEvent(ev, leave);
}

void CefBrowserManager::SendMouseButton(int browser_id, double x, double y,
                                        int button, bool down, int click_count,
                                        int modifiers) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  CefMouseEvent ev;
  ev.x = static_cast<int>(x);
  ev.y = static_cast<int>(y);
  ev.modifiers = modifiers;
  b->GetHost()->SendMouseClickEvent(ev, MapButton(button), /*mouseUp=*/!down,
                                    click_count);
}

void CefBrowserManager::SendMouseWheel(int browser_id, double x, double y,
                                       double dx, double dy, int modifiers) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  CefMouseEvent ev;
  ev.x = static_cast<int>(x);
  ev.y = static_cast<int>(y);
  ev.modifiers = modifiers;  // Ctrl+滚轮缩放 / Shift+滚轮横向滚动
  b->GetHost()->SendMouseWheelEvent(ev, static_cast<int>(dx),
                                    static_cast<int>(dy));
}

namespace {
// 由文件绝对路径列表构造「文件拖拽」数据。AddFile 只交路径 + 展示名，Chromium
// 自行读盘，网页最终拿到带正确 name/size/type 的真 File（与在系统里直接拖入一致）。
// 一个文件都没能加进去时返回空引用：交一份没有文件的 CefDragData 进去，网页会收到
// 一次 dataTransfer 里什么都没有的 dragenter，上传区反而被置成「不接受」。
CefRefPtr<CefDragData> MakeFileDragData(const std::vector<std::string>& paths) {
  CefRefPtr<CefDragData> data = CefDragData::Create();
  if (!data) return nullptr;
  bool has_file = false;
  for (const auto& p : paths) {
    if (p.empty()) continue;
    std::string name = p;
    const size_t slash = name.find_last_of("/\\");
    if (slash != std::string::npos) name = name.substr(slash + 1);
    data->AddFile(CefString(p), CefString(name));
    has_file = true;
  }
  if (!has_file) return nullptr;
  return data;
}

CefMouseEvent MakeMouseEvent(double x, double y, int modifiers) {
  CefMouseEvent ev;
  ev.x = static_cast<int>(x);
  ev.y = static_cast<int>(y);
  ev.modifiers = modifiers;
  return ev;
}
}  // namespace

void CefBrowserManager::DragTargetDragEnter(
    int browser_id, double x, double y,
    const std::vector<std::string>& paths, int modifiers) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  CefRefPtr<CefDragData> data = MakeFileDragData(paths);
  // CefBrowserHost::DragTargetDragEnter 收到空 drag_data 会走 NOTREACHED 分支，
  // debug 构建直接中止；宁可整次拖放无效，也别把空数据递进去。
  if (!data) return;
  b->GetHost()->DragTargetDragEnter(data, MakeMouseEvent(x, y, modifiers),
                                    DRAG_OPERATION_EVERY);
}

void CefBrowserManager::DragTargetDragOver(int browser_id, double x, double y,
                                           int modifiers) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  b->GetHost()->DragTargetDragOver(MakeMouseEvent(x, y, modifiers),
                                   DRAG_OPERATION_EVERY);
}

void CefBrowserManager::DragTargetDragLeave(int browser_id) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  b->GetHost()->DragTargetDragLeave();
}

void CefBrowserManager::DragTargetDrop(int browser_id, double x, double y,
                                       int modifiers) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  b->GetHost()->DragTargetDrop(MakeMouseEvent(x, y, modifiers));
}

void CefBrowserManager::SendKey(int browser_id, int type, int windows_key_code,
                                int native_key_code, int modifiers,
                                int character) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  CefKeyEvent ev;
  ev.type = MapKeyType(type);
  ev.windows_key_code = windows_key_code;
  ev.native_key_code = native_key_code;
  ev.modifiers = modifiers;
  if (character != 0) {
    ev.character = static_cast<char16_t>(character);
    ev.unmodified_character = static_cast<char16_t>(character);
  }
#if defined(__APPLE__)
  // macOS：把编辑/导航键的 Windows VK 换成 macOS 原生键码 + 功能键字符，
  // 否则退格/方向键等在网页输入框中无效（编辑命令不触发）。windows_key_code
  // 保持不变，DOM keydown 的 keyCode/key 仍正确。
  {
    int mac_code = 0, mac_char = 0;
    if (MapMacEditingKey(windows_key_code, &mac_code, &mac_char)) {
      ev.native_key_code = mac_code;
      ev.character = static_cast<char16_t>(mac_char);
      ev.unmodified_character = static_cast<char16_t>(mac_char);
    }
  }
#endif
  b->GetHost()->SendKeyEvent(ev);
}

// --------------------------------------------------------------------------
// IME（输入法组字）：让中文/日文等输入法在 OSR 模式下可正常预编辑与提交。
// --------------------------------------------------------------------------

void CefBrowserManager::ImeSetComposition(int browser_id,
                                          const std::string& text,
                                          int selection_start,
                                          int selection_end) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  if (text.empty()) {
    b->GetHost()->ImeCancelComposition();
    return;
  }
  CefString ctext(text);
  const int len = static_cast<int>(ctext.length());
  // 给整段预编辑文本加一条下划线（IME 组字视觉）。
  CefCompositionUnderline underline;
  underline.range.from = 0;
  underline.range.to = static_cast<uint32_t>(len);
  underline.color = 0xFF000000;  // 不透明黑
  underline.background_color = 0;
  underline.thick = 0;
  std::vector<CefCompositionUnderline> underlines{underline};

  const uint32_t kInvalid = static_cast<uint32_t>(-1);
  CefRange replacement_range(kInvalid, kInvalid);  // 替换当前组字区
  CefRange selection_range(
      static_cast<uint32_t>(selection_start < 0 ? len : selection_start),
      static_cast<uint32_t>(selection_end < 0 ? len : selection_end));
  b->GetHost()->ImeSetComposition(ctext, underlines, replacement_range,
                                  selection_range);
}

void CefBrowserManager::ImeCommitText(int browser_id,
                                      const std::string& text) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  const uint32_t kInvalid = static_cast<uint32_t>(-1);
  b->GetHost()->ImeCommitText(text, CefRange(kInvalid, kInvalid),
                              /*relative_cursor_pos=*/0);
}

void CefBrowserManager::ImeFinishComposing(int browser_id,
                                           bool keep_selection) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  b->GetHost()->ImeFinishComposingText(keep_selection);
}

void CefBrowserManager::ImeCancelComposition(int browser_id) {
  CefRefPtr<CefBrowser> b = FindBrowser(browser_id);
  if (!b) return;
  b->GetHost()->ImeCancelComposition();
}

void CefBrowserManager::DoMessageLoopWork() {
  // 多线程消息循环模式下由 CEF 自己的线程驱动，外部不得再调用。
  if (!initialized_ || multi_threaded_) return;
  // 防重入：CreateBrowserSync 等同步调用内部会跑嵌套消息循环；若此时被泵再次触发
  // CefDoMessageLoopWork 会造成消息循环重入而卡死（打开页面后整窗无响应）。
  if (g_message_loop_busy.exchange(true)) return;
  CefDoMessageLoopWork();
  g_message_loop_busy.store(false);
}

void CefBrowserManager::Shutdown() {
  if (!initialized_) return;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto& kv : browsers_) {
      if (kv.second.browser)
        kv.second.browser->GetHost()->CloseBrowser(true);
    }
  }
  // 给关闭流程留出泵循环时间。
  for (int i = 0; i < 10; ++i) CefDoMessageLoopWork();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    browsers_.clear();
  }
  CefShutdown();
  initialized_ = false;
}

void CefBrowserManager::OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                                         int64_t texture_id) {
  // 映射已在 CreateBrowser 同步建立，这里无需额外处理。
}

void CefBrowserManager::OnBrowserClosed(int browser_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  browsers_.erase(browser_id);
}

}  // namespace cef_webview
