// CefApp：跨进程共享逻辑（浏览器进程 + 渲染进程）。
//
// - 浏览器进程：命令行裁剪/开关、上下文初始化。
// - 渲染进程  ：注入 window.cefBridge JS 桥；驱动 CefMessageRouter 渲染端。
#ifndef CEF_WEBVIEW_APP_H_
#define CEF_WEBVIEW_APP_H_

#include <functional>
#include <string>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "include/wrapper/cef_message_router.h"

namespace cef_webview {

class CefWebviewApp : public CefApp,
                      public CefBrowserProcessHandler,
                      public CefRenderProcessHandler {
 public:
  CefWebviewApp();

  // 在 CefInitialize 之前由 manager 设置，影响浏览器进程命令行开关。
  // 注：子进程通过命令行继承，无需重复设置。
  static void SetExtraSwitches(
      const std::vector<std::pair<std::string, std::string>>& switches);

  // GPU 加速（共享纹理）开关：true 时不注入 disable-gpu 系列，让 Chromium 启用
  // GPU 合成以产出 OnAcceleratedPaint 共享纹理。默认 false（软件 OSR）。
  // 必须在 CefInitialize 之前设置（浏览器进程命令行处理时读取）。
  static void SetGpuEnabled(bool enabled);

  // 外部消息泵调度回调（macOS 必需）：external_message_pump=true 时，CEF 通过
  // OnScheduleMessagePumpWork 请求在主线程调度一次 DoMessageLoopWork。平台层
  // （CefMacBridge）注册此回调，用 dispatch_after 切主线程执行。必须在
  // CefInitialize 之前设置。未设置时回调为空（Windows/Linux 用自有定时器泵）。
  static void SetScheduleMessagePumpWorkCallback(
      std::function<void(int64_t /*delay_ms*/)> cb);

  // CefApp
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override;
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  // CefBrowserProcessHandler
  void OnContextInitialized() override;
  void OnScheduleMessagePumpWork(int64_t delay_ms) override;

  // CefRenderProcessHandler
  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override;
  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override;
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;

 private:
  // 渲染进程侧消息路由（与浏览器进程侧 cefQuery 函数名保持一致）。
  CefRefPtr<CefMessageRouterRendererSide> render_message_router_;

  IMPLEMENT_REFCOUNTING(CefWebviewApp);
  DISALLOW_COPY_AND_ASSIGN(CefWebviewApp);
};

}  // namespace cef_webview

#endif  // CEF_WEBVIEW_APP_H_
