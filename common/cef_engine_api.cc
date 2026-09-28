#include "cef_engine_api.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <strings.h>
#include <unistd.h>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_parser.h"
#include "include/cef_values.h"
#include "cef_browser_manager.h"
#include "cef_webview/cef_event_sink.h"
#include "cef_webview/flutter_texture_bridge.h"

namespace {

CefwvCallbacks g_cb = {};
void* g_user = nullptr;

// 引擎最终决定的渲染模式：true=GPU 共享纹理(DMABUF)，false=软件(OnPaint)。
// 在 cefwv_engine_initialize 最早期决定，供 BuildMainArgs / CreateBrowser /
// cefwv_engine_gpu_enabled 共用。
bool g_gpu_enabled = false;

// 探测目标机是否具备 GPU 零拷贝(DMABUF)能力：无副作用启发式——
//   1) 有 X11/Wayland 显示；2) 存在可用的 DRM render 节点(/dev/dri/renderD*)。
// 满足即认为可走 GPU 合成 + native pixmap 导出。不初始化 EGL，避免干扰 CEF/ANGLE。
bool ProbeGpuCapable() {
  const char* disp = getenv("DISPLAY");
  const char* wl = getenv("WAYLAND_DISPLAY");
  if ((!disp || !*disp) && (!wl || !*wl)) return false;
  for (int i = 128; i < 136; ++i) {
    char path[64];
    snprintf(path, sizeof(path), "/dev/dri/renderD%d", i);
    if (access(path, R_OK | W_OK) == 0) return true;
  }
  if (access("/dev/dri/card0", R_OK) == 0) return true;
  return false;
}

// 依据环境变量 CEFWV_GPU 决定渲染模式：1/true/on=强制 GPU，0/false/off=强制软件，
// auto=自动探测（ProbeGpuCapable）。**默认（未设置）= 软件 OSR**。
// 原因：GPU 零拷贝(DMABUF)合成在部分国产 GPU/驱动上不稳定（统信实体机某些型号打开
// 网页直接闪退）；软件 OSR 全机型通用、最稳。启动器 launch.sh 也会显式钉 CEFWV_GPU=0。
// 想在特定机型试 GPU：设 CEFWV_GPU=1（强制）或 CEFWV_GPU=auto（探测 /dev/dri）。
bool DecideGpuMode() {
  const char* env = getenv("CEFWV_GPU");
  if (env && *env) {
    if (!strcmp(env, "1") || !strcasecmp(env, "true") || !strcasecmp(env, "on"))
      return true;
    if (!strcmp(env, "0") || !strcasecmp(env, "false") ||
        !strcasecmp(env, "off"))
      return false;
    if (!strcasecmp(env, "auto")) return ProbeGpuCapable();
    // 其余未知值按软件处理（安全默认）
  }
  return false;
}

// <input type=file> 异步回执：request_id -> done 回调。on_file_dialog 把请求抛给
// 插件（GTK）后在此登记，cefwv_engine_file_dialog_result 回来时取出触发。
std::mutex g_fd_mutex;
std::map<int, cef_webview::CefBrowserManager::FileDialogDoneCallback>
    g_fd_pending;
int g_fd_next_id = 0;

std::string SerializeStrings(const std::vector<std::string>& items) {
  CefRefPtr<CefListValue> list = CefListValue::Create();
  for (size_t i = 0; i < items.size(); ++i) list->SetString(i, items[i]);
  CefRefPtr<CefValue> v = CefValue::Create();
  v->SetList(list);
  return CefWriteJSON(v, JSON_WRITER_DEFAULT).ToString();
}

std::vector<std::string> ParseJsonStringArray(const char* json) {
  std::vector<std::string> out;
  if (!json || !*json) return out;
  CefRefPtr<CefValue> v = CefParseJSON(CefString(json), JSON_PARSER_RFC);
  if (v && v->GetType() == VTYPE_LIST) {
    CefRefPtr<CefListValue> list = v->GetList();
    for (size_t i = 0; i < list->GetSize(); ++i)
      out.push_back(list->GetString(i).ToString());
  }
  return out;
}

// 把引擎产出的纹理帧/事件，经 C 回调交还插件侧（持有 Flutter 符号）执行。
class EngineTextureBridge : public cef_webview::FlutterTextureBridge {
 public:
  int64_t CreateTexture(int w, int h) override {
    return g_cb.create_texture ? g_cb.create_texture(g_user, w, h) : -1;
  }
  void OnFrame(int64_t id, const void* buf, int w, int h) override {
    if (g_cb.on_frame) g_cb.on_frame(g_user, id, buf, w, h);
  }
  void OnFrameRect(int64_t id, const void* buf, int w, int h, int dx, int dy,
                   int dw, int dh) override {
    if (g_cb.on_frame_rect)
      g_cb.on_frame_rect(g_user, id, buf, w, h, dx, dy, dw, dh);
    else if (g_cb.on_frame)
      g_cb.on_frame(g_user, id, buf, w, h);  // 旧插件回落全帧
  }
  // GPU 零拷贝路径（Linux DMABUF）：把 handler 填好的 planes 打包成 C 结构，
  // 同步交还插件侧（持有 Flutter/EGL 符号）导入为 EGLImage → GL 纹理。fd 仅在
  // 本调用栈内有效，插件须在回调内 dup()/导入。
  void OnAcceleratedFrame(
      int64_t id, const cef_webview::AcceleratedFrameInfo& info) override {
    if (!g_cb.on_accelerated_frame) return;
    CefwvAcceleratedFrame f;
    memset(&f, 0, sizeof(f));
    f.width = info.width;
    f.height = info.height;
    f.format = info.format;
    f.plane_count = info.plane_count;
    f.modifier = info.modifier;
    for (int i = 0; i < info.plane_count && i < 4; ++i) {
      f.planes[i].fd = info.planes[i].fd;
      f.planes[i].stride = info.planes[i].stride;
      f.planes[i].offset = info.planes[i].offset;
      f.planes[i].size = info.planes[i].size;
    }
    g_cb.on_accelerated_frame(g_user, id, &f);
  }
  void ResizeTexture(int64_t id, int w, int h) override {
    if (g_cb.resize_texture) g_cb.resize_texture(g_user, id, w, h);
  }
  void DisposeTexture(int64_t id) override {
    if (g_cb.dispose_texture) g_cb.dispose_texture(g_user, id);
  }
};

class EngineEventSink : public cef_webview::CefEventSink {
 public:
  void OnLoadingStateChange(int id, bool l, bool b, bool f, double p) override {
    if (g_cb.on_loading_state)
      g_cb.on_loading_state(g_user, id, l ? 1 : 0, b ? 1 : 0, f ? 1 : 0, p);
  }
  void OnAddressChange(int id, const std::string& url) override {
    if (g_cb.on_address) g_cb.on_address(g_user, id, url.c_str());
  }
  void OnTitleChange(int id, const std::string& t) override {
    if (g_cb.on_title) g_cb.on_title(g_user, id, t.c_str());
  }
  void OnLoadError(int id, int c, const std::string& t,
                   const std::string& u) override {
    if (g_cb.on_load_error)
      g_cb.on_load_error(g_user, id, c, t.c_str(), u.c_str());
  }
  void OnJsMessage(int id, const std::string& h,
                   const std::string& d) override {
    if (g_cb.on_js_message)
      g_cb.on_js_message(g_user, id, h.c_str(), d.c_str());
  }
  void OnBeforePopup(int id, const std::string& u) override {
    if (g_cb.on_before_popup) g_cb.on_before_popup(g_user, id, u.c_str());
  }
  void OnGlobalError(const std::string&) override {}
  void OnImeCursorRect(int id, int x, int y, int w, int h) override {
    if (g_cb.on_ime_cursor) g_cb.on_ime_cursor(g_user, id, x, y, w, h);
  }
  void OnCursorChange(int id, int cursor_type) override {
    if (g_cb.on_cursor_change) g_cb.on_cursor_change(g_user, id, cursor_type);
  }
};

EngineTextureBridge g_texture_bridge;
EngineEventSink g_event_sink;

void BuildMainArgs(int* argc, char*** argv) {
  static std::vector<std::string> storage;
  static std::vector<char*> args;
  if (args.empty()) {
    FILE* f = fopen("/proc/self/cmdline", "rb");
    if (f) {
      std::string buf;
      int c;
      while ((c = fgetc(f)) != EOF) {
        if (c == '\0') {
          storage.push_back(buf);
          buf.clear();
        } else {
          buf.push_back(static_cast<char>(c));
        }
      }
      if (!buf.empty()) storage.push_back(buf);
      fclose(f);
    }
    if (storage.empty()) storage.push_back("app");
    // browser 进程用 nullptr CefApp，命令行开关在此注入。
    if (g_gpu_enabled) {
      // GPU 零拷贝 OSR：启用 GPU 合成，让 CEF 走 OnAcceleratedPaint 交付
      // native pixmap(DMABUF)。CEF 144 在 OSR + 共享纹理时需要 ANGLE 的
      // gl-egl 后端与 X11 Ozone 后端（见 CEF issue #3953）。不注入 in-process-gpu，
      // 使用独立 GPU 进程（实体机 GPU 更稳、DMABUF 导出更可靠）。
      storage.push_back("--use-angle=gl-egl");
      storage.push_back("--ozone-platform=x11");
      storage.push_back("--enable-gpu-rasterization");
      storage.push_back("--enable-zero-copy");
      storage.push_back("--enable-begin-frame-scheduling");
    } else {
      // 软件 OSR（兜底，最稳）：禁用 GPU 合成，OnPaint 输出 CPU BGRA 帧；
      // GPU 内置主进程，避免独立 GPU 子进程在虚拟机/无独显环境启动失败。
      storage.push_back("--disable-gpu");
      storage.push_back("--disable-gpu-compositing");
      storage.push_back("--in-process-gpu");
      storage.push_back("--enable-begin-frame-scheduling");
    }
    for (auto& s : storage) args.push_back(const_cast<char*>(s.c_str()));
  }
  *argc = static_cast<int>(args.size());
  *argv = args.data();
}

}  // namespace

extern "C" {

int cefwv_engine_initialize(const CefwvCallbacks* callbacks, void* user,
                            const char* cache_path, const char* locale,
                            const char* user_agent_suffix,
                            const char* subprocess_path,
                            const char* resources_dir, const char* locales_dir,
                            int log_severity, int remote_debugging_port) {
  if (callbacks) g_cb = *callbacks;
  g_user = user;

  // 最早期决定渲染模式（供 BuildMainArgs 使用）。仅当插件提供了
  // on_accelerated_frame 回调时才允许 GPU 路径，否则 GPU 帧无处消费会黑屏。
  g_gpu_enabled = (g_cb.on_accelerated_frame != nullptr) && DecideGpuMode();
  // 子进程(renderer/gpu)通过环境变量继承同一决定，使其 OnBeforeCommandLineProcessing
  // 与浏览器进程一致（不再无脑注入 disable-gpu）。
  setenv("CEFWV_GPU_EFFECTIVE", g_gpu_enabled ? "1" : "0", 1);
  fprintf(stderr, "[CEFWV] render mode = %s\n",
          g_gpu_enabled ? "GPU (DMABUF shared texture)" : "software (OnPaint)");

  auto& mgr = cef_webview::CefBrowserManager::Instance();
  mgr.SetBridges(&g_texture_bridge, &g_event_sink);
  // Linux 走本文件内独立 CefInitialize（不经 CefBrowserManager::InitializeCef 读
  // config），故在此直接把 GPU 模式同步给 manager：CreateBrowser 据此设置
  // window_info.shared_texture_enabled。
  mgr.SetGpuSharedTexture(g_gpu_enabled);

  // 文件选择框：请求转成 on_file_dialog 抛给插件（GTK），登记 done 待回执。
  mgr.SetFileDialogProvider(
      [](const cef_webview::FileDialogRequest& req,
         cef_webview::CefBrowserManager::FileDialogDoneCallback done) {
        if (!g_cb.on_file_dialog) {
          done(std::vector<std::string>());  // 无插件回调：视为取消
          return;
        }
        int id;
        {
          std::lock_guard<std::mutex> lock(g_fd_mutex);
          id = ++g_fd_next_id;
          g_fd_pending[id] = std::move(done);
        }
        const std::string filters_json = SerializeStrings(req.accept_filters);
        g_cb.on_file_dialog(g_user, id, req.mode, req.multiple ? 1 : 0,
                            req.title.c_str(), filters_json.c_str());
      });

  // browser 进程使用 nullptr CefApp（DEEPBIND 引擎中实例化多重继承的 CefApp 会
  // 在 CefInitialize 崩溃）；JS 桥/渲染由独立 subprocess 的 CefWebviewApp 承载。
  CefSettings settings;
  settings.no_sandbox = true;
  settings.windowless_rendering_enabled = true;
  settings.multi_threaded_message_loop = false;
  settings.external_message_pump = false;
  if (cache_path && *cache_path)
    CefString(&settings.cache_path).FromString(cache_path);
  if (locale && *locale) CefString(&settings.locale).FromString(locale);
  if (subprocess_path && *subprocess_path)
    CefString(&settings.browser_subprocess_path).FromString(subprocess_path);
  if (resources_dir && *resources_dir)
    CefString(&settings.resources_dir_path).FromString(resources_dir);
  if (locales_dir && *locales_dir)
    CefString(&settings.locales_dir_path).FromString(locales_dir);
  if (remote_debugging_port > 0)
    settings.remote_debugging_port = remote_debugging_port;
  (void)user_agent_suffix;
  // CEF 日志落盘到 cache_path/cef_debug.log，便于在目标机（麒麟/统信）排查
  // CefInitialize 失败原因；未显式指定级别时用 INFO。
  settings.log_severity = log_severity > 0
                              ? static_cast<cef_log_severity_t>(log_severity)
                              : LOGSEVERITY_INFO;
  if (cache_path && *cache_path) {
    std::string log_file = std::string(cache_path) + "/cef_debug.log";
    CefString(&settings.log_file).FromString(log_file);
  }

  int argc = 0;
  char** argv = nullptr;
  BuildMainArgs(&argc, &argv);
  CefMainArgs main_args(argc, argv);
  bool ok = CefInitialize(main_args, settings, nullptr, nullptr);
  mgr.SetInitialized(ok);
  return ok ? 1 : 0;
}

int cefwv_engine_is_initialized(void) {
  return cef_webview::CefBrowserManager::Instance().initialized() ? 1 : 0;
}

int cefwv_engine_gpu_enabled(void) { return g_gpu_enabled ? 1 : 0; }

void cefwv_engine_shutdown(void) {
  {
    std::lock_guard<std::mutex> lock(g_fd_mutex);
    g_fd_pending.clear();  // 丢弃未完成的文件框回执，避免悬挂
  }
  cef_webview::CefBrowserManager::Instance().Shutdown();
}

void cefwv_engine_pump(void) {
  cef_webview::CefBrowserManager::Instance().DoMessageLoopWork();
}

int cefwv_engine_create_browser(const char* url, int width, int height,
                                float dpr, int transparent, int enable_js,
                                unsigned int background_color, int frame_rate,
                                int* out_browser_id, int64_t* out_texture_id) {
  cef_webview::BrowserOptions opts;
  opts.transparent = transparent != 0;
  opts.enable_javascript = enable_js != 0;
  opts.background_color = background_color;
  opts.windowless_frame_rate = frame_rate;
  cef_webview::CreateResult r =
      cef_webview::CefBrowserManager::Instance().CreateBrowser(
          url ? url : "", width, height, dpr, opts);
  if (!r.ok) return 0;
  if (out_browser_id) *out_browser_id = r.browser_id;
  if (out_texture_id) *out_texture_id = r.texture_id;
  return 1;
}

void cefwv_engine_close_browser(int id) {
  cef_webview::CefBrowserManager::Instance().CloseBrowser(id);
}
void cefwv_engine_load_url(int id, const char* url) {
  cef_webview::CefBrowserManager::Instance().LoadUrl(id, url ? url : "");
}
void cefwv_engine_reload(int id) {
  cef_webview::CefBrowserManager::Instance().Reload(id);
}
void cefwv_engine_stop_load(int id) {
  cef_webview::CefBrowserManager::Instance().StopLoad(id);
}
void cefwv_engine_go_back(int id) {
  cef_webview::CefBrowserManager::Instance().GoBack(id);
}
void cefwv_engine_go_forward(int id) {
  cef_webview::CefBrowserManager::Instance().GoForward(id);
}
void cefwv_engine_resize(int id, int w, int h, float dpr) {
  cef_webview::CefBrowserManager::Instance().Resize(id, w, h, dpr);
}
void cefwv_engine_set_visible(int id, int v) {
  cef_webview::CefBrowserManager::Instance().SetVisible(id, v != 0);
}
void cefwv_engine_set_focus(int id, int f) {
  cef_webview::CefBrowserManager::Instance().SetFocus(id, f != 0);
}
void cefwv_engine_eval_js(int id, const char* src) {
  cef_webview::CefBrowserManager::Instance().EvaluateJavascript(
      id, src ? src : "");
}
void cefwv_engine_mouse_move(int id, double x, double y, int leave) {
  cef_webview::CefBrowserManager::Instance().SendMouseMove(id, x, y, leave != 0);
}
void cefwv_engine_mouse_button(int id, double x, double y, int button, int down,
                               int clicks, int mods) {
  cef_webview::CefBrowserManager::Instance().SendMouseButton(
      id, x, y, button, down != 0, clicks, mods);
}
void cefwv_engine_mouse_wheel(int id, double x, double y, double dx,
                              double dy) {
  cef_webview::CefBrowserManager::Instance().SendMouseWheel(id, x, y, dx, dy);
}
void cefwv_engine_key(int id, int type, int wkc, int nkc, int mods, int ch) {
  cef_webview::CefBrowserManager::Instance().SendKey(id, type, wkc, nkc, mods,
                                                     ch);
}
void cefwv_engine_drag_enter(int id, double x, double y, int mods,
                             const char* paths_json) {
  cef_webview::CefBrowserManager::Instance().DragTargetDragEnter(
      id, x, y, ParseJsonStringArray(paths_json), mods);
}
void cefwv_engine_drag_over(int id, double x, double y, int mods) {
  cef_webview::CefBrowserManager::Instance().DragTargetDragOver(id, x, y, mods);
}
void cefwv_engine_drag_leave(int id) {
  cef_webview::CefBrowserManager::Instance().DragTargetDragLeave(id);
}
void cefwv_engine_drag_drop(int id, double x, double y, int mods) {
  cef_webview::CefBrowserManager::Instance().DragTargetDrop(id, x, y, mods);
}
void cefwv_engine_ime_set_composition(int id, const char* text, int sel_start,
                                      int sel_end) {
  cef_webview::CefBrowserManager::Instance().ImeSetComposition(
      id, text ? text : "", sel_start, sel_end);
}
void cefwv_engine_ime_commit(int id, const char* text) {
  cef_webview::CefBrowserManager::Instance().ImeCommitText(id,
                                                           text ? text : "");
}
void cefwv_engine_ime_finish(int id, int keep_selection) {
  cef_webview::CefBrowserManager::Instance().ImeFinishComposing(
      id, keep_selection != 0);
}
void cefwv_engine_ime_cancel(int id) {
  cef_webview::CefBrowserManager::Instance().ImeCancelComposition(id);
}

void cefwv_engine_file_dialog_result(int request_id, const char* paths_json) {
  cef_webview::CefBrowserManager::FileDialogDoneCallback done;
  {
    std::lock_guard<std::mutex> lock(g_fd_mutex);
    auto it = g_fd_pending.find(request_id);
    if (it == g_fd_pending.end()) return;
    done = std::move(it->second);
    g_fd_pending.erase(it);
  }
  done(ParseJsonStringArray(paths_json));
}

}  // extern "C"
