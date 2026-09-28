// 平台无关的 CEF 运行时管理器（单例）。
//
// 各端插件只需：
//   1) 提供 FlutterTextureBridge / CefEventSink 的平台实现；
//   2) 构造 CefMainArgs 与 CefInitConfig（填充 subprocess/资源路径）；
//   3) 在平台主循环上定时调用 DoMessageLoopWork()；
//   4) 解析自己的 MethodChannel 参数后转调本类的方法。
#ifndef CEF_WEBVIEW_BROWSER_MANAGER_H_
#define CEF_WEBVIEW_BROWSER_MANAGER_H_

#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "cef_webview/cef_event_sink.h"
#include "cef_webview/flutter_texture_bridge.h"
#include "cef_webview_handler.h"

namespace cef_webview {

struct CefInitConfig {
  std::string cache_path;
  std::string locale = "zh-CN";
  std::string user_agent_suffix;
  std::string subprocess_path;  // Linux/Windows：helper 可执行；macOS 可空
  std::string framework_dir;    // macOS：CEF framework 路径
  std::string resources_dir;
  std::string locales_dir;
  int log_severity = 2;
  int remote_debugging_port = 0;
  bool persist_session_cookies = true;
  // 启用 GPU 合成 + OnAcceleratedPaint 共享纹理零拷贝（Windows D3D11 /
  // macOS IOSurface / Linux DMABUF）。false 时保持软件 OSR（disable-gpu + OnPaint）。
  bool gpu_shared_texture = false;
  std::vector<std::pair<std::string, std::string>> extra_switches;
};

struct BrowserOptions {
  std::string user_agent;
  bool transparent = false;
  bool enable_javascript = true;
  bool persist_cookies = true;
  std::string default_encoding = "UTF-8";
  uint32_t background_color = 0xFFFFFFFFu;  // ARGB
  int windowless_frame_rate = 60;  // OSR 帧率；<=0 由 CreateBrowser 兜底为 60
};

struct CreateResult {
  bool ok = false;
  int browser_id = 0;
  int64_t texture_id = -1;
};

// <input type=file> 触发的文件选择请求（平台无关描述）。由 OSR handler 的
// OnFileDialog 组装后交给平台层用系统原生对话框呈现。
struct FileDialogRequest {
  int mode = 0;  // cef_file_dialog_mode_t & FILE_DIALOG_TYPE_MASK:
                 // 0=open 1=open_multiple 2=open_folder 3=save
  bool multiple = false;
  std::string title;
  std::string default_path;
  // 原样透传 CEF 的 accept_filters：可能是扩展名(".pdf")、MIME("image/*")或
  // 组合("Image|.png;.jpg")。平台层自行映射为各自对话框的过滤器。
  std::vector<std::string> accept_filters;
};

class CefBrowserManager : public CefWebviewHandler::Delegate {
 public:
  static CefBrowserManager& Instance();

  // 在「将要泵消息的那个线程」上调用（通常是 Flutter 平台/UI 线程）。
  bool Initialize(const CefMainArgs& main_args,
                  const CefInitConfig& config,
                  FlutterTextureBridge* texture_bridge,
                  CefEventSink* sink);

  // 拆分：在 runner main() 早期（单线程）调用 InitializeCef 完成 CefInitialize，
  // 之后插件注册/Dart 调用时再 SetBridges 提供纹理与事件桥。
  bool InitializeCef(const CefMainArgs& main_args, const CefInitConfig& config);
  void SetBridges(FlutterTextureBridge* texture_bridge, CefEventSink* sink);

  bool initialized() const { return initialized_; }
  void SetInitialized(bool v) { initialized_ = v; }
  // 当前是否为 GPU 共享纹理（加速）模式。平台插件据此决定用 GpuSurfaceTexture
  // 还是 PixelBufferTexture。
  bool gpu_shared_texture() const { return gpu_shared_texture_; }
  // Linux 走独立 CefInitialize（不经 InitializeCef 读 config），故由 cef_engine_api
  // 在决定 GPU 模式后直接设置：true 时 CreateBrowser 会置 shared_texture_enabled，
  // CEF 改走 OnAcceleratedPaint（DMABUF）而非 OnPaint。
  void SetGpuSharedTexture(bool v) { gpu_shared_texture_ = v; }

  // 仅子进程使用：早于一切的进程分发。返回 >=0 表示是子进程，应立即退出。
  static int ExecuteSubProcess(const CefMainArgs& main_args);

  CreateResult CreateBrowser(const std::string& url,
                             int width,
                             int height,
                             float dpr,
                             const BrowserOptions& options);

  void CloseBrowser(int browser_id);
  void LoadUrl(int browser_id, const std::string& url);
  void Reload(int browser_id);
  void StopLoad(int browser_id);
  void GoBack(int browser_id);
  void GoForward(int browser_id);
  void Resize(int browser_id, int width, int height, float dpr);
  void SetVisible(int browser_id, bool visible);
  void SetFocus(int browser_id, bool focused);
  void EvaluateJavascript(int browser_id, const std::string& source);

  void SendMouseMove(int browser_id, double x, double y, bool leave,
                     int modifiers = 0);
  void SendMouseButton(int browser_id, double x, double y, int button,
                       bool down, int click_count, int modifiers);
  void SendMouseWheel(int browser_id, double x, double y, double dx, double dy,
                      int modifiers = 0);
  void SendKey(int browser_id, int type, int windows_key_code,
               int native_key_code, int modifiers, int character);

  // 拖拽（OS 文件拖入 OSR webview）。x/y 为 DIP 视图坐标（与鼠标同一坐标空间）。
  // OSR 下宿主必须手动驱动这套 DragTarget 时序：enter(数据)→over*→drop / leave。
  // [paths] 为被拖文件的绝对路径，enter 时据此构造 CefDragData（AddFile 按路径，
  // CEF 自行读盘、零字节搬运）；drop 复用 enter 设置的数据。
  void DragTargetDragEnter(int browser_id, double x, double y,
                           const std::vector<std::string>& paths,
                           int modifiers);
  void DragTargetDragOver(int browser_id, double x, double y, int modifiers);
  void DragTargetDragLeave(int browser_id);
  void DragTargetDrop(int browser_id, double x, double y, int modifiers);

  // IME（输入法组字）：OSR 模式下中文/日文等需要这些接口才能预编辑与提交。
  // selection_start/end < 0 表示置于组字串末尾。
  void ImeSetComposition(int browser_id, const std::string& text,
                         int selection_start, int selection_end);
  void ImeCommitText(int browser_id, const std::string& text);
  void ImeFinishComposing(int browser_id, bool keep_selection);
  void ImeCancelComposition(int browser_id);

  // 平台提供「视图原点(0,0) 对应的屏幕坐标(设备像素)」。OSR 的 GetScreenPoint
  // 据此把 DIP 视图坐标换算到屏幕坐标，用于原生弹层 / 输入法窗口定位。
  // 返回 false 表示当前不可用（如未注册 / 无窗口）。
  using ScreenOriginProvider = std::function<bool(int* x, int* y)>;
  void SetScreenOriginProvider(ScreenOriginProvider provider);
  bool GetScreenOrigin(int* x, int* y);

  // 平台层实现「弹出系统原生文件选择框」。OSR + 空父窗口下 CEF 自带对话框不可靠，
  // 故由各端插件注册此 provider，用 NSOpenPanel / IFileOpenDialog / GtkFileChooser
  // 呈现，选择结果经 done 回传（空 vector = 取消）。done 可能在任意线程被调用，
  // 由调用方（handler）负责切回 CEF UI 线程执行 CefFileDialogCallback。
  using FileDialogDoneCallback =
      std::function<void(const std::vector<std::string>& paths)>;
  using FileDialogProvider =
      std::function<void(const FileDialogRequest&, FileDialogDoneCallback)>;
  void SetFileDialogProvider(FileDialogProvider provider);
  // 有 provider 时转发并返回 true（异步，稍后回调 done）；无 provider 返回 false，
  // 由 handler 回退到 CEF 自带对话框。
  bool RequestFileDialog(const FileDialogRequest& request,
                         FileDialogDoneCallback done);

  // 由平台定时器驱动（外部消息泵）。
  void DoMessageLoopWork();

  void Shutdown();

  // CefWebviewHandler::Delegate
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        int64_t texture_id) override;
  void OnBrowserClosed(int browser_id) override;

 private:
  CefBrowserManager() = default;

  struct Entry {
    CefRefPtr<CefWebviewHandler> handler;
    CefRefPtr<CefBrowser> browser;
    int64_t texture_id = -1;
    int logical_w = 1024;
    int logical_h = 768;
    float dpr = 1.0f;
  };

  CefRefPtr<CefBrowser> FindBrowser(int browser_id);
  Entry* FindEntry(int browser_id);

  bool initialized_ = false;
  bool multi_threaded_ = false;  // Linux：CEF 在独立线程跑 UI 循环
  bool gpu_shared_texture_ = false;  // GPU 加速（共享纹理）模式，见 CefInitConfig
  FlutterTextureBridge* texture_bridge_ = nullptr;
  CefEventSink* sink_ = nullptr;

  std::mutex mutex_;
  std::map<int, Entry> browsers_;

  ScreenOriginProvider screen_origin_provider_;
  FileDialogProvider file_dialog_provider_;

  BrowserOptions pending_options_;  // CreateBrowserSync 期间临时存放
};

}  // namespace cef_webview

#endif  // CEF_WEBVIEW_BROWSER_MANAGER_H_
