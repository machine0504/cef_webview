// 平台无关的「C++ → Dart 事件回传」抽象。
//
// 各端用各自的 MethodChannel 实现：把事件序列化为 {browserId, ...} 调用回 Dart。
#ifndef CEF_WEBVIEW_CEF_EVENT_SINK_H_
#define CEF_WEBVIEW_CEF_EVENT_SINK_H_

#include <string>

namespace cef_webview {

class CefEventSink {
 public:
  virtual ~CefEventSink() = default;

  virtual void OnLoadingStateChange(int browser_id,
                                    bool is_loading,
                                    bool can_go_back,
                                    bool can_go_forward,
                                    double progress) = 0;

  virtual void OnAddressChange(int browser_id, const std::string& url) = 0;

  virtual void OnTitleChange(int browser_id, const std::string& title) = 0;

  virtual void OnLoadError(int browser_id,
                           int error_code,
                           const std::string& error_text,
                           const std::string& failed_url) = 0;

  // data_json：页面通过 cefBridge.callHandler 传来的 JSON 字符串。
  virtual void OnJsMessage(int browser_id,
                           const std::string& handler,
                           const std::string& data_json) = 0;

  // 新窗口（target=_blank / window.open）请求，交由 Dart 业务决定。
  virtual void OnBeforePopup(int browser_id,
                             const std::string& target_url) = 0;

  // 全局/进程级错误（无 browserId）。
  virtual void OnGlobalError(const std::string& message) = 0;

  // IME 组字光标位置（DIP，相对 webview 左上角）。用于把系统输入法候选框
  // 定位到光标处。默认空实现，平台可选接入。
  virtual void OnImeCursorRect(int browser_id, int x, int y, int width,
                               int height) {}

  // 鼠标指针类型变化。OSR（离屏渲染）下 CEF 不会自动改系统光标：悬停在链接、
  // 文本、缩放手柄等元素上时，需宿主接管把 Flutter 侧光标换成对应形状。
  // cursor_type 为 cef_cursor_type_t 的整型值（见 include/internal/cef_types.h）。
  // 默认空实现，平台可选接入。
  virtual void OnCursorChange(int browser_id, int cursor_type) {}
};

}  // namespace cef_webview

#endif  // CEF_WEBVIEW_CEF_EVENT_SINK_H_
