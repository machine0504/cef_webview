#include "cef_webview_app.h"

#include <cstdlib>

#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"

namespace cef_webview {

namespace {
// JS 桥：把 cefQuery 包装成更友好的 window.cefBridge。
// 页面侧用法：
//   window.cefBridge.callHandler('foo', {a:1});  // -> Dart onJsMessage
//   window.cefBridge.postMessage('hi');           // -> Dart onJsMessage('postMessage', ...)
const char kBridgeJs[] =
    "(function(){\n"
    "  if (window.cefBridge) return;\n"
    "  function send(handler, data){\n"
    "    return new Promise(function(resolve, reject){\n"
    "      window.cefQuery({\n"
    "        request: JSON.stringify({handler: handler, data: data}),\n"
    "        onSuccess: function(r){ try{resolve(JSON.parse(r));}catch(e){resolve(r);} },\n"
    "        onFailure: function(c,m){ reject(m); }\n"
    "      });\n"
    "    });\n"
    "  }\n"
    "  window.cefBridge = {\n"
    "    callHandler: function(name){\n"
    "      var args = Array.prototype.slice.call(arguments, 1);\n"
    "      return send(name, args.length===1 ? args[0] : args);\n"
    "    },\n"
    "    postMessage: function(msg){ return send('postMessage', msg); }\n"
    "  };\n"
    "})();";

std::vector<std::pair<std::string, std::string>>& GlobalExtraSwitches() {
  static std::vector<std::pair<std::string, std::string>> switches;
  return switches;
}

bool& GlobalGpuEnabled() {
  static bool enabled = false;
  return enabled;
}

// 子进程(renderer/gpu)是独立可执行，其进程内 GlobalGpuEnabled() 默认 false；
// Linux 引擎在浏览器进程用环境变量 CEFWV_GPU_EFFECTIVE 把决定传递给子进程，
// 使其命令行开关（是否 disable-gpu）与浏览器进程一致。mac/win 直链模型下不设该
// 环境变量，退化为 GlobalGpuEnabled()（进程内已正确设置），行为不变。
bool EffectiveGpuEnabled() {
  if (GlobalGpuEnabled()) return true;
  // MSVC + Flutter /WX：getenv 触发 C4996；此处仅读调试环境变量。
#if defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4996)
#endif
  const char* e = getenv("CEFWV_GPU_EFFECTIVE");
#if defined(_MSC_VER)
#pragma warning(pop)
#endif
  return e && e[0] == '1';
}

std::function<void(int64_t)>& GlobalScheduleMessagePumpCb() {
  static std::function<void(int64_t)> cb;
  return cb;
}
}  // namespace

void CefWebviewApp::SetExtraSwitches(
    const std::vector<std::pair<std::string, std::string>>& switches) {
  GlobalExtraSwitches() = switches;
}

void CefWebviewApp::SetGpuEnabled(bool enabled) {
  GlobalGpuEnabled() = enabled;
}

void CefWebviewApp::SetScheduleMessagePumpWorkCallback(
    std::function<void(int64_t)> cb) {
  GlobalScheduleMessagePumpCb() = std::move(cb);
}

CefWebviewApp::CefWebviewApp() {}

void CefWebviewApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {
  // 仅对浏览器进程追加全局开关（process_type 为空即浏览器进程）。
  if (!process_type.empty()) return;

  // OSR 离屏渲染相关：禁用 GPU 合成可显著降低 Linux 下的兼容性问题，
  // 但会牺牲性能。是否禁用由 Dart 侧 extraCommandLineSwitches 决定，
  // 这里仅设置离屏渲染必需/通用的开关。
  // OSR 在虚拟机/无独显环境用软件渲染更稳；GPU 放进主进程（in-process-gpu）
  // 避免独立 GPU 子进程在此类环境启动失败导致 FATAL。
  if (EffectiveGpuEnabled()) {
    // GPU 加速 OSR：不禁用 GPU，让 Chromium 启用 GPU 合成，改走
    // OnAcceleratedPaint 输出共享纹理（Windows D3D11 / macOS IOSurface /
    // Linux DMABUF），实现零 CPU 拷贝上屏。--use-angle/--ozone-platform 等
    // GPU 相关开关由浏览器进程命令行自动传播给本子进程，无需在此重复注入。
    command_line->AppendSwitch("enable-begin-frame-scheduling");
  } else {
    // 软件 OSR（默认，最稳）：禁用 GPU 合成，OnPaint 输出 CPU BGRA 帧。GPU 放
    // 主进程（in-process-gpu）避免独立 GPU 子进程在虚拟机/无独显环境启动失败。
    command_line->AppendSwitch("disable-gpu");
    command_line->AppendSwitch("disable-gpu-compositing");
    command_line->AppendSwitch("in-process-gpu");
    // OSR 必需：windowless 下按帧调度绘制，缺失会画几帧后停刷、整窗"无响应"。
    command_line->AppendSwitch("enable-begin-frame-scheduling");
  }
  // 关闭部分会唤起系统窗口/通知的特性，避免与 Flutter 抢占资源。
  command_line->AppendSwitchWithValue("disable-features",
                                      "HardwareMediaKeyHandling");

  // 透传 Dart 侧 extraCommandLineSwitches。
  for (const auto& kv : GlobalExtraSwitches()) {
    if (kv.second.empty()) {
      command_line->AppendSwitch(kv.first);
    } else {
      command_line->AppendSwitchWithValue(kv.first, kv.second);
    }
  }
}

void CefWebviewApp::OnContextInitialized() {
  CEF_REQUIRE_UI_THREAD();
  // 浏览器进程上下文已就绪。此处可做全局 Cookie/代理等初始化。
}

void CefWebviewApp::OnScheduleMessagePumpWork(int64_t delay_ms) {
  // external_message_pump=true 时由 CEF 从任意线程调用，请求在主(UI)线程调度
  // 一次 CefDoMessageLoopWork。转交平台层（macOS：dispatch_after 切主线程）。
  auto& cb = GlobalScheduleMessagePumpCb();
  if (cb) cb(delay_ms);
}

void CefWebviewApp::OnContextCreated(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefV8Context> context) {
  if (!render_message_router_) {
    CefMessageRouterConfig config;  // 默认 js_query_function = "cefQuery"
    render_message_router_ = CefMessageRouterRendererSide::Create(config);
  }
  render_message_router_->OnContextCreated(browser, frame, context);

  // 注入 JS 桥（每个 frame 的上下文创建时）。
  frame->ExecuteJavaScript(kBridgeJs, frame->GetURL(), 0);
}

void CefWebviewApp::OnContextReleased(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      CefRefPtr<CefV8Context> context) {
  if (render_message_router_) {
    render_message_router_->OnContextReleased(browser, frame, context);
  }
}

bool CefWebviewApp::OnProcessMessageReceived(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefProcessId source_process,
    CefRefPtr<CefProcessMessage> message) {
  if (render_message_router_) {
    return render_message_router_->OnProcessMessageReceived(
        browser, frame, source_process, message);
  }
  return false;
}

}  // namespace cef_webview
