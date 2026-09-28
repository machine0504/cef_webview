// CefClient：单个 OSR 浏览器实例的全部回调处理器集合。
//
// 聚合实现：
//   CefRenderHandler        —— OSR：GetViewRect / GetScreenInfo / OnPaint
//   CefLifeSpanHandler      —— 创建/关闭/弹窗拦截
//   CefLoadHandler          —— 加载状态/错误
//   CefDisplayHandler       —— 地址/标题/进度
//   CefRequestHandler       —— 导航拦截/证书/渲染进程崩溃
//   CefContextMenuHandler   —— 屏蔽原生右键菜单
//   CefDialogHandler        —— 文件选择框（合并 <input accept> 多类型过滤器）
//   CefMessageRouterBrowserSide::Handler —— JS → C++ 查询
#ifndef CEF_WEBVIEW_HANDLER_H_
#define CEF_WEBVIEW_HANDLER_H_

#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

#include "include/cef_client.h"
#include "include/cef_dialog_handler.h"
#include "include/wrapper/cef_message_router.h"
#include "cef_webview/cef_event_sink.h"
#include "cef_webview/flutter_texture_bridge.h"

namespace cef_webview {

class CefWebviewHandler : public CefClient,
                          public CefRenderHandler,
                          public CefLifeSpanHandler,
                          public CefLoadHandler,
                          public CefDisplayHandler,
                          public CefRequestHandler,
                          public CefContextMenuHandler,
                          public CefJSDialogHandler,
                          public CefDialogHandler {
 public:
  // 当浏览器创建/销毁时通知 manager 维护其映射表。
  class Delegate {
   public:
    virtual ~Delegate() = default;
    virtual void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                                  int64_t texture_id) = 0;
    virtual void OnBrowserClosed(int browser_id) = 0;
  };

  CefWebviewHandler(FlutterTextureBridge* texture_bridge,
                    CefEventSink* sink,
                    Delegate* delegate,
                    int64_t texture_id);

  void SetViewSize(int logical_width, int logical_height, float dpr);

  // ---- CefClient ----
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
    return this;
  }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;

  // ---- CefRenderHandler (OSR) ----
  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
  bool GetScreenInfo(CefRefPtr<CefBrowser> browser,
                     CefScreenInfo& screen_info) override;
  bool GetScreenPoint(CefRefPtr<CefBrowser> browser, int viewX, int viewY,
                      int& screenX, int& screenY) override;
  void OnPaint(CefRefPtr<CefBrowser> browser,
               PaintElementType type,
               const RectList& dirtyRects,
               const void* buffer,
               int width,
               int height) override;
  // GPU 加速路径（shared_texture_enabled=true 时由 CEF 调用，替代 OnPaint）。
  void OnAcceleratedPaint(CefRefPtr<CefBrowser> browser,
                          PaintElementType type,
                          const RectList& dirtyRects,
                          const CefAcceleratedPaintInfo& info) override;
  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override;
  void OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) override;
  void OnImeCompositionRangeChanged(
      CefRefPtr<CefBrowser> browser,
      const CefRange& selected_range,
      const RectList& character_bounds) override;

  // ---- CefLifeSpanHandler ----
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
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
                     bool* no_javascript_access) override;

  // ---- CefLoadHandler ----
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override;

  // ---- CefDisplayHandler ----
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override;
  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                               double progress) override;
  // OSR 下 CEF 无系统窗口可改光标：把指针类型上报 Dart，由 Flutter 的
  // MouseRegion 换成对应 SystemMouseCursor（链接=小手 / 文本=I 形 / 缩放等）。
  bool OnCursorChange(CefRefPtr<CefBrowser> browser,
                      CefCursorHandle cursor,
                      cef_cursor_type_t type,
                      const CefCursorInfo& custom_cursor_info) override;

  // ---- CefRequestHandler ----
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
  bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                          ErrorCode cert_error,
                          const CefString& request_url,
                          CefRefPtr<CefSSLInfo> ssl_info,
                          CefRefPtr<CefCallback> callback) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString& error_string) override;

  // ---- CefContextMenuHandler ----
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override;

  // ---- CefJSDialogHandler ----
  // OSR 无系统窗口，默认 JS 对话框会以不可见的原生窗口弹出并阻塞消息循环，
  // 这里一律抑制 / 自动放行，避免整窗"无响应"。
  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString& origin_url,
                  JSDialogType dialog_type,
                  const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppress_message) override;
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString& message_text,
                            bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override;

  // ---- CefDialogHandler ----
  // <input type=file accept="..."> 会把每个 accept 项拆成一个过滤器传进来，
  // CEF 默认对话框只默认选中第一个（表现为"只能选 PDF"）。这里把其中的扩展名
  // 项合并成一个「支持的文件」组合过滤器置顶作为默认，再用 RunFileDialog 重弹，
  // 让用户一次就能看到 web 声明支持的全部类型。
  bool OnFileDialog(CefRefPtr<CefBrowser> browser,
                    FileDialogMode mode,
                    const CefString& title,
                    const CefString& default_file_path,
                    const std::vector<CefString>& accept_filters,
                    const std::vector<CefString>& accept_extensions,
                    const std::vector<CefString>& accept_descriptions,
                    CefRefPtr<CefFileDialogCallback> callback) override;

 private:
  FlutterTextureBridge* texture_bridge_;  // 不持有
  CefEventSink* sink_;                    // 不持有
  Delegate* delegate_;                    // 不持有
  const int64_t texture_id_;

  std::atomic<int> browser_id_{0};
  int logical_width_ = 1024;
  int logical_height_ = 768;
  float dpr_ = 1.0f;

  bool last_loading_ = false;
  bool last_back_ = false;
  bool last_forward_ = false;

  // OSR 弹层（<select> 下拉、日期选择器等 PET_POPUP）合成状态。
  // 无弹层时主视图直接转发（零额外拷贝）；弹层出现时缓存主视图并叠加弹层。
  bool popup_visible_ = false;
  CefRect popup_rect_;                 // 弹层位置（DIP，需乘 dpr 映射到设备像素）
  std::vector<uint8_t> view_buffer_;   // 最近一帧主视图（BGRA，仅弹层期间缓存）
  int view_w_ = 0;
  int view_h_ = 0;
  std::vector<uint8_t> popup_buffer_;  // 最近一帧弹层（BGRA）
  int popup_w_ = 0;
  int popup_h_ = 0;

  CefRefPtr<CefMessageRouterBrowserSide> message_router_;
  std::unique_ptr<CefMessageRouterBrowserSide::Handler> query_handler_;

  IMPLEMENT_REFCOUNTING(CefWebviewHandler);
  DISALLOW_COPY_AND_ASSIGN(CefWebviewHandler);
};

}  // namespace cef_webview

#endif  // CEF_WEBVIEW_HANDLER_H_
