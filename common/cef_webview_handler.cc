#include "cef_webview_handler.h"

#include "cef_browser_manager.h"
#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"

namespace cef_webview {

namespace {

// JS → C++ 查询处理器：解析 {handler, data} 并回传 Dart。
class QueryHandler : public CefMessageRouterBrowserSide::Handler {
 public:
  QueryHandler(CefEventSink* sink) : sink_(sink) {}

  bool OnQuery(CefRefPtr<CefBrowser> browser,
               CefRefPtr<CefFrame> frame,
               int64_t query_id,
               const CefString& request,
               bool persistent,
               CefRefPtr<Callback> callback) override {
    CefRefPtr<CefValue> root = CefParseJSON(
        request, JSON_PARSER_RFC);
    std::string handler = "postMessage";
    std::string data_json = "null";

    if (root && root->GetType() == VTYPE_DICTIONARY) {
      CefRefPtr<CefDictionaryValue> dict = root->GetDictionary();
      if (dict->HasKey("handler") &&
          dict->GetType("handler") == VTYPE_STRING) {
        handler = dict->GetString("handler").ToString();
      }
      if (dict->HasKey("data")) {
        CefRefPtr<CefValue> data = dict->GetValue("data");
        data_json = CefWriteJSON(data, JSON_WRITER_DEFAULT).ToString();
      }
    }

    if (sink_) {
      sink_->OnJsMessage(browser->GetIdentifier(), handler, data_json);
    }
    // 立即应答以解析页面侧 Promise；如需把 Dart 处理结果回传给 JS，
    // 可改为 persistent + 异步保存 callback（见 docs/README JS 双向通道）。
    callback->Success("");
    return true;
  }

 private:
  CefEventSink* sink_;
};

// RunFileDialog 的回调：把「合并过滤器」对话框的选择结果回传给原始
// <input type=file> 的 CefFileDialogCallback。空选择等价取消。
class MergedFileDialogCallback : public CefRunFileDialogCallback {
 public:
  explicit MergedFileDialogCallback(CefRefPtr<CefFileDialogCallback> original)
      : original_(original) {}

  void OnFileDialogDismissed(
      const std::vector<CefString>& file_paths) override {
    if (file_paths.empty()) {
      original_->Cancel();
    } else {
      original_->Continue(file_paths);
    }
  }

 private:
  CefRefPtr<CefFileDialogCallback> original_;
  IMPLEMENT_REFCOUNTING(MergedFileDialogCallback);
  DISALLOW_COPY_AND_ASSIGN(MergedFileDialogCallback);
};

// 平台原生文件框选择结果：在 CEF UI 线程上回传给 <input type=file> 的 callback。
// 用自定义 CefTask（而非 base::BindOnce）投递，避免依赖 libcef_dll_wrapper 的
// base::Bind/RefCountedThreadSafeBase 符号（macOS 直链模型下会链接失败）。
// 空 paths 等价取消。
class FileDialogResultTask : public CefTask {
 public:
  FileDialogResultTask(CefRefPtr<CefFileDialogCallback> callback,
                       std::vector<CefString> paths)
      : callback_(callback), paths_(std::move(paths)) {}

  void Execute() override {
    if (paths_.empty()) {
      callback_->Cancel();
    } else {
      callback_->Continue(paths_);
    }
  }

 private:
  CefRefPtr<CefFileDialogCallback> callback_;
  std::vector<CefString> paths_;
  IMPLEMENT_REFCOUNTING(FileDialogResultTask);
  DISALLOW_COPY_AND_ASSIGN(FileDialogResultTask);
};

// 把弹层（popup）BGRA 缓冲按设备像素坐标覆盖到主视图缓冲之上。
// rect 为 DIP（视图逻辑像素），需乘 dpr 映射到设备像素。
void OverlayPopup(std::vector<uint8_t>& view, int vw, int vh,
                  const std::vector<uint8_t>& popup, int pw, int ph,
                  const CefRect& rect, float dpr) {
  if (view.empty() || popup.empty() || pw <= 0 || ph <= 0) return;
  const int x0 = static_cast<int>(rect.x * dpr + 0.5f);
  const int y0 = static_cast<int>(rect.y * dpr + 0.5f);
  for (int row = 0; row < ph; ++row) {
    const int vy = y0 + row;
    if (vy < 0 || vy >= vh) continue;
    for (int col = 0; col < pw; ++col) {
      const int vx = x0 + col;
      if (vx < 0 || vx >= vw) continue;
      const size_t s = (static_cast<size_t>(row) * pw + col) * 4;
      const size_t d = (static_cast<size_t>(vy) * vw + vx) * 4;
      view[d + 0] = popup[s + 0];
      view[d + 1] = popup[s + 1];
      view[d + 2] = popup[s + 2];
      view[d + 3] = popup[s + 3];
    }
  }
}

}  // namespace

CefWebviewHandler::CefWebviewHandler(FlutterTextureBridge* texture_bridge,
                                     CefEventSink* sink,
                                     Delegate* delegate,
                                     int64_t texture_id)
    : texture_bridge_(texture_bridge),
      sink_(sink),
      delegate_(delegate),
      texture_id_(texture_id) {
  CefMessageRouterConfig config;  // 默认 cefQuery / cefQueryCancel
  message_router_ = CefMessageRouterBrowserSide::Create(config);
  query_handler_.reset(new QueryHandler(sink_));
  message_router_->AddHandler(query_handler_.get(), /*first=*/false);
}

void CefWebviewHandler::SetViewSize(int logical_width,
                                    int logical_height,
                                    float dpr) {
  if (logical_width > 0) logical_width_ = logical_width;
  if (logical_height > 0) logical_height_ = logical_height;
  if (dpr > 0) dpr_ = dpr;
}

// --------------------------------------------------------------------------
// CefRenderHandler (OSR)
// --------------------------------------------------------------------------

void CefWebviewHandler::GetViewRect(CefRefPtr<CefBrowser> browser,
                                    CefRect& rect) {
  // 返回逻辑像素；设备像素缩放交由 GetScreenInfo 的 device_scale_factor。
  rect.Set(0, 0, logical_width_, logical_height_);
}

bool CefWebviewHandler::GetScreenInfo(CefRefPtr<CefBrowser> browser,
                                      CefScreenInfo& screen_info) {
  screen_info.device_scale_factor = dpr_;
  // 屏幕/可用区域用视图矩形（DIP）填充，参照 cefclient 的 OSR 实现，供 CEF
  // 计算视口、弹层与输入法定位时使用。
  const CefRect view(0, 0, logical_width_, logical_height_);
  screen_info.rect = view;
  screen_info.available_rect = view;
  return true;
}

bool CefWebviewHandler::GetScreenPoint(CefRefPtr<CefBrowser> browser, int viewX,
                                       int viewY, int& screenX, int& screenY) {
  int ox = 0, oy = 0;
  if (!CefBrowserManager::Instance().GetScreenOrigin(&ox, &oy)) return false;
  // viewX/viewY 为 DIP，乘 dpr 得设备像素，再加窗口客户区屏幕原点。
  screenX = ox + static_cast<int>(viewX * dpr_);
  screenY = oy + static_cast<int>(viewY * dpr_);
  return true;
}

void CefWebviewHandler::OnPaint(CefRefPtr<CefBrowser> browser,
                                PaintElementType type,
                                const RectList& dirtyRects,
                                const void* buffer,
                                int width,
                                int height) {
  if (!texture_bridge_) return;
  const uint8_t* src = static_cast<const uint8_t*>(buffer);

  if (type == PET_VIEW) {
    view_w_ = width;
    view_h_ = height;
    // 无弹层：直接转发。附带脏矩形包围盒，软件路径据此只增量转色/上传变化区域
    // （打字/光标等小改动时省掉整幅 CPU 开销）。GPU 路径忽略它。
    if (!popup_visible_ || popup_buffer_.empty()) {
      view_buffer_.clear();
      int dx = 0, dy = 0, dw = width, dh = height;
      if (!dirtyRects.empty()) {
        int x0 = width, y0 = height, x1 = 0, y1 = 0;
        for (const CefRect& r : dirtyRects) {
          if (r.x < x0) x0 = r.x;
          if (r.y < y0) y0 = r.y;
          if (r.x + r.width > x1) x1 = r.x + r.width;
          if (r.y + r.height > y1) y1 = r.y + r.height;
        }
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 > width) x1 = width;
        if (y1 > height) y1 = height;
        if (x1 > x0 && y1 > y0) {
          dx = x0; dy = y0; dw = x1 - x0; dh = y1 - y0;
        }
      }
      texture_bridge_->OnFrameRect(texture_id_, buffer, width, height, dx, dy,
                                   dw, dh);
      return;
    }
    // 有弹层：缓存主视图并叠加弹层后提交。
    view_buffer_.assign(src, src + static_cast<size_t>(width) * height * 4);
    std::vector<uint8_t> composed = view_buffer_;
    OverlayPopup(composed, view_w_, view_h_, popup_buffer_, popup_w_, popup_h_,
                 popup_rect_, dpr_);
    texture_bridge_->OnFrame(texture_id_, composed.data(), view_w_, view_h_);
    return;
  }

  if (type == PET_POPUP) {
    popup_w_ = width;
    popup_h_ = height;
    popup_buffer_.assign(src, src + static_cast<size_t>(width) * height * 4);
    // 需要主视图作为底图；若尚未缓存，请求重绘一次主视图来触发合成。
    if (view_buffer_.empty() || view_w_ <= 0) {
      if (browser) browser->GetHost()->Invalidate(PET_VIEW);
      return;
    }
    std::vector<uint8_t> composed = view_buffer_;
    OverlayPopup(composed, view_w_, view_h_, popup_buffer_, popup_w_, popup_h_,
                 popup_rect_, dpr_);
    texture_bridge_->OnFrame(texture_id_, composed.data(), view_w_, view_h_);
  }
}

void CefWebviewHandler::OnAcceleratedPaint(
    CefRefPtr<CefBrowser> browser,
    PaintElementType type,
    const RectList& dirtyRects,
    const CefAcceleratedPaintInfo& info) {
  if (!texture_bridge_) return;
  // GPU 加速路径：只提交主视图。PET_POPUP（<select> 下拉等）在 GPU 模式下改由
  // Dart 层用独立 Texture 叠加，不再做 CPU 像素合成。
  if (type != PET_VIEW) return;

  AcceleratedFrameInfo frame;
  frame.width = static_cast<int>(logical_width_ * dpr_ + 0.5f);
  frame.height = static_cast<int>(logical_height_ * dpr_ + 0.5f);
  frame.format = static_cast<int>(info.format);
#if defined(_WIN32)
  frame.shared_handle = info.shared_texture_handle;
#elif defined(__APPLE__)
  frame.shared_handle = info.shared_texture_io_surface;
#elif defined(__linux__)
  // Linux（Ozone/X11 + GPU 合成）：CEF 通过 native pixmap 交付 DMABUF。
  // 对应 CEF 头文件 include/internal/cef_types.h 的：
  //   cef_accelerated_paint_info_t { planes[4]; plane_count; modifier; format; }
  //   cef_accelerated_paint_native_pixmap_plane_info_t { stride; offset; size; fd; }
  // 若在目标机编译报字段名不符，请对照该头文件调整（版本 144 使用如下名字）。
  frame.plane_count = info.plane_count;
  frame.modifier = info.modifier;
  for (int i = 0; i < info.plane_count && i < 4; ++i) {
    frame.planes[i].fd = info.planes[i].fd;
    frame.planes[i].stride = info.planes[i].stride;
    frame.planes[i].offset = static_cast<uint32_t>(info.planes[i].offset);
    frame.planes[i].size = info.planes[i].size;
  }
#endif
  texture_bridge_->OnAcceleratedFrame(texture_id_, frame);
}

void CefWebviewHandler::OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) {
  popup_visible_ = show;
  if (!show) {
    popup_rect_ = CefRect();
    popup_buffer_.clear();
    popup_w_ = popup_h_ = 0;
    // 弹层关闭：重绘主视图擦除残留。
    if (browser) browser->GetHost()->Invalidate(PET_VIEW);
  }
}

void CefWebviewHandler::OnPopupSize(CefRefPtr<CefBrowser> browser,
                                    const CefRect& rect) {
  popup_rect_ = rect;
}

void CefWebviewHandler::OnImeCompositionRangeChanged(
    CefRefPtr<CefBrowser> browser,
    const CefRange& selected_range,
    const RectList& character_bounds) {
  // 把组字光标位置回传 Dart，用于把系统输入法候选框定位到光标处。
  // character_bounds 为视图 DIP 坐标（相对 webview 左上角）。
  if (!sink_ || character_bounds.empty()) return;
  const CefRect& r = character_bounds.back();
  sink_->OnImeCursorRect(browser_id_, r.x, r.y, r.width, r.height);
}

// --------------------------------------------------------------------------
// CefLifeSpanHandler
// --------------------------------------------------------------------------

void CefWebviewHandler::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  browser_id_ = browser->GetIdentifier();
  if (delegate_) delegate_->OnBrowserCreated(browser, texture_id_);
}

bool CefWebviewHandler::DoClose(CefRefPtr<CefBrowser> browser) {
  return false;  // 允许正常关闭
}

void CefWebviewHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  if (message_router_) {
    message_router_->OnBeforeClose(browser);
    message_router_->RemoveHandler(query_handler_.get());
  }
  const int id = browser->GetIdentifier();
  if (texture_bridge_) texture_bridge_->DisposeTexture(texture_id_);
  if (delegate_) delegate_->OnBrowserClosed(id);
}

bool CefWebviewHandler::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    int popup_id,
    const CefString& target_url,
    const CefString& target_frame_name,
    cef_window_open_disposition_t target_disposition,
    bool user_gesture,
    const CefPopupFeatures& popupFeatures,
    CefWindowInfo& windowInfo,
    CefRefPtr<CefClient>& client,
    CefBrowserSettings& settings,
    CefRefPtr<CefDictionaryValue>& extra_info,
    bool* no_javascript_access) {
  // OSR 模式不自动开独立系统窗口：上报 Dart，由业务再走链接拦截。
  if (sink_) {
    sink_->OnBeforePopup(browser->GetIdentifier(), target_url.ToString());
  }
  return true;  // 取消默认弹窗
}

// --------------------------------------------------------------------------
// CefLoadHandler
// --------------------------------------------------------------------------

void CefWebviewHandler::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                             bool isLoading,
                                             bool canGoBack,
                                             bool canGoForward) {
  last_loading_ = isLoading;
  last_back_ = canGoBack;
  last_forward_ = canGoForward;
  if (sink_) {
    sink_->OnLoadingStateChange(browser->GetIdentifier(), isLoading, canGoBack,
                                canGoForward, isLoading ? 0.0 : 1.0);
  }
}

void CefWebviewHandler::OnLoadError(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    ErrorCode errorCode,
                                    const CefString& errorText,
                                    const CefString& failedUrl) {
  if (!frame->IsMain()) return;  // 仅主框架失败才上报错误页
  if (sink_) {
    sink_->OnLoadError(browser->GetIdentifier(), errorCode,
                       errorText.ToString(), failedUrl.ToString());
  }
}

// --------------------------------------------------------------------------
// CefDisplayHandler
// --------------------------------------------------------------------------

void CefWebviewHandler::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        const CefString& url) {
  if (!frame->IsMain()) return;
  if (sink_) sink_->OnAddressChange(browser->GetIdentifier(), url.ToString());
}

void CefWebviewHandler::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                      const CefString& title) {
  if (sink_) sink_->OnTitleChange(browser->GetIdentifier(), title.ToString());
}

void CefWebviewHandler::OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                                                double progress) {
  if (sink_) {
    sink_->OnLoadingStateChange(browser->GetIdentifier(), last_loading_,
                                last_back_, last_forward_, progress);
  }
}

bool CefWebviewHandler::OnCursorChange(CefRefPtr<CefBrowser> browser,
                                       CefCursorHandle cursor,
                                       cef_cursor_type_t type,
                                       const CefCursorInfo& custom_cursor_info) {
  // OSR 无系统窗口，CEF 无法自行改光标：把指针类型（cef_cursor_type_t）回传
  // Dart，由 CefWebviewWidget 的 MouseRegion 映射为对应 SystemMouseCursor。
  // 返回 true 表示已接管（默认行为在 windowless 下本就无效）。
  if (sink_) sink_->OnCursorChange(browser->GetIdentifier(),
                                   static_cast<int>(type));
  return true;
}

// --------------------------------------------------------------------------
// CefRequestHandler
// --------------------------------------------------------------------------

bool CefWebviewHandler::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       CefRefPtr<CefRequest> request,
                                       bool user_gesture,
                                       bool is_redirect) {
  if (message_router_) message_router_->OnBeforeBrowse(browser, frame);
  return false;  // 允许导航（白名单在 Dart 层 open() 已校验）
}

bool CefWebviewHandler::OnCertificateError(CefRefPtr<CefBrowser> browser,
                                           ErrorCode cert_error,
                                           const CefString& request_url,
                                           CefRefPtr<CefSSLInfo> ssl_info,
                                           CefRefPtr<CefCallback> callback) {
  // 默认拒绝不可信证书，并以加载错误形式上报，业务可在 Dart 侧提示用户。
  if (sink_) {
    sink_->OnLoadError(browser->GetIdentifier(), cert_error,
                       "SSL certificate error", request_url.ToString());
  }
  return false;  // 返回 false：采用默认行为（取消该请求）
}

void CefWebviewHandler::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                                  TerminationStatus status,
                                                  int error_code,
                                                  const CefString& error_string) {
  if (message_router_) message_router_->OnRenderProcessTerminated(browser);
  if (sink_) sink_->OnGlobalError("Render process terminated");
  // 渲染进程崩溃后自动重载，避免白屏。
  if (browser && browser->GetMainFrame()) {
    browser->GetMainFrame()->LoadURL(browser->GetMainFrame()->GetURL());
  }
}

// --------------------------------------------------------------------------
// CefContextMenuHandler
// --------------------------------------------------------------------------

void CefWebviewHandler::OnBeforeContextMenu(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefContextMenuParams> params,
    CefRefPtr<CefMenuModel> model) {
  // OSR 下原生右键菜单无法正确定位，直接清空。
  model->Clear();
}

// --------------------------------------------------------------------------
// CefJSDialogHandler
//
// OSR（windowless）下没有真正的系统窗口；若不接管，alert/confirm/prompt 以及
// 切走/关闭页面时的 beforeunload 确认框会走 CEF 默认实现——弹出一个无父窗口、
// 不可见也无法点击的原生对话框，其模态消息循环会把平台线程的消息泵彻底堵死，
// 表现为整窗永久"无响应"（调用栈停在 CefDoMessageLoopWork 内）。
// 这里一律抑制 / 自动放行，保证消息循环不被阻塞。
// --------------------------------------------------------------------------
bool CefWebviewHandler::OnJSDialog(CefRefPtr<CefBrowser> browser,
                                   const CefString& origin_url,
                                   JSDialogType dialog_type,
                                   const CefString& message_text,
                                   const CefString& default_prompt_text,
                                   CefRefPtr<CefJSDialogCallback> callback,
                                   bool& suppress_message) {
  // 抑制对话框：alert 立即返回，confirm 视为取消，prompt 返回空——都不阻塞。
  suppress_message = true;
  return false;
}

bool CefWebviewHandler::OnBeforeUnloadDialog(
    CefRefPtr<CefBrowser> browser,
    const CefString& message_text,
    bool is_reload,
    CefRefPtr<CefJSDialogCallback> callback) {
  // 自动允许卸载/关闭，避免 beforeunload 原生确认框阻塞消息循环（切页面/关页时）。
  callback->Continue(true, CefString());
  return true;
}

// --------------------------------------------------------------------------
// CefDialogHandler：文件选择框（<input type=file>）
// --------------------------------------------------------------------------
bool CefWebviewHandler::OnFileDialog(
    CefRefPtr<CefBrowser> browser,
    FileDialogMode mode,
    const CefString& title,
    const CefString& default_file_path,
    const std::vector<CefString>& accept_filters,
    const std::vector<CefString>& accept_extensions,
    const std::vector<CefString>& accept_descriptions,
    CefRefPtr<CefFileDialogCallback> callback) {
  // 优先交平台层用系统原生对话框呈现：OSR + 空父窗口下 CEF 自带框在部分平台
  // （尤其 macOS）弹不出来，故对所有 <input type=file> 统一走原生框，网页零改造。
  FileDialogRequest req;
  req.mode = static_cast<int>(mode);
  req.multiple = (req.mode == FILE_DIALOG_OPEN_MULTIPLE);
  req.title = title.ToString();
  req.default_path = default_file_path.ToString();
  req.accept_filters.reserve(accept_filters.size());
  for (const auto& f : accept_filters)
    req.accept_filters.push_back(f.ToString());

  CefRefPtr<CefFileDialogCallback> cb = callback;
  auto done = [cb](const std::vector<std::string>& paths) {
    std::vector<CefString> cef_paths;
    cef_paths.reserve(paths.size());
    for (const auto& p : paths) cef_paths.push_back(CefString(p));
    // Continue/Cancel 必须在 CEF UI 线程执行；provider 回调可能在别的线程。
    CefRefPtr<CefTask> task = new FileDialogResultTask(cb, std::move(cef_paths));
    if (CefCurrentlyOn(TID_UI)) {
      task->Execute();
    } else {
      CefPostTask(TID_UI, task);
    }
  };
  if (CefBrowserManager::Instance().RequestFileDialog(req, done)) {
    return true;  // 平台已接管，稍后异步回传结果
  }

  // 回退（未注册平台 provider 时）：合并过滤器后走 CEF 自带 RunFileDialog。
  // 少于 2 个过滤器（或无过滤器 = 本就可选所有）无需重组，交默认对话框。
  if (accept_filters.size() < 2) return false;

  // 防重入：RunFileDialog 在个别平台可能回调本方法，此时首项已是本类生成的
  // 组合项（以下述前缀开头），直接走默认对话框，避免递归。
  static const char kMergedPrefix[] = "支持的文件|";
  if (accept_filters.front().ToString().rfind(kMergedPrefix, 0) == 0) {
    return false;
  }

  // 收集扩展名项（".pdf" 等）合并为一个组合过滤器；MIME 项（"image/*"）无法进
  // 组合，保留为独立过滤器项，供用户在下拉里单独筛选。
  std::string exts;
  for (const auto& f : accept_filters) {
    const std::string s = f.ToString();
    if (s.size() >= 2 && s[0] == '.') {
      if (!exts.empty()) exts += ";";
      exts += s;
    }
  }
  if (exts.empty()) return false;  // 纯 MIME：交默认对话框处理

  std::vector<CefString> merged;
  merged.reserve(accept_filters.size() + 1);
  // 组合项置顶并设为默认选中，用户打开即可看到 web 声明支持的全部类型。
  merged.push_back(CefString(std::string(kMergedPrefix) + exts));
  for (const auto& f : accept_filters) merged.push_back(f);

  browser->GetHost()->RunFileDialog(mode, title, default_file_path, merged,
                                    new MergedFileDialogCallback(callback));
  return true;  // 已接管，稍后由 MergedFileDialogCallback 回传结果
}

// --------------------------------------------------------------------------
// CefClient
// --------------------------------------------------------------------------

bool CefWebviewHandler::OnProcessMessageReceived(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefProcessId source_process,
    CefRefPtr<CefProcessMessage> message) {
  if (message_router_) {
    return message_router_->OnProcessMessageReceived(browser, frame,
                                                     source_process, message);
  }
  return false;
}

}  // namespace cef_webview
