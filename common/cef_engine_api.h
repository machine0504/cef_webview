// 独立 CEF 引擎的纯 C 接口（被 cef_webview_engine.so 导出，被插件 dlopen 调用）。
//
// 设计目的：让承载 CEF 的 .so 通过 dlopen(RTLD_DEEPBIND) 加载，使其与 Flutter
// engine（同样基于 Chromium）的全局符号/内存分配器隔离，避免 CefInitialize
// 死锁。引擎侧绝不触碰任何 Flutter 符号；所有 Flutter 纹理/通道操作通过下面的
// 回调交还给插件侧执行。
#ifndef CEF_WEBVIEW_ENGINE_API_H_
#define CEF_WEBVIEW_ENGINE_API_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// GPU 零拷贝（DMABUF）一帧的平面信息。对应 CEF 的
// cef_accelerated_paint_native_pixmap_plane_info_t。
typedef struct CefwvDmabufPlane {
  int fd;           // DMABUF 文件描述符（仅在 on_accelerated_frame 回调内有效）
  uint32_t stride;  // 行字节数
  uint32_t offset;  // 平面在 buffer 内的偏移
  uint64_t size;    // 平面字节数
} CefwvDmabufPlane;

// GPU 零拷贝一帧（Linux）。宽高为设备像素；format 为 cef_color_type_t 数值
// （0 = kBGRA_8888）。fd 仅在回调栈内有效，实现方须在回调内 dup() 或立即导入。
typedef struct CefwvAcceleratedFrame {
  int width;
  int height;
  int format;
  int plane_count;
  uint64_t modifier;  // DRM format modifier（DMABUF 布局）
  CefwvDmabufPlane planes[4];
} CefwvAcceleratedFrame;

// 插件提供给引擎的回调集合。引擎在“泵消息的那个线程”（平台线程）上调用它们，
// 因此插件可安全地在回调中操作 Flutter 纹理/方法通道。
typedef struct CefwvCallbacks {
  // 创建一个 width*height（设备像素）的 Flutter 外部纹理，返回 textureId（<0 失败）。
  int64_t (*create_texture)(void* user, int width, int height);
  // 提交一帧 BGRA32 数据（length = width*height*4）。
  void (*on_frame)(void* user, int64_t texture_id, const void* buffer,
                   int width, int height);
  void (*resize_texture)(void* user, int64_t texture_id, int width, int height);
  void (*dispose_texture)(void* user, int64_t texture_id);

  void (*on_loading_state)(void* user, int browser_id, int is_loading,
                           int can_go_back, int can_go_forward, double progress);
  void (*on_address)(void* user, int browser_id, const char* url);
  void (*on_title)(void* user, int browser_id, const char* title);
  void (*on_load_error)(void* user, int browser_id, int error_code,
                        const char* error_text, const char* failed_url);
  void (*on_js_message)(void* user, int browser_id, const char* handler,
                        const char* data_json);
  void (*on_before_popup)(void* user, int browser_id, const char* target_url);
  void (*on_browser_closed)(void* user, int browser_id);
  // IME 组字光标位置（DIP，相对 webview 左上角）。
  void (*on_ime_cursor)(void* user, int browser_id, int x, int y, int width,
                        int height);
  // <input type=file>：引擎请求插件用系统原生文件框（GTK）呈现选择。
  // 在泵消息的平台线程（= GTK 主线程）触发；插件弹框后须（可异步）调用
  // cefwv_engine_file_dialog_result(request_id, paths_json) 回传结果。
  // mode: 0=open 1=open_multiple 2=open_folder 3=save；multiple: 0/1；
  // accept_filters_json: JSON 字符串数组（如 ["\\.pdf","image/*"]）。
  // 追加在结构体末尾以保持 ABI 兼容（旧插件不设置即为 nullptr，引擎按取消处理）。
  void (*on_file_dialog)(void* user, int request_id, int mode, int multiple,
                         const char* title, const char* accept_filters_json);
  // 鼠标指针类型变化（cef_cursor_type_t 整型值）。OSR 下宿主据此把 Flutter 光标
  // 换成对应形状。追加在结构体末尾以保持 ABI 兼容（旧插件不设置即 nullptr，
  // 引擎判空跳过）。
  void (*on_cursor_change)(void* user, int browser_id, int cursor_type);
  // GPU 零拷贝路径：提交一帧 DMABUF 共享纹理（Linux）。在泵消息的平台线程、于
  // CEF OnAcceleratedPaint 回调栈内同步触发；frame->planes[i].fd 仅在本回调返回
  // 前有效（CEF 随后回收/复用底层 buffer），插件须在回调内 dup(fd) 保活或立即
  // 导入为 EGLImage。追加在结构体末尾以保持 ABI 兼容（旧插件为 nullptr → 引擎
  // 判空跳过，此时应保持软件模式走 on_frame）。
  void (*on_accelerated_frame)(void* user, int64_t texture_id,
                               const CefwvAcceleratedFrame* frame);
  // 软件 OSR 增量帧：同 on_frame，但附带脏矩形（设备像素，自上而下）。插件据此
  // 只转色/上传变化区域，省掉每帧全画幅 CPU 开销。追加在末尾保持 ABI 兼容
  // （旧插件为 nullptr → 引擎回落 on_frame 全帧）。
  void (*on_frame_rect)(void* user, int64_t texture_id, const void* buffer,
                        int width, int height, int dirty_x, int dirty_y,
                        int dirty_w, int dirty_h);
} CefwvCallbacks;

// 强制导出（即便 CEF 的 cmake 全局设了 -fvisibility=hidden）。
#pragma GCC visibility push(default)

// 一次性初始化 CEF（应在进程仍为单线程时调用）。返回 1 成功 / 0 失败。
int cefwv_engine_initialize(const CefwvCallbacks* callbacks, void* user,
                            const char* cache_path, const char* locale,
                            const char* user_agent_suffix,
                            const char* subprocess_path,
                            const char* resources_dir, const char* locales_dir,
                            int log_severity, int remote_debugging_port);

int cefwv_engine_is_initialized(void);
void cefwv_engine_shutdown(void);
void cefwv_engine_pump(void);  // 由插件定时器驱动

// 引擎最终决定的渲染模式：1=GPU 共享纹理(DMABUF, OnAcceleratedPaint)，
// 0=软件(OnPaint)。插件在 initialize 后调用，据此选择 FlTextureGL 还是
// FlPixelBufferTexture。由环境变量 CEFWV_GPU（1/0/auto，默认 auto=探测）决定。
int cefwv_engine_gpu_enabled(void);

// 创建 OSR 浏览器。成功返回 1 并写出 browser_id / texture_id。
// frame_rate：OSR 帧率（fps），<=0 由引擎侧兜底为 60。
int cefwv_engine_create_browser(const char* url, int width, int height,
                                float dpr, int transparent, int enable_js,
                                unsigned int background_color, int frame_rate,
                                int* out_browser_id, int64_t* out_texture_id);

void cefwv_engine_close_browser(int browser_id);
void cefwv_engine_load_url(int browser_id, const char* url);
void cefwv_engine_reload(int browser_id);
void cefwv_engine_stop_load(int browser_id);
void cefwv_engine_go_back(int browser_id);
void cefwv_engine_go_forward(int browser_id);
void cefwv_engine_resize(int browser_id, int width, int height, float dpr);
void cefwv_engine_set_visible(int browser_id, int visible);
void cefwv_engine_set_focus(int browser_id, int focused);
void cefwv_engine_eval_js(int browser_id, const char* source);

void cefwv_engine_mouse_move(int browser_id, double x, double y, int leave);
void cefwv_engine_mouse_button(int browser_id, double x, double y, int button,
                               int down, int click_count, int modifiers);
void cefwv_engine_mouse_wheel(int browser_id, double x, double y, double dx,
                              double dy);
void cefwv_engine_key(int browser_id, int type, int windows_key_code,
                      int native_key_code, int modifiers, int character);

// 拖拽（OS 文件拖入 OSR webview）。x/y 为 DIP 视图坐标（同鼠标）。
// paths_json 为被拖文件绝对路径的 JSON 字符串数组（与 file_dialog 同格式），
// drag_enter 用它构造 CefDragData；drag_drop 复用 enter 设置的数据。
void cefwv_engine_drag_enter(int browser_id, double x, double y, int modifiers,
                             const char* paths_json);
void cefwv_engine_drag_over(int browser_id, double x, double y, int modifiers);
void cefwv_engine_drag_leave(int browser_id);
void cefwv_engine_drag_drop(int browser_id, double x, double y, int modifiers);

// IME（输入法组字）。set_composition 传当前预编辑串；commit 提交最终文本；
// finish 结束组字；cancel 取消。selection_start/end < 0 表示置于串末尾。
void cefwv_engine_ime_set_composition(int browser_id, const char* text,
                                      int selection_start, int selection_end);
void cefwv_engine_ime_commit(int browser_id, const char* text);
void cefwv_engine_ime_finish(int browser_id, int keep_selection);
void cefwv_engine_ime_cancel(int browser_id);

// 插件在系统原生文件框选择完成后回传结果给引擎（对应 on_file_dialog 的
// request_id）。paths_json 为 JSON 字符串数组；空数组 / 空串 / nullptr = 取消。
void cefwv_engine_file_dialog_result(int request_id, const char* paths_json);

#pragma GCC visibility pop

#ifdef __cplusplus
}
#endif

#endif  // CEF_WEBVIEW_ENGINE_API_H_
