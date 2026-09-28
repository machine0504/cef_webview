#include "include/cef_webview/cef_webview_plugin.h"

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "common/cef_engine_api.h"

// G_DECLARE_FINAL_TYPE 会生成未使用的 static 辅助函数；关闭对应告警。
#pragma GCC diagnostic ignored "-Wunused-function"

// ===========================================================================
// FlPixelBufferTexture 子类：承载一帧 RGBA 像素（插件侧，持有 Flutter 符号）
// ===========================================================================

G_DECLARE_FINAL_TYPE(CefFlTexture, cef_fl_texture, CEF, FL_TEXTURE,
                     FlPixelBufferTexture)

struct _CefFlTexture {
  FlPixelBufferTexture parent_instance;
  std::mutex* mutex;
  std::vector<uint8_t>* pending;
  std::vector<uint8_t>* stable;
  uint32_t pending_w, pending_h;
  uint32_t width, height;
  bool has_frame;
};

G_DEFINE_TYPE(CefFlTexture, cef_fl_texture, fl_pixel_buffer_texture_get_type())

static gboolean cef_fl_texture_copy_pixels(FlPixelBufferTexture* texture,
                                           const uint8_t** out_buffer,
                                           uint32_t* width, uint32_t* height,
                                           GError** error) {
  CefFlTexture* self = CEF_FL_TEXTURE(texture);
  if (!self->mutex || !self->stable) return FALSE;
  std::lock_guard<std::mutex> lock(*self->mutex);
  if (self->has_frame) {
    std::swap(*self->pending, *self->stable);
    self->width = self->pending_w;
    self->height = self->pending_h;
    self->has_frame = false;
  }
  if (self->stable->empty()) return FALSE;
  *out_buffer = self->stable->data();
  *width = self->width;
  *height = self->height;
  return TRUE;
}

static void cef_fl_texture_init(CefFlTexture* self) {
  self->mutex = new std::mutex();
  self->pending = new std::vector<uint8_t>();
  self->stable = new std::vector<uint8_t>();
  self->pending_w = self->pending_h = 0;
  self->width = self->height = 0;
  self->has_frame = false;
}

static void cef_fl_texture_finalize(GObject* object) {
  CefFlTexture* self = CEF_FL_TEXTURE(object);
  delete self->mutex;
  delete self->pending;
  delete self->stable;
  G_OBJECT_CLASS(cef_fl_texture_parent_class)->finalize(object);
}

static void cef_fl_texture_class_init(CefFlTextureClass* klass) {
  G_OBJECT_CLASS(klass)->finalize = cef_fl_texture_finalize;
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = cef_fl_texture_copy_pixels;
}

// ===========================================================================
// FlTextureGL 子类：GPU 零拷贝路径（CEF OnAcceleratedPaint → DMABUF → EGLImage）
//
// 数据流：CEF UI(平台)线程在 on_accelerated_frame 里把 DMABUF fd dup() 存入 pending；
// Flutter raster 线程调用 populate() 时（Flutter 的 EGL 上下文已 current）把 pending
// 的 dmabuf 通过 eglCreateImageKHR(EGL_LINUX_DMA_BUF_EXT) 导入为 EGLImage，绑定到
// 一个持久 GL 纹理并交还 Flutter 直接采样——全程 GPU、零 CPU 拷贝。
// ===========================================================================

// ---- EGL/GLES 扩展函数（运行时解析，避免头文件/链接依赖）----
namespace {
using EglDisplayT = void*;
using EglImageT = void*;
typedef EglDisplayT (*PFN_eglGetCurrentDisplay)(void);
typedef void* (*PFN_eglGetProcAddress)(const char*);
// 注意：eglCreateImageKHR 的 attrib_list 是 EGLint(32 位)，故 64 位 modifier 必须
// 拆成 LO/HI 两个 32 位分量传入（与 EGL_EXT_image_dma_buf_import_modifiers 一致）。
typedef EglImageT (*PFN_eglCreateImageKHR)(EglDisplayT, void*, unsigned int,
                                           void*, const int32_t*);
typedef unsigned int (*PFN_eglDestroyImageKHR)(EglDisplayT, EglImageT);
typedef void (*PFN_glEGLImageTargetTexture2DOES)(unsigned int, void*);
typedef void (*PFN_glGenTextures)(int, unsigned int*);
typedef void (*PFN_glBindTexture)(unsigned int, unsigned int);
typedef void (*PFN_glDeleteTextures)(int, const unsigned int*);
typedef void (*PFN_glTexParameteri)(unsigned int, unsigned int, int);
typedef void (*PFN_glTexImage2D)(unsigned int, int, int, int, int, int,
                                 unsigned int, unsigned int, const void*);
typedef void (*PFN_glTexSubImage2D)(unsigned int, int, int, int, int, int,
                                    unsigned int, unsigned int, const void*);
typedef void (*PFN_glPixelStorei)(unsigned int, int);
typedef const unsigned char* (*PFN_glGetString)(unsigned int);

PFN_eglGetCurrentDisplay p_eglGetCurrentDisplay = nullptr;
PFN_eglCreateImageKHR p_eglCreateImageKHR = nullptr;
PFN_eglDestroyImageKHR p_eglDestroyImageKHR = nullptr;
PFN_glEGLImageTargetTexture2DOES p_glEGLImageTargetTexture2DOES = nullptr;
PFN_glGenTextures p_glGenTextures = nullptr;
PFN_glBindTexture p_glBindTexture = nullptr;
PFN_glDeleteTextures p_glDeleteTextures = nullptr;
PFN_glTexParameteri p_glTexParameteri = nullptr;
PFN_glTexImage2D p_glTexImage2D = nullptr;
PFN_glTexSubImage2D p_glTexSubImage2D = nullptr;
PFN_glPixelStorei p_glPixelStorei = nullptr;
PFN_glGetString p_glGetString = nullptr;
bool g_gl_fns_ok = false;     // DMABUF 导入路径（GPU 零拷贝）就绪
bool g_gl_upload_ok = false;  // 软件上传路径（glTexImage2D/SubImage）就绪
// 软件路径能力（在首个 populate 里查询，需 GL 上下文 current）：
bool g_gl_caps_probed = false;
bool g_gl_bgra = false;            // GL_EXT_texture_format_BGRA8888（免 CPU 转色）
bool g_gl_unpack_subimage = false; // GL_EXT_unpack_subimage（脏矩形增量上传）

// EGL/GL 常量（数值稳定，直接内联，避免包含系统 EGL/GL 头造成的类型冲突）。
constexpr unsigned int kGL_TEXTURE_2D = 0x0DE1;
constexpr unsigned int kGL_TEXTURE_MIN_FILTER = 0x2801;
constexpr unsigned int kGL_TEXTURE_MAG_FILTER = 0x2800;
constexpr unsigned int kGL_TEXTURE_WRAP_S = 0x2802;
constexpr unsigned int kGL_TEXTURE_WRAP_T = 0x2803;
constexpr int kGL_LINEAR = 0x2601;
constexpr int kGL_CLAMP_TO_EDGE = 0x812F;
constexpr unsigned int kEGL_LINUX_DMA_BUF_EXT = 0x3270;
constexpr int32_t kEGL_WIDTH = 0x3057;
constexpr int32_t kEGL_HEIGHT = 0x3056;
constexpr int32_t kEGL_LINUX_DRM_FOURCC_EXT = 0x3271;
constexpr int32_t kEGL_DMA_BUF_PLANE0_FD_EXT = 0x3272;
constexpr int32_t kEGL_DMA_BUF_PLANE0_OFFSET_EXT = 0x3273;
constexpr int32_t kEGL_DMA_BUF_PLANE0_PITCH_EXT = 0x3274;
constexpr int32_t kEGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT = 0x3443;
constexpr int32_t kEGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT = 0x3444;
constexpr int32_t kEGL_NONE = 0x3038;
constexpr unsigned int kGL_RGBA = 0x1908;
constexpr unsigned int kGL_BGRA_EXT = 0x80E1;
constexpr unsigned int kGL_UNSIGNED_BYTE = 0x1401;
constexpr unsigned int kGL_UNPACK_ROW_LENGTH_EXT = 0x0CF2;
constexpr unsigned int kGL_EXTENSIONS = 0x1F03;
// DRM fourcc：CEF OSR 共享纹理通常为 BGRA8888（cef_color_type 默认），对应小端
// DRM_FORMAT_ARGB8888。若实测红蓝互换，改用 ABGR8888（0x34324241）。
constexpr uint32_t kDRM_FORMAT_ARGB8888 = 0x34325241;  // 'AR24'
constexpr uint32_t kDRM_FORMAT_ABGR8888 = 0x34324241;  // 'AB24'
constexpr uint64_t kDRM_FORMAT_MOD_INVALID = 0x00ffffffffffffffULL;

// 加载 EGL/GLES 符号并探测能力（只在 populate 里调用，GL 上下文已 current）。
// 返回值 = DMABUF 导入路径是否就绪；软件上传路径就绪见 g_gl_upload_ok。
bool EnsureGlFns() {
  static bool loaded = false;
  if (loaded) return g_gl_fns_ok;
  loaded = true;
  void* egl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
  if (!egl) egl = dlopen("libEGL.so", RTLD_NOW | RTLD_GLOBAL);
  if (!egl) return false;
  auto getproc = reinterpret_cast<PFN_eglGetProcAddress>(
      dlsym(egl, "eglGetProcAddress"));
  p_eglGetCurrentDisplay = reinterpret_cast<PFN_eglGetCurrentDisplay>(
      dlsym(egl, "eglGetCurrentDisplay"));
  if (!getproc) return false;
  p_eglCreateImageKHR =
      reinterpret_cast<PFN_eglCreateImageKHR>(getproc("eglCreateImageKHR"));
  p_eglDestroyImageKHR =
      reinterpret_cast<PFN_eglDestroyImageKHR>(getproc("eglDestroyImageKHR"));
  p_glEGLImageTargetTexture2DOES =
      reinterpret_cast<PFN_glEGLImageTargetTexture2DOES>(
          getproc("glEGLImageTargetTexture2DOES"));
  // 核心 GLES2 符号：优先从 libGLESv2 取（eglGetProcAddress 在 EGL<1.5 不保证返回核心函数）。
  void* gles = dlopen("libGLESv2.so.2", RTLD_NOW | RTLD_GLOBAL);
  if (!gles) gles = dlopen("libGLESv2.so", RTLD_NOW | RTLD_GLOBAL);
  auto sym = [&](const char* n) -> void* {
    void* p = gles ? dlsym(gles, n) : nullptr;
    if (!p && getproc) p = getproc(n);
    return p;
  };
  p_glGenTextures = reinterpret_cast<PFN_glGenTextures>(sym("glGenTextures"));
  p_glBindTexture = reinterpret_cast<PFN_glBindTexture>(sym("glBindTexture"));
  p_glDeleteTextures =
      reinterpret_cast<PFN_glDeleteTextures>(sym("glDeleteTextures"));
  p_glTexParameteri =
      reinterpret_cast<PFN_glTexParameteri>(sym("glTexParameteri"));
  p_glTexImage2D = reinterpret_cast<PFN_glTexImage2D>(sym("glTexImage2D"));
  p_glTexSubImage2D =
      reinterpret_cast<PFN_glTexSubImage2D>(sym("glTexSubImage2D"));
  p_glPixelStorei = reinterpret_cast<PFN_glPixelStorei>(sym("glPixelStorei"));
  p_glGetString = reinterpret_cast<PFN_glGetString>(sym("glGetString"));

  // 能力探测（GL 上下文已 current）：BGRA 直传（免 CPU 转色）与脏矩形增量上传。
  if (!g_gl_caps_probed && p_glGetString) {
    g_gl_caps_probed = true;
    const unsigned char* ext = p_glGetString(kGL_EXTENSIONS);
    const char* s = reinterpret_cast<const char*>(ext);
    if (s) {
      g_gl_bgra = strstr(s, "GL_EXT_texture_format_BGRA8888") != nullptr ||
                  strstr(s, "GL_APPLE_texture_format_BGRA8888") != nullptr ||
                  strstr(s, "GL_EXT_bgra") != nullptr;
      g_gl_unpack_subimage =
          strstr(s, "GL_EXT_unpack_subimage") != nullptr;
    }
  }

  g_gl_fns_ok = p_eglCreateImageKHR && p_eglDestroyImageKHR &&
                p_glEGLImageTargetTexture2DOES && p_glGenTextures &&
                p_glBindTexture && p_glTexParameteri;
  g_gl_upload_ok = p_glGenTextures && p_glBindTexture && p_glTexParameteri &&
                   p_glTexImage2D && p_glTexSubImage2D && p_glPixelStorei;
  return g_gl_fns_ok;
}

void ClosePlanes(CefwvAcceleratedFrame* f) {
  for (int i = 0; i < f->plane_count && i < 4; ++i) {
    if (f->planes[i].fd >= 0) {
      close(f->planes[i].fd);
      f->planes[i].fd = -1;
    }
  }
  f->plane_count = 0;
}
}  // namespace

G_DECLARE_FINAL_TYPE(CefFlTextureGl, cef_fl_texture_gl, CEF, FL_TEXTURE_GL,
                     FlTextureGL)

struct _CefFlTextureGl {
  FlTextureGL parent_instance;
  std::mutex* mutex;
  CefwvAcceleratedFrame* pending;  // 待消费帧（fd 已 dup，本对象拥有）
  bool has_pending;
  unsigned int gl_tex;   // 交还 Flutter 的持久纹理名（raster 线程创建）
  void* cur_image;       // 当前绑定到 gl_tex 的 EGLImage
  void* prev_image;      // 上一帧 EGLImage，延迟一帧销毁（避免 Flutter 仍在采样）
  uint32_t width, height;
};

G_DEFINE_TYPE(CefFlTextureGl, cef_fl_texture_gl, fl_texture_gl_get_type())

// Flutter raster 线程调用（Flutter 的 EGL 上下文已 current）：把 pending 的 DMABUF
// 导入为 EGLImage，绑定到持久 GL 纹理并返回。返回 FALSE 表示本次无更新。
static gboolean cef_fl_texture_gl_populate(FlTextureGL* texture,
                                           uint32_t* target, uint32_t* name,
                                           uint32_t* width, uint32_t* height,
                                           GError** error) {
  CefFlTextureGl* self = CEF_FL_TEXTURE_GL(texture);
  if (!self->mutex) return FALSE;
  CefwvAcceleratedFrame frame;
  bool have_new = false;
  {
    std::lock_guard<std::mutex> lock(*self->mutex);
    if (self->has_pending) {
      frame = *self->pending;      // 接管 fd 所有权
      self->pending->plane_count = 0;  // 防止 finalize/替换时重复 close
      self->has_pending = false;
      have_new = true;
    }
  }

  if (!have_new) {
    // 无新帧：复用已有纹理（Flutter 重绘会反复 populate）。
    if (self->gl_tex) {
      *target = kGL_TEXTURE_2D;
      *name = self->gl_tex;
      *width = self->width;
      *height = self->height;
      return TRUE;
    }
    return FALSE;
  }

  if (!EnsureGlFns() || frame.plane_count < 1) {
    ClosePlanes(&frame);
    return self->gl_tex ? (*target = kGL_TEXTURE_2D, *name = self->gl_tex,
                           *width = self->width, *height = self->height, TRUE)
                        : FALSE;
  }

  EglDisplayT dpy = p_eglGetCurrentDisplay();
  const uint32_t fourcc =
      (frame.format == 1) ? kDRM_FORMAT_ABGR8888 : kDRM_FORMAT_ARGB8888;
  const bool has_mod = frame.modifier != 0 &&
                       frame.modifier != kDRM_FORMAT_MOD_INVALID;

  auto make_image = [&](bool with_modifier) -> void* {
    int32_t attribs[40];
    int n = 0;
    attribs[n++] = kEGL_WIDTH;                 attribs[n++] = frame.width;
    attribs[n++] = kEGL_HEIGHT;                attribs[n++] = frame.height;
    attribs[n++] = kEGL_LINUX_DRM_FOURCC_EXT;  attribs[n++] = (int32_t)fourcc;
    attribs[n++] = kEGL_DMA_BUF_PLANE0_FD_EXT;     attribs[n++] = frame.planes[0].fd;
    attribs[n++] = kEGL_DMA_BUF_PLANE0_OFFSET_EXT; attribs[n++] = (int32_t)frame.planes[0].offset;
    attribs[n++] = kEGL_DMA_BUF_PLANE0_PITCH_EXT;  attribs[n++] = (int32_t)frame.planes[0].stride;
    if (with_modifier) {
      attribs[n++] = kEGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT;
      attribs[n++] = (int32_t)(uint32_t)(frame.modifier & 0xffffffffu);
      attribs[n++] = kEGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT;
      attribs[n++] = (int32_t)(uint32_t)(frame.modifier >> 32);
    }
    attribs[n++] = kEGL_NONE;
    return p_eglCreateImageKHR(dpy, /*EGL_NO_CONTEXT=*/nullptr,
                               kEGL_LINUX_DMA_BUF_EXT, nullptr, attribs);
  };

  void* img = make_image(has_mod);
  if (!img && has_mod) img = make_image(false);  // 部分驱动不支持 modifier，退化重试
  ClosePlanes(&frame);  // EGLImage 已持有 buffer 引用，dup 的 fd 可关闭

  if (!img) {
    g_warning("[cef_webview] eglCreateImageKHR(DMABUF) 失败");
    return self->gl_tex ? (*target = kGL_TEXTURE_2D, *name = self->gl_tex,
                           *width = self->width, *height = self->height, TRUE)
                        : FALSE;
  }

  if (!self->gl_tex) {
    p_glGenTextures(1, &self->gl_tex);
    p_glBindTexture(kGL_TEXTURE_2D, self->gl_tex);
    p_glTexParameteri(kGL_TEXTURE_2D, kGL_TEXTURE_MIN_FILTER, kGL_LINEAR);
    p_glTexParameteri(kGL_TEXTURE_2D, kGL_TEXTURE_MAG_FILTER, kGL_LINEAR);
    p_glTexParameteri(kGL_TEXTURE_2D, kGL_TEXTURE_WRAP_S, kGL_CLAMP_TO_EDGE);
    p_glTexParameteri(kGL_TEXTURE_2D, kGL_TEXTURE_WRAP_T, kGL_CLAMP_TO_EDGE);
  } else {
    p_glBindTexture(kGL_TEXTURE_2D, self->gl_tex);
  }
  p_glEGLImageTargetTexture2DOES(kGL_TEXTURE_2D, img);

  // 延迟一帧销毁上上帧的 image（此刻 Flutter 已呈现完上一帧）。
  if (self->prev_image && p_eglDestroyImageKHR)
    p_eglDestroyImageKHR(dpy, self->prev_image);
  self->prev_image = self->cur_image;
  self->cur_image = img;
  self->width = frame.width;
  self->height = frame.height;

  *target = kGL_TEXTURE_2D;
  *name = self->gl_tex;
  *width = self->width;
  *height = self->height;
  return TRUE;
}

static void cef_fl_texture_gl_init(CefFlTextureGl* self) {
  self->mutex = new std::mutex();
  self->pending = new CefwvAcceleratedFrame();
  memset(self->pending, 0, sizeof(*self->pending));
  self->has_pending = false;
  self->gl_tex = 0;
  self->cur_image = nullptr;
  self->prev_image = nullptr;
  self->width = self->height = 0;
}

static void cef_fl_texture_gl_finalize(GObject* object) {
  CefFlTextureGl* self = CEF_FL_TEXTURE_GL(object);
  if (self->pending) {
    ClosePlanes(self->pending);
    delete self->pending;
  }
  // 注：EGLImage/纹理属于 Flutter raster 线程的 GL 上下文，销毁应在该线程；
  // 此处不主动调用 GL/EGL（finalize 可能不在 raster 线程）。进程退出时随上下文回收。
  delete self->mutex;
  G_OBJECT_CLASS(cef_fl_texture_gl_parent_class)->finalize(object);
}

static void cef_fl_texture_gl_class_init(CefFlTextureGlClass* klass) {
  G_OBJECT_CLASS(klass)->finalize = cef_fl_texture_gl_finalize;
  FL_TEXTURE_GL_CLASS(klass)->populate = cef_fl_texture_gl_populate;
}

// ===========================================================================
// FlTextureGL 子类：软件路径优化（CEF OnPaint 的 CPU BGRA → GL 纹理）
//
// 相比旧的 FlPixelBufferTexture（每帧全画幅 BGRA→RGBA 逐像素转色 + Flutter 再全量
// 上传），这里：① 若驱动支持 GL_EXT_texture_format_BGRA8888 则直接以 BGRA 上传，
// **免掉 CPU 转色**（GPU 采样自动按 BGRA 解释）；② 若支持 GL_EXT_unpack_subimage，
// 则只 glTexSubImage2D 上传脏矩形，**免掉整幅上传**（打字/光标等小改动近乎零成本）。
// 无 BGRA 扩展时退化为一次性 CPU 转色（少见；mesa/多数国产驱动都支持 BGRA）。
// ===========================================================================
G_DECLARE_FINAL_TYPE(CefFlTextureSw, cef_fl_texture_sw, CEF, FL_TEXTURE_SW,
                     FlTextureGL)

struct _CefFlTextureSw {
  FlTextureGL parent_instance;
  std::mutex* mutex;
  std::vector<uint8_t>* buf;   // 全画幅 BGRA staging（持久；CEF 线程写、raster 读）
  std::vector<uint8_t>* rgba;  // 无 BGRA 扩展时的 CPU 转色暂存
  uint32_t w, h;
  bool has_new;
  bool need_full;              // 首帧/尺寸变化 → 整帧上传
  int ax0, ay0, ax1, ay1;      // 累计脏矩形（union）
  unsigned int gl_tex;
  bool alloc;
  uint32_t alloc_w, alloc_h;
};

G_DEFINE_TYPE(CefFlTextureSw, cef_fl_texture_sw, fl_texture_gl_get_type())

static gboolean cef_fl_texture_sw_populate(FlTextureGL* texture,
                                           uint32_t* target, uint32_t* name,
                                           uint32_t* width, uint32_t* height,
                                           GError** error) {
  CefFlTextureSw* self = CEF_FL_TEXTURE_SW(texture);
  if (!self->mutex) return FALSE;
  EnsureGlFns();  // raster 线程，GL 上下文已 current
  std::lock_guard<std::mutex> lock(*self->mutex);
  auto emit_existing = [&]() -> gboolean {
    if (!self->gl_tex) return FALSE;
    *target = kGL_TEXTURE_2D;
    *name = self->gl_tex;
    *width = self->w;
    *height = self->h;
    return TRUE;
  };
  if (!g_gl_upload_ok || self->buf->empty()) return emit_existing();
  if (!self->has_new && self->alloc) return emit_existing();

  const uint32_t w = self->w, h = self->h;
  const uint8_t* src = self->buf->data();
  unsigned int fmt = kGL_BGRA_EXT;
  bool full = self->need_full || !self->alloc || self->alloc_w != w ||
              self->alloc_h != h || !g_gl_unpack_subimage;
  if (!g_gl_bgra) {
    // 无 BGRA 扩展：整帧 CPU 转色到 rgba，再按 RGBA 上传（退化路径，少见）。
    const size_t n = static_cast<size_t>(w) * h;
    self->rgba->resize(n * 4);
    uint8_t* d = self->rgba->data();
    for (size_t i = 0; i < n; ++i) {
      d[i * 4 + 0] = src[i * 4 + 2];
      d[i * 4 + 1] = src[i * 4 + 1];
      d[i * 4 + 2] = src[i * 4 + 0];
      d[i * 4 + 3] = src[i * 4 + 3];
    }
    src = d;
    fmt = kGL_RGBA;
    full = true;
  }

  if (!self->gl_tex) {
    p_glGenTextures(1, &self->gl_tex);
    p_glBindTexture(kGL_TEXTURE_2D, self->gl_tex);
    p_glTexParameteri(kGL_TEXTURE_2D, kGL_TEXTURE_MIN_FILTER, kGL_LINEAR);
    p_glTexParameteri(kGL_TEXTURE_2D, kGL_TEXTURE_MAG_FILTER, kGL_LINEAR);
    p_glTexParameteri(kGL_TEXTURE_2D, kGL_TEXTURE_WRAP_S, kGL_CLAMP_TO_EDGE);
    p_glTexParameteri(kGL_TEXTURE_2D, kGL_TEXTURE_WRAP_T, kGL_CLAMP_TO_EDGE);
  } else {
    p_glBindTexture(kGL_TEXTURE_2D, self->gl_tex);
  }

  if (full) {
    p_glTexImage2D(kGL_TEXTURE_2D, 0, static_cast<int>(fmt), w, h, 0, fmt,
                   kGL_UNSIGNED_BYTE, src);
    self->alloc = true;
    self->alloc_w = w;
    self->alloc_h = h;
  } else {
    int dx = self->ax0, dy = self->ay0;
    int dw = self->ax1 - self->ax0, dh = self->ay1 - self->ay0;
    if (dw > 0 && dh > 0) {
      p_glPixelStorei(kGL_UNPACK_ROW_LENGTH_EXT, static_cast<int>(w));
      const uint8_t* p = src + (static_cast<size_t>(dy) * w + dx) * 4;
      p_glTexSubImage2D(kGL_TEXTURE_2D, 0, dx, dy, dw, dh, fmt,
                        kGL_UNSIGNED_BYTE, p);
      p_glPixelStorei(kGL_UNPACK_ROW_LENGTH_EXT, 0);
    }
  }

  self->has_new = false;
  self->need_full = false;
  self->ax0 = self->ay0 = self->ax1 = self->ay1 = 0;
  *target = kGL_TEXTURE_2D;
  *name = self->gl_tex;
  *width = w;
  *height = h;
  return TRUE;
}

static void cef_fl_texture_sw_init(CefFlTextureSw* self) {
  self->mutex = new std::mutex();
  self->buf = new std::vector<uint8_t>();
  self->rgba = new std::vector<uint8_t>();
  self->w = self->h = 0;
  self->has_new = false;
  self->need_full = true;
  self->ax0 = self->ay0 = self->ax1 = self->ay1 = 0;
  self->gl_tex = 0;
  self->alloc = false;
  self->alloc_w = self->alloc_h = 0;
}

static void cef_fl_texture_sw_finalize(GObject* object) {
  CefFlTextureSw* self = CEF_FL_TEXTURE_SW(object);
  delete self->buf;
  delete self->rgba;
  delete self->mutex;
  G_OBJECT_CLASS(cef_fl_texture_sw_parent_class)->finalize(object);
}

static void cef_fl_texture_sw_class_init(CefFlTextureSwClass* klass) {
  G_OBJECT_CLASS(klass)->finalize = cef_fl_texture_sw_finalize;
  FL_TEXTURE_GL_CLASS(klass)->populate = cef_fl_texture_sw_populate;
}

// ===========================================================================
// 全局状态（单引擎、单宿主窗口）
// ===========================================================================

static FlTextureRegistrar* g_tex_reg = nullptr;
static FlMethodChannel* g_channel = nullptr;
static std::map<int64_t, CefFlTexture*>* g_textures = nullptr;         // 软件(pixbuf 兜底)
static std::map<int64_t, CefFlTextureGl*>* g_gl_textures = nullptr;    // GPU(DMABUF)
static std::map<int64_t, CefFlTextureSw*>* g_sw_textures = nullptr;    // 软件(GL 上传)

// ===========================================================================
// 位图帧仓库：Flutter **软件渲染器**（FLUTTER_LINUX_RENDERER=software）下的显示路径
//
// 为什么必须另起一条路：Flutter Linux 的外部纹理（FlTextureGL / FlPixelBufferTexture）
// 在 embedder 层**都经由 GL 实现**——FlPixelBufferTexture 只是替调用方做 CPU→GL 上传，
// 底层仍是 GL 纹理。软件渲染器不创建 GL 上下文，外部纹理于是整体失效（引擎日志：
// "external texture support is not enabled" / "Could not create external texture"），
// 实机表现就是 CEF 网页一片空白。
//
// 解法：这条路下**不注册 Flutter 纹理**，把 CEF OnPaint 的 BGRA 位图存在这里，由 Dart
// 侧经 FFI 读走，用 ui.decodeImageFromPixels 生成 ui.Image 交给 RawImage 显示。
// ui.Image 是 Skia 内部图像，软件渲染器下走 Skia 的 CPU 后端，完全支持。
// 存 BGRA 不转色：Dart 侧用 ui.PixelFormat.bgra8888 直接解释，省一遍全画幅逐像素转换。
//
// 线程：CEF 在平台线程写入，Dart 经 FFI 在 UI 线程读取，故 map 与每帧各自加锁。
// ===========================================================================
struct CefBitmapFrame {
  std::mutex mutex;
  std::vector<uint8_t> buf;  // BGRA8888，w*h*4；CEF 平台线程写
  int32_t w = 0;
  int32_t h = 0;
  int64_t seq = 0;  // 帧序号；Dart 侧靠它判断有无新帧，没变就不重建 ui.Image

  // 快照：acquire() 时在持锁状态下从 buf 拷一份，之后 Dart 可以安全地慢慢读，
  // 不必跨 FFI 调用持有 mutex（那样一旦 Dart 侧抛异常就会把 CEF 线程锁死）。
  // 只有 Dart UI 线程会碰这三个字段。
  std::vector<uint8_t> snapshot;
  int32_t snap_w = 0;
  int32_t snap_h = 0;
};
static std::map<int64_t, CefBitmapFrame*>* g_bitmap_frames = nullptr;
static std::mutex g_bitmap_map_mutex;
static int64_t g_next_bitmap_id = 1;
// true = Flutter 用软件渲染器，外部纹理不可用，必须走上面的位图路径。
static bool g_no_texture = false;

// 取位图槽；调用方不持有所有权。未找到返回 nullptr。
static CefBitmapFrame* bitmap_find(int64_t id) {
  std::lock_guard<std::mutex> lock(g_bitmap_map_mutex);
  if (!g_bitmap_frames) return nullptr;
  auto it = g_bitmap_frames->find(id);
  return it == g_bitmap_frames->end() ? nullptr : it->second;
}

// CEF 平台线程：提交一帧整幅 BGRA。脏矩形在这条路上忽略——Dart 侧每次都要完整
// 位图来建 ui.Image，增量没有意义。
static void bitmap_submit(CefBitmapFrame* f, const void* buffer, int w, int h) {
  if (!f || !buffer || w <= 0 || h <= 0) return;
  const size_t need = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
  std::lock_guard<std::mutex> lock(f->mutex);
  if (f->buf.size() != need) f->buf.resize(need);
  memcpy(f->buf.data(), buffer, need);
  f->w = w;
  f->h = h;
  ++f->seq;  // 从 1 开始递增；0 保留表示「尚无帧」
}
static FlPluginRegistrar* g_registrar = nullptr;  // 供 GTK 文件框取父窗口
// 注册时缓存的 FlView（供 GTK 文件框取父窗口）。
// 关键：不在文件框回调里现调 fl_plugin_registrar_get_view——个别 Flutter 版本下
// 延迟调用会触发 FL_IS_PLUGIN_REGISTRAR 断言并返回 NULL（日志可见），导致原生框
// 无父窗口；在统信/深度(xdg-portal 不可用、GtkFileChooserNative 退回 GTK 自带框)
// 下，无父窗口的模态框易出现焦点/层叠异常甚至崩溃。改为注册期（registrar 必定
// 有效）取一次并用 weak pointer 跟随其销毁自动置空。
static FlView* g_fl_view = nullptr;
static bool g_gpu = false;  // 引擎决定的渲染模式：true=GPU 共享纹理(DMABUF)
static bool g_sw_use_gl = false;  // 软件模式纹理：默认 pixbuf(最稳)；CEFWV_SW_TEX=gl 才用 GL 上传

// ---- 引擎函数指针（dlsym 自 libcef_webview_engine.so）----
typedef int (*PFN_init)(const CefwvCallbacks*, void*, const char*, const char*,
                        const char*, const char*, const char*, const char*, int,
                        int);
typedef int (*PFN_isinit)(void);
typedef void (*PFN_void)(void);
typedef int (*PFN_create)(const char*, int, int, float, int, int, unsigned int,
                          int frame_rate, int*, int64_t*);
typedef void (*PFN_i)(int);
typedef void (*PFN_is)(int, const char*);
typedef void (*PFN_resize)(int, int, int, float);
typedef void (*PFN_ii)(int, int);
typedef void (*PFN_mmove)(int, double, double, int);
typedef void (*PFN_mbtn)(int, double, double, int, int, int, int);
typedef void (*PFN_mwheel)(int, double, double, double, double);
typedef void (*PFN_key)(int, int, int, int, int, int);
typedef void (*PFN_ime_set)(int, const char*, int, int);
typedef void (*PFN_fdresult)(int, const char*);  // cefwv_engine_file_dialog_result
typedef void (*PFN_drag_enter)(int, double, double, int, const char*);
typedef void (*PFN_drag_over)(int, double, double, int);
typedef void (*PFN_drag_leave)(int);
typedef void (*PFN_drag_drop)(int, double, double, int);

static void* g_engine = nullptr;
static PFN_init g_init = nullptr;
static PFN_isinit g_isinit = nullptr;
static PFN_isinit g_gpu_enabled_fn = nullptr;  // cefwv_engine_gpu_enabled（可选）
static PFN_void g_shutdown = nullptr;
static PFN_void g_pump = nullptr;
static PFN_create g_create = nullptr;
static PFN_i g_close = nullptr, g_reload = nullptr, g_stop = nullptr,
             g_back = nullptr, g_forward = nullptr;
static PFN_is g_loadurl = nullptr, g_eval = nullptr;
static PFN_resize g_resize = nullptr;
static PFN_ii g_visible = nullptr, g_focus = nullptr;
static PFN_mmove g_mmove = nullptr;
static PFN_mbtn g_mbtn = nullptr;
static PFN_mwheel g_mwheel = nullptr;
static PFN_key g_key = nullptr;
static PFN_ime_set g_ime_set = nullptr;
static PFN_is g_ime_commit = nullptr;
static PFN_ii g_ime_finish = nullptr;
static PFN_i g_ime_cancel = nullptr;
static PFN_fdresult g_file_dialog_result = nullptr;
static PFN_drag_enter g_drag_enter = nullptr;
static PFN_drag_over g_drag_over = nullptr;
static PFN_drag_leave g_drag_leave = nullptr;
static PFN_drag_drop g_drag_drop = nullptr;

// ===========================================================================
// 引擎 → 插件 回调（均在平台线程触发，可安全操作 Flutter API）
// ===========================================================================

static int64_t cb_create_texture(void*, int w, int h) {
  // 软件渲染器：外部纹理在 embedder 层不可用，改走位图仓库（见上方说明）。
  // 这里返回的 id 只是位图槽编号，不是 Flutter 纹理 id，Dart 侧据 bitmapMode 区分。
  if (g_no_texture) {
    auto* f = new CefBitmapFrame();
    // 预填一帧透明像素，避免 Dart 首次读取时拿不到尺寸而闪一下空白。
    f->w = w > 0 ? w : 1;
    f->h = h > 0 ? h : 1;
    f->buf.assign(static_cast<size_t>(f->w) * f->h * 4, 0);
    int64_t id;
    {
      std::lock_guard<std::mutex> lock(g_bitmap_map_mutex);
      if (!g_bitmap_frames) g_bitmap_frames = new std::map<int64_t, CefBitmapFrame*>();
      id = g_next_bitmap_id++;
      (*g_bitmap_frames)[id] = f;
    }
    return id;
  }
  if (!g_tex_reg) return -1;
  // GPU 模式：创建 FlTextureGL（零拷贝，帧到达前 populate 返回 FALSE，Flutter 允许）。
  if (g_gpu) {
    CefFlTextureGl* tex =
        CEF_FL_TEXTURE_GL(g_object_new(cef_fl_texture_gl_get_type(), nullptr));
    if (!fl_texture_registrar_register_texture(g_tex_reg, FL_TEXTURE(tex))) {
      g_object_unref(tex);
      return -1;
    }
    int64_t id = fl_texture_get_id(FL_TEXTURE(tex));
    (*g_gl_textures)[id] = tex;
    return id;
  }
  // 软件模式（默认）：GL 上传纹理（免 CPU 转色 + 脏矩形增量），见 CefFlTextureSw。
  if (g_sw_use_gl) {
    CefFlTextureSw* tex =
        CEF_FL_TEXTURE_SW(g_object_new(cef_fl_texture_sw_get_type(), nullptr));
    if (!fl_texture_registrar_register_texture(g_tex_reg, FL_TEXTURE(tex))) {
      g_object_unref(tex);
      return -1;
    }
    int64_t id = fl_texture_get_id(FL_TEXTURE(tex));
    (*g_sw_textures)[id] = tex;
    return id;
  }
  // 软件模式（兜底 CEFWV_SW_TEX=pixbuf）：FlPixelBufferTexture。
  CefFlTexture* tex =
      CEF_FL_TEXTURE(g_object_new(cef_fl_texture_get_type(), nullptr));
  if (!fl_texture_registrar_register_texture(g_tex_reg, FL_TEXTURE(tex))) {
    g_object_unref(tex);
    return -1;
  }
  int64_t id = fl_texture_get_id(FL_TEXTURE(tex));
  // 预填一帧透明像素：Flutter raster 首次 copy_pixels 必须拿到有效 buffer，
  // 返回 FALSE/空 buffer 会导致 engine 崩溃。
  {
    std::lock_guard<std::mutex> lock(*tex->mutex);
    tex->stable->assign(static_cast<size_t>(w) * h * 4, 0);
    tex->width = static_cast<uint32_t>(w);
    tex->height = static_cast<uint32_t>(h);
  }
  (*g_textures)[id] = tex;
  return id;
}

// 软件 GL 纹理：提交一帧（脏矩形；dx/dy/dw/dh 为设备像素，full=整帧）。
static void sw_submit(CefFlTextureSw* tex, const void* buffer, int w, int h,
                      int dx, int dy, int dw, int dh) {
  const uint8_t* src = static_cast<const uint8_t*>(buffer);
  {
    std::lock_guard<std::mutex> lock(*tex->mutex);
    const bool size_changed =
        static_cast<uint32_t>(w) != tex->w ||
        static_cast<uint32_t>(h) != tex->h || tex->buf->empty();
    if (size_changed) {
      tex->buf->assign(src, src + static_cast<size_t>(w) * h * 4);
      tex->w = static_cast<uint32_t>(w);
      tex->h = static_cast<uint32_t>(h);
      tex->need_full = true;
      tex->ax0 = 0; tex->ay0 = 0; tex->ax1 = w; tex->ay1 = h;
    } else {
      // 夹取脏矩形到边界内。
      if (dx < 0) dx = 0;
      if (dy < 0) dy = 0;
      if (dx + dw > w) dw = w - dx;
      if (dy + dh > h) dh = h - dy;
      if (dw < 0) dw = 0;
      if (dh < 0) dh = 0;
      // 只拷贝脏矩形所在行的对应区间到 staging。
      for (int row = dy; row < dy + dh; ++row) {
        const size_t off = (static_cast<size_t>(row) * w + dx) * 4;
        memcpy(tex->buf->data() + off, src + off, static_cast<size_t>(dw) * 4);
      }
      const int x0 = dx, y0 = dy, x1 = dx + dw, y1 = dy + dh;
      if (tex->has_new) {  // 与上次未消费的脏矩形取并集
        if (x0 < tex->ax0) tex->ax0 = x0;
        if (y0 < tex->ay0) tex->ay0 = y0;
        if (x1 > tex->ax1) tex->ax1 = x1;
        if (y1 > tex->ay1) tex->ay1 = y1;
      } else {
        tex->ax0 = x0; tex->ay0 = y0; tex->ax1 = x1; tex->ay1 = y1;
      }
    }
    tex->has_new = true;
  }
  fl_texture_registrar_mark_texture_frame_available(g_tex_reg, FL_TEXTURE(tex));
}

// GPU 零拷贝路径：引擎在平台线程（CEF UI 线程）于 OnAcceleratedPaint 回调栈内同步
// 调用。frame->planes[i].fd 仅在本调用内有效，这里 dup() 保活到 raster 线程 populate。
static void cb_on_accelerated_frame(void*, int64_t id,
                                    const CefwvAcceleratedFrame* frame) {
  if (!g_gl_textures || !frame) return;
  auto it = g_gl_textures->find(id);
  if (it == g_gl_textures->end()) return;
  CefFlTextureGl* tex = it->second;
  {
    std::lock_guard<std::mutex> lock(*tex->mutex);
    if (tex->has_pending) ClosePlanes(tex->pending);  // 丢弃未消费的上一帧
    *tex->pending = *frame;
    for (int i = 0; i < frame->plane_count && i < 4; ++i) {
      tex->pending->planes[i].fd =
          frame->planes[i].fd >= 0 ? dup(frame->planes[i].fd) : -1;
    }
    tex->has_pending = true;
  }
  fl_texture_registrar_mark_texture_frame_available(g_tex_reg, FL_TEXTURE(tex));
}

// pixbuf 兜底纹理：整帧 BGRA→RGBA 转色提交（旧路径，仅 CEFWV_SW_TEX=pixbuf 时用）。
static void pixbuf_submit(CefFlTexture* tex, const void* buffer, int w, int h) {
  const uint8_t* src = static_cast<const uint8_t*>(buffer);
  const size_t n = static_cast<size_t>(w) * h;
  {
    std::lock_guard<std::mutex> lock(*tex->mutex);
    tex->pending->resize(n * 4);
    uint8_t* dst = tex->pending->data();
    for (size_t i = 0; i < n; ++i) {  // BGRA -> RGBA
      dst[i * 4 + 0] = src[i * 4 + 2];
      dst[i * 4 + 1] = src[i * 4 + 1];
      dst[i * 4 + 2] = src[i * 4 + 0];
      dst[i * 4 + 3] = src[i * 4 + 3];
    }
    tex->pending_w = w;
    tex->pending_h = h;
    tex->has_frame = true;
  }
  fl_texture_registrar_mark_texture_frame_available(g_tex_reg, FL_TEXTURE(tex));
}

// 软件全帧帧（旧引擎无 on_frame_rect 时的入口，或 dirty 缺失时）。按 id 路由到
// GL 上传纹理（整帧）或 pixbuf 兜底纹理。
static void cb_on_frame(void*, int64_t id, const void* buffer, int w, int h) {
  if (g_no_texture) {
    bitmap_submit(bitmap_find(id), buffer, w, h);
    return;
  }
  if (g_sw_textures) {
    auto it = g_sw_textures->find(id);
    if (it != g_sw_textures->end()) {
      sw_submit(it->second, buffer, w, h, 0, 0, w, h);
      return;
    }
  }
  auto it = g_textures->find(id);
  if (it == g_textures->end()) return;
  pixbuf_submit(it->second, buffer, w, h);
}

// 软件增量帧（新引擎）：GL 上传纹理走脏矩形增量；pixbuf 兜底纹理忽略脏矩形走整帧。
static void cb_on_frame_rect(void*, int64_t id, const void* buffer, int w, int h,
                             int dx, int dy, int dw, int dh) {
  // 位图路径忽略脏矩形：Dart 侧建 ui.Image 需要完整位图，增量在这里没有意义。
  if (g_no_texture) {
    bitmap_submit(bitmap_find(id), buffer, w, h);
    return;
  }
  if (g_sw_textures) {
    auto it = g_sw_textures->find(id);
    if (it != g_sw_textures->end()) {
      sw_submit(it->second, buffer, w, h, dx, dy, dw, dh);
      return;
    }
  }
  auto it = g_textures->find(id);
  if (it == g_textures->end()) return;
  pixbuf_submit(it->second, buffer, w, h);
}

static void cb_resize_texture(void*, int64_t, int, int) {}

static void cb_dispose_texture(void*, int64_t id) {
  if (g_no_texture) {
    CefBitmapFrame* f = nullptr;
    {
      std::lock_guard<std::mutex> lock(g_bitmap_map_mutex);
      if (g_bitmap_frames) {
        auto it = g_bitmap_frames->find(id);
        if (it != g_bitmap_frames->end()) {
          f = it->second;
          g_bitmap_frames->erase(it);
        }
      }
    }
    // 出了 map 锁再销毁：此刻已无人能通过 id 取到它，但可能有 FFI 调用正持着 f->mutex，
    // 先抢一次该锁确保对方已退出，再释放。
    if (f) {
      { std::lock_guard<std::mutex> lock(f->mutex); }
      delete f;
    }
    return;
  }
  if (g_gl_textures) {
    auto it = g_gl_textures->find(id);
    if (it != g_gl_textures->end()) {
      fl_texture_registrar_unregister_texture(g_tex_reg,
                                              FL_TEXTURE(it->second));
      g_object_unref(it->second);
      g_gl_textures->erase(it);
      return;
    }
  }
  if (g_sw_textures) {
    auto it = g_sw_textures->find(id);
    if (it != g_sw_textures->end()) {
      fl_texture_registrar_unregister_texture(g_tex_reg,
                                              FL_TEXTURE(it->second));
      g_object_unref(it->second);
      g_sw_textures->erase(it);
      return;
    }
  }
  auto it = g_textures->find(id);
  if (it == g_textures->end()) return;
  fl_texture_registrar_unregister_texture(g_tex_reg, FL_TEXTURE(it->second));
  g_object_unref(it->second);
  g_textures->erase(it);
}

static void invoke_event(const char* method, FlValue* args) {
  if (!g_channel) {
    fl_value_unref(args);
    return;
  }
  fl_method_channel_invoke_method(g_channel, method, args, nullptr, nullptr,
                                  nullptr);
  fl_value_unref(args);
}

static void cb_on_loading_state(void*, int bid, int loading, int back, int fwd,
                                double progress) {
  FlValue* a = fl_value_new_map();
  fl_value_set_string_take(a, "browserId", fl_value_new_int(bid));
  fl_value_set_string_take(a, "isLoading", fl_value_new_bool(loading));
  fl_value_set_string_take(a, "canGoBack", fl_value_new_bool(back));
  fl_value_set_string_take(a, "canGoForward", fl_value_new_bool(fwd));
  fl_value_set_string_take(a, "progress", fl_value_new_float(progress));
  invoke_event("onLoadingStateChange", a);
}
static void cb_on_address(void*, int bid, const char* url) {
  FlValue* a = fl_value_new_map();
  fl_value_set_string_take(a, "browserId", fl_value_new_int(bid));
  fl_value_set_string_take(a, "url", fl_value_new_string(url ? url : ""));
  invoke_event("onAddressChange", a);
}
static void cb_on_title(void*, int bid, const char* title) {
  FlValue* a = fl_value_new_map();
  fl_value_set_string_take(a, "browserId", fl_value_new_int(bid));
  fl_value_set_string_take(a, "title", fl_value_new_string(title ? title : ""));
  invoke_event("onTitleChange", a);
}
static void cb_on_load_error(void*, int bid, int code, const char* text,
                             const char* url) {
  FlValue* a = fl_value_new_map();
  fl_value_set_string_take(a, "browserId", fl_value_new_int(bid));
  fl_value_set_string_take(a, "errorCode", fl_value_new_int(code));
  fl_value_set_string_take(a, "errorText",
                           fl_value_new_string(text ? text : ""));
  fl_value_set_string_take(a, "failedUrl", fl_value_new_string(url ? url : ""));
  invoke_event("onLoadError", a);
}
static void cb_on_js_message(void*, int bid, const char* handler,
                             const char* data) {
  FlValue* a = fl_value_new_map();
  fl_value_set_string_take(a, "browserId", fl_value_new_int(bid));
  fl_value_set_string_take(a, "handler",
                           fl_value_new_string(handler ? handler : ""));
  fl_value_set_string_take(a, "data", fl_value_new_string(data ? data : ""));
  invoke_event("onJsMessage", a);
}
static void cb_on_before_popup(void*, int bid, const char* url) {
  FlValue* a = fl_value_new_map();
  fl_value_set_string_take(a, "browserId", fl_value_new_int(bid));
  fl_value_set_string_take(a, "targetUrl", fl_value_new_string(url ? url : ""));
  invoke_event("onBeforePopup", a);
}
static void cb_on_browser_closed(void*, int) {}

static void cb_on_ime_cursor(void*, int bid, int x, int y, int w, int h) {
  FlValue* a = fl_value_new_map();
  fl_value_set_string_take(a, "browserId", fl_value_new_int(bid));
  fl_value_set_string_take(a, "x", fl_value_new_int(x));
  fl_value_set_string_take(a, "y", fl_value_new_int(y));
  fl_value_set_string_take(a, "width", fl_value_new_int(w));
  fl_value_set_string_take(a, "height", fl_value_new_int(h));
  invoke_event("onImeCursorRect", a);
}

static void cb_on_cursor_change(void*, int bid, int cursor_type) {
  FlValue* a = fl_value_new_map();
  fl_value_set_string_take(a, "browserId", fl_value_new_int(bid));
  fl_value_set_string_take(a, "cursorType", fl_value_new_int(cursor_type));
  invoke_event("onCursorChange", a);
}

// ---- <input type=file>：GTK 原生文件框 ----
// 引擎侧用 CefWriteJSON 传来 JSON 字符串数组；这里做最小解析（含常见转义）。
static std::vector<std::string> fd_parse_json_array(const char* json) {
  std::vector<std::string> out;
  if (!json) return out;
  const char* p = json;
  while (*p && *p != '[') ++p;
  if (*p != '[') return out;
  ++p;
  while (*p) {
    while (*p && *p != '"' && *p != ']') ++p;
    if (*p != '"') break;
    ++p;
    std::string s;
    while (*p && *p != '"') {
      if (*p == '\\' && p[1]) {
        char c = p[1];
        switch (c) {
          case 'n': s.push_back('\n'); break;
          case 't': s.push_back('\t'); break;
          case 'r': s.push_back('\r'); break;
          default: s.push_back(c); break;  // \/ \" \\ 等取原字符
        }
        p += 2;
      } else {
        s.push_back(*p++);
      }
    }
    if (*p == '"') ++p;
    out.push_back(s);
  }
  return out;
}

// 选择结果序列化为 JSON 数组回传引擎（引擎侧用 CefParseJSON 解析）。
static std::string fd_serialize_json_array(
    const std::vector<std::string>& items) {
  std::string s = "[";
  for (size_t i = 0; i < items.size(); ++i) {
    if (i) s += ",";
    s += "\"";
    for (char c : items[i]) {
      if (c == '"' || c == '\\') {
        s.push_back('\\');
        s.push_back(c);
      } else if (c == '\n') {
        s += "\\n";
      } else if (c == '\r') {
        s += "\\r";
      } else if (c == '\t') {
        s += "\\t";
      } else {
        s.push_back(c);
      }
    }
    s += "\"";
  }
  s += "]";
  return s;
}

// 从 accept_filters 提取扩展名（不含点）；MIME/描述段跳过。
static std::vector<std::string> fd_exts_from_filters(
    const std::vector<std::string>& filters) {
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

// GtkFileChooserNative 的 response 信号（GTK 主线程，非阻塞）：收集路径回传引擎。
static void fd_on_response(GtkNativeDialog* dialog, gint response,
                          gpointer user_data) {
  int request_id = GPOINTER_TO_INT(user_data);
  std::vector<std::string> paths;
  if (response == GTK_RESPONSE_ACCEPT) {
    GtkFileChooser* chooser = GTK_FILE_CHOOSER(dialog);
    GSList* files = gtk_file_chooser_get_filenames(chooser);
    for (GSList* it = files; it; it = it->next) {
      char* pth = static_cast<char*>(it->data);
      if (pth) {
        paths.push_back(pth);
        g_free(pth);
      }
    }
    g_slist_free(files);
  }
  const std::string json = fd_serialize_json_array(paths);
  if (g_file_dialog_result) g_file_dialog_result(request_id, json.c_str());
  g_object_unref(dialog);
}

// 解析文件框父窗口（仅在 GTK 主线程调用）：优先用注册时缓存的 FlView 的顶层窗口；
// 不可用时回退到当前活动/可见的顶层 GtkWindow，尽量避免无父窗口的原生框。
static GtkWindow* fd_resolve_parent_window() {
  if (g_fl_view && GTK_IS_WIDGET(g_fl_view)) {
    GtkWidget* top = gtk_widget_get_toplevel(GTK_WIDGET(g_fl_view));
    if (top && GTK_IS_WINDOW(top)) return GTK_WINDOW(top);
  }
  GtkWindow* fallback = nullptr;
  GList* tops = gtk_window_list_toplevels();
  for (GList* it = tops; it; it = it->next) {
    if (!GTK_IS_WINDOW(it->data)) continue;
    GtkWindow* w = GTK_WINDOW(it->data);
    if (gtk_window_is_active(w)) {  // 活动窗口最优
      fallback = w;
      break;
    }
    if (!fallback && gtk_widget_get_visible(GTK_WIDGET(w)))
      fallback = w;  // 退而求其次：任一可见顶层
  }
  g_list_free(tops);
  return fallback;
}

// 引擎 → 插件：<input type=file> 请求。在 GTK 主线程用系统原生文件框呈现。
static void cb_on_file_dialog(void*, int request_id, int mode, int multiple,
                             const char* title, const char* filters_json) {
  GtkFileChooserAction action = GTK_FILE_CHOOSER_ACTION_OPEN;
  const char* accept = "_打开";
  if (mode == 2) {
    action = GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER;
  } else if (mode == 3) {
    action = GTK_FILE_CHOOSER_ACTION_SAVE;
    accept = "_保存";
  }

  // 注册期缓存的 FlView 优先；其顶层窗口作父窗口，避免无父窗口原生框在统信下异常。
  GtkWindow* parent = fd_resolve_parent_window();

  GtkFileChooserNative* native = gtk_file_chooser_native_new(
      (title && *title) ? title : nullptr, parent, action, accept, "_取消");
  GtkFileChooser* chooser = GTK_FILE_CHOOSER(native);
  if (mode == 0 || mode == 1)
    gtk_file_chooser_set_select_multiple(chooser, multiple ? TRUE : FALSE);

  if (mode == 0 || mode == 1) {
    std::vector<std::string> exts =
        fd_exts_from_filters(fd_parse_json_array(filters_json));
    if (!exts.empty()) {
      GtkFileFilter* filter = gtk_file_filter_new();
      gtk_file_filter_set_name(filter, "支持的文件");
      for (const auto& e : exts) {
        const std::string pat = "*." + e;
        gtk_file_filter_add_pattern(filter, pat.c_str());
      }
      gtk_file_chooser_add_filter(chooser, filter);
      GtkFileFilter* all = gtk_file_filter_new();
      gtk_file_filter_set_name(all, "所有文件");
      gtk_file_filter_add_pattern(all, "*");
      gtk_file_chooser_add_filter(chooser, all);
    }
  }

  g_signal_connect(native, "response", G_CALLBACK(fd_on_response),
                   GINT_TO_POINTER(request_id));
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(native));
}

static CefwvCallbacks g_callbacks = {
    cb_create_texture, cb_on_frame,       cb_resize_texture, cb_dispose_texture,
    cb_on_loading_state, cb_on_address,   cb_on_title,       cb_on_load_error,
    cb_on_js_message,  cb_on_before_popup, cb_on_browser_closed,
    cb_on_ime_cursor,  cb_on_file_dialog, cb_on_cursor_change,
    cb_on_accelerated_frame, cb_on_frame_rect};

// ===========================================================================
// 插件 GObject
// ===========================================================================

struct _CefWebviewPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar;
  FlMethodChannel* channel;
  guint pump_timer;
  bool initialized;
};

G_DEFINE_TYPE(CefWebviewPlugin, cef_webview_plugin, g_object_get_type())

#define CEF_WEBVIEW_PLUGIN(obj)                                       \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), cef_webview_plugin_get_type(), \
                              CefWebviewPlugin))

// ---- FlValue 小工具 ----
static double v_double(FlValue* m, const char* k) {
  FlValue* v = fl_value_lookup_string(m, k);
  if (!v) return 0.0;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT)
    return static_cast<double>(fl_value_get_int(v));
  return 0.0;
}
static int64_t v_int(FlValue* m, const char* k) {
  FlValue* v = fl_value_lookup_string(m, k);
  return (v && fl_value_get_type(v) == FL_VALUE_TYPE_INT) ? fl_value_get_int(v)
                                                          : 0;
}
static bool v_bool(FlValue* m, const char* k, bool def = false) {
  FlValue* v = fl_value_lookup_string(m, k);
  return (v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL)
             ? fl_value_get_bool(v)
             : def;
}
static std::string v_str(FlValue* m, const char* k) {
  FlValue* v = fl_value_lookup_string(m, k);
  return (v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING)
             ? fl_value_get_string(v)
             : std::string();
}
// 读取字符串列表参数并序列化为 JSON 数组（复用文件框那套格式，交引擎 CefParseJSON）。
static std::string v_str_list_json(FlValue* m, const char* k) {
  std::vector<std::string> out;
  FlValue* v = fl_value_lookup_string(m, k);
  if (v && fl_value_get_type(v) == FL_VALUE_TYPE_LIST) {
    const size_t n = fl_value_get_length(v);
    for (size_t i = 0; i < n; ++i) {
      FlValue* item = fl_value_get_list_value(v, i);
      if (item && fl_value_get_type(item) == FL_VALUE_TYPE_STRING)
        out.push_back(fl_value_get_string(item));
    }
  }
  return fd_serialize_json_array(out);
}
static std::string executable_dir() {
  char path[4096] = {0};
  ssize_t n = readlink("/proc/self/exe", path, sizeof(path) - 1);
  if (n <= 0) return ".";
  std::string p(path, n);
  auto pos = p.rfind('/');
  return pos == std::string::npos ? "." : p.substr(0, pos);
}

// CEF 运行时下载目录（与 Dart cef_runtime_manager.dart 的 _baseDir 公式一致）：
//   $HOME/.local/share/cef_webview/cef/<safeVer>
// 仅当 .ready 与 libcef_webview_engine.so 都存在时返回该目录；否则返回空串，
// 由调用方回退到「随包 exe/lib」（开发期）。
static const char* kCefSafeVersion = "144.0.29-g0b1a012-chromium-144.0.7559.256";

// 判定「这是不是一个 CEF 运行时目录」只看 libcef.so —— 那才是运行时包真正提供的
// 东西。曾经用 libcef_webview_engine.so 当标志，但引擎是我们自己的代码、要随 app
// 走（见 sync_bundled_engine），不能再当成运行时包的特征文件。
static bool looks_like_cef_runtime_dir(const std::string& dir) {
  return access((dir + "/libcef.so").c_str(), F_OK) == 0;
}

static std::string downloaded_cef_dir() {
  const char* home = getenv("HOME");
  if (!home || !*home) return std::string();
  std::string dir =
      std::string(home) + "/.local/share/cef_webview/cef/" + kCefSafeVersion;
  if (access((dir + "/.ready").c_str(), F_OK) != 0) return std::string();
  if (!looks_like_cef_runtime_dir(dir)) return std::string();
  return dir;
}


// 实际加载 CEF 的目录：由 load_engine() 设定，pre_initialize() 复用。
static std::string g_runtime_dir;

static gboolean pump_cb(gpointer) {
  if (g_pump) g_pump();
  return G_SOURCE_CONTINUE;
}

// 打印一个文件的路径与构建时间。引擎装的是我们自己的 common/ 实现，一旦又出现
// 「改了 C++ 不生效」，这一行立刻暴露它是哪来的、是不是旧的，不必再从空日志倒推
// 部署链路（这正是拖拽崩溃排查中连丢三个版本的原因）。
static void log_module_stamp(const char* label, const std::string& path) {
  struct stat st;
  if (stat(path.c_str(), &st) != 0) {
    g_printerr("[CEFWV] %s = %s (缺失)\n", label, path.c_str());
    return;
  }
  char ts[32] = {0};
  struct tm tm_buf;
  if (localtime_r(&st.st_mtime, &tm_buf))
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M", &tm_buf);
  g_printerr("[CEFWV] %s = %s (built %s)\n", label, path.c_str(), ts);
}

static bool load_engine() {
  if (g_engine) return g_init != nullptr;

  // ---- CEF 运行时目录：只放 CEF 自己的东西（libcef.so / *.pak / icudtl.dat /
  // locales）。判定标志用 libcef.so —— 那才是这个包真正提供的内容。
  // 离线预装目录最优先（启动器/install.sh 导出 CEF_RUNTIME_ROOT，与 Dart 侧
  // cef_runtime_manager.dart 的 resolveReadyRoot 优先级一致），其次在线下载目录。
  std::string dir;
  const char* override_root = getenv("CEF_RUNTIME_ROOT");
  if (override_root && *override_root &&
      looks_like_cef_runtime_dir(override_root)) {
    dir = override_root;
  }
  if (dir.empty()) dir = downloaded_cef_dir();
  if (dir.empty()) dir = executable_dir() + "/lib";  // 回退：随包(开发期)
  g_runtime_dir = dir;

  // ---- 引擎：认 app 自带的那份，与本次构建同版本。
  //
  // 引擎（连同 subprocess）编的是 common/ 全部实现——浏览器管理、鼠标键盘、IME、
  // 拖拽、OnFileDialog、渲染回调，全是我们自己的代码，必须跟 app 版本走。它过去
  // 被打进「CEF 运行时下载包」一起分发，而那个包按 CEF 版本重建、不随 app 更新，
  // 于是 app 升级后机器上仍在跑几个月前的 common/：改了不生效，且没有任何提示。
  //
  // 现在由 linux/CMakeLists.txt 把它随 app 装进 bundle/lib/，这里优先加载；
  // 运行时目录里那份仅作旧布局兜底，永远不会再遮住 app 自己的代码。
  const std::string bundled_engine =
      executable_dir() + "/lib/libcef_webview_engine.so";
  std::string engine_path = bundled_engine;
  if (access(engine_path.c_str(), F_OK) != 0)
    engine_path = dir + "/libcef_webview_engine.so";  // 兜底：旧布局
  log_module_stamp("engine", engine_path);
  log_module_stamp("cef", dir + "/libcef.so");

  // 引擎的 DT_RPATH 是 $ORIGIN，从 bundle/lib 加载时找不到住在运行时目录的
  // libcef.so，故先按绝对路径把它加载进来。同一命名空间内 DT_NEEDED 会直接复用
  // 这个已加载对象，不必依赖任何搜索路径。
  //
  // 标志必须与下面加载引擎时一致：libcef.so 原本是作为引擎的依赖、在同一次
  // DEEPBIND dlopen 里被带进来的，符号隔离正是靠这个。改成先单独加载后若丢掉
  // DEEPBIND，libcef 就会去和 Flutter engine（同源 Chromium）绑同名符号，
  // 退回到 CefInitialize 死锁的老问题上。
  const std::string libcef_path = dir + "/libcef.so";
  if (engine_path == bundled_engine &&
      access(libcef_path.c_str(), F_OK) == 0) {
    if (!dlopen(libcef_path.c_str(),
                RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND)) {
      g_printerr("[CEFWV] 预加载 %s 失败: %s\n", libcef_path.c_str(),
                 dlerror());
    }
  }

  // RTLD_DEEPBIND：让引擎及其依赖的 libcef 优先解析自身符号/分配器，
  // 与 Flutter engine（同基于 Chromium）隔离，避免 CefInitialize 死锁。
  g_engine = dlopen(engine_path.c_str(),
                    RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
  if (!g_engine) {
    g_printerr("[CEFWV] dlopen %s failed: %s\n", engine_path.c_str(),
               dlerror());
    return false;
  }
#define SYM(var, type, name)                              \
  var = reinterpret_cast<type>(dlsym(g_engine, name));    \
  if (!var) {                                             \
    g_printerr("[CEFWV] dlsym %s failed\n", name);        \
    return false;                                         \
  }
  SYM(g_init, PFN_init, "cefwv_engine_initialize");
  SYM(g_isinit, PFN_isinit, "cefwv_engine_is_initialized");
  // GPU 模式查询：旧引擎 so 可能无此符号，缺失即按软件模式（容错，不 return）。
  g_gpu_enabled_fn = reinterpret_cast<PFN_isinit>(
      dlsym(g_engine, "cefwv_engine_gpu_enabled"));
  SYM(g_shutdown, PFN_void, "cefwv_engine_shutdown");
  SYM(g_pump, PFN_void, "cefwv_engine_pump");
  SYM(g_create, PFN_create, "cefwv_engine_create_browser");
  SYM(g_close, PFN_i, "cefwv_engine_close_browser");
  SYM(g_loadurl, PFN_is, "cefwv_engine_load_url");
  SYM(g_reload, PFN_i, "cefwv_engine_reload");
  SYM(g_stop, PFN_i, "cefwv_engine_stop_load");
  SYM(g_back, PFN_i, "cefwv_engine_go_back");
  SYM(g_forward, PFN_i, "cefwv_engine_go_forward");
  SYM(g_resize, PFN_resize, "cefwv_engine_resize");
  SYM(g_visible, PFN_ii, "cefwv_engine_set_visible");
  SYM(g_focus, PFN_ii, "cefwv_engine_set_focus");
  SYM(g_eval, PFN_is, "cefwv_engine_eval_js");
  SYM(g_mmove, PFN_mmove, "cefwv_engine_mouse_move");
  SYM(g_mbtn, PFN_mbtn, "cefwv_engine_mouse_button");
  SYM(g_mwheel, PFN_mwheel, "cefwv_engine_mouse_wheel");
  SYM(g_key, PFN_key, "cefwv_engine_key");
  SYM(g_ime_set, PFN_ime_set, "cefwv_engine_ime_set_composition");
  SYM(g_ime_commit, PFN_is, "cefwv_engine_ime_commit");
  SYM(g_ime_finish, PFN_ii, "cefwv_engine_ime_finish");
  SYM(g_ime_cancel, PFN_i, "cefwv_engine_ime_cancel");
#undef SYM
  // 文件框回执函数：旧引擎 so 可能无此符号，缺失时容错（不 return false），
  // 仅退化为「文件框选择无法回传」，不影响其余功能加载。
  g_file_dialog_result = reinterpret_cast<PFN_fdresult>(
      dlsym(g_engine, "cefwv_engine_file_dialog_result"));
  // 拖拽相关：同为「后追加」的符号，旧引擎 so 可能没有；缺失时容错退化为
  // 「拖拽上传不可用」，不阻断插件加载。
  g_drag_enter = reinterpret_cast<PFN_drag_enter>(
      dlsym(g_engine, "cefwv_engine_drag_enter"));
  g_drag_over = reinterpret_cast<PFN_drag_over>(
      dlsym(g_engine, "cefwv_engine_drag_over"));
  g_drag_leave = reinterpret_cast<PFN_drag_leave>(
      dlsym(g_engine, "cefwv_engine_drag_leave"));
  g_drag_drop = reinterpret_cast<PFN_drag_drop>(
      dlsym(g_engine, "cefwv_engine_drag_drop"));
  return true;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
  CefWebviewPlugin* self = CEF_WEBVIEW_PLUGIN(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);

  if (strcmp(method, "initialize") == 0) {
    bool ok = g_isinit && g_isinit() != 0;
    if (ok && !self->initialized) {
      self->initialized = true;
      self->pump_timer = g_timeout_add(16, pump_cb, self);
    }
    if (ok) {
      fl_method_call_respond_success(call, nullptr, nullptr);
    } else {
      g_autoptr(FlMethodResponse) r = FL_METHOD_RESPONSE(
          fl_method_error_response_new(
              "INIT_FAILED", "CEF 引擎未初始化（pre_initialize 失败）",
              nullptr));
      fl_method_call_respond(call, r, nullptr);
    }
    return;
  }

  if (strcmp(method, "createBrowser") == 0) {
    int transparent = 0, enable_js = 1, frame_rate = 0;
    unsigned int bg = 0xFFFFFFFFu;
    FlValue* s = fl_value_lookup_string(args, "settings");
    if (s && fl_value_get_type(s) == FL_VALUE_TYPE_MAP) {
      transparent = v_bool(s, "transparent") ? 1 : 0;
      enable_js = v_bool(s, "enableJavaScript", true) ? 1 : 0;
      bg = static_cast<unsigned int>(v_int(s, "backgroundColor"));
      frame_rate = static_cast<int>(v_int(s, "windowlessFrameRate"));
    }
    int bid = 0;
    int64_t tex = -1;
    int ok = g_create
                 ? g_create(v_str(args, "url").c_str(),
                            static_cast<int>(v_int(args, "width")),
                            static_cast<int>(v_int(args, "height")),
                            static_cast<float>(v_double(args, "dpr")),
                            transparent, enable_js, bg, frame_rate, &bid, &tex)
                 : 0;
    if (!ok) {
      g_autoptr(FlMethodResponse) r = FL_METHOD_RESPONSE(
          fl_method_error_response_new("CREATE_FAILED",
                                       "create_browser 失败", nullptr));
      fl_method_call_respond(call, r, nullptr);
      return;
    }
    FlValue* map = fl_value_new_map();
    fl_value_set_string_take(map, "browserId", fl_value_new_int(bid));
    fl_value_set_string_take(map, "textureId", fl_value_new_int(tex));
    // bitmapMode=true 时 textureId 不是 Flutter 纹理 id，而是位图槽编号：
    // Dart 侧要改用 FFI 拉帧 + RawImage 显示，不能用 Texture widget。
    fl_value_set_string_take(map, "bitmapMode",
                             fl_value_new_bool(g_no_texture));
    g_autoptr(FlMethodResponse) r =
        FL_METHOD_RESPONSE(fl_method_success_response_new(map));
    fl_method_call_respond(call, r, nullptr);
    fl_value_unref(map);
    return;
  }

  const int id = static_cast<int>(v_int(args, "browserId"));
  if (strcmp(method, "loadUrl") == 0) {
    if (g_loadurl) g_loadurl(id, v_str(args, "url").c_str());
  } else if (strcmp(method, "reload") == 0) {
    if (g_reload) g_reload(id);
  } else if (strcmp(method, "stopLoad") == 0) {
    if (g_stop) g_stop(id);
  } else if (strcmp(method, "goBack") == 0) {
    if (g_back) g_back(id);
  } else if (strcmp(method, "goForward") == 0) {
    if (g_forward) g_forward(id);
  } else if (strcmp(method, "resize") == 0) {
    if (g_resize)
      g_resize(id, static_cast<int>(v_int(args, "width")),
               static_cast<int>(v_int(args, "height")),
               static_cast<float>(v_double(args, "dpr")));
  } else if (strcmp(method, "setVisible") == 0) {
    if (g_visible) g_visible(id, v_bool(args, "visible", true) ? 1 : 0);
  } else if (strcmp(method, "setFocus") == 0) {
    if (g_focus) g_focus(id, v_bool(args, "focused", true) ? 1 : 0);
  } else if (strcmp(method, "evaluateJavascript") == 0) {
    if (g_eval) g_eval(id, v_str(args, "source").c_str());
  } else if (strcmp(method, "mouseMove") == 0) {
    if (g_mmove)
      g_mmove(id, v_double(args, "x"), v_double(args, "y"),
              v_bool(args, "leave") ? 1 : 0);
  } else if (strcmp(method, "mouseButton") == 0) {
    if (g_mbtn)
      g_mbtn(id, v_double(args, "x"), v_double(args, "y"),
             static_cast<int>(v_int(args, "button")),
             v_bool(args, "down") ? 1 : 0,
             static_cast<int>(v_int(args, "clickCount")),
             static_cast<int>(v_int(args, "modifiers")));
  } else if (strcmp(method, "mouseWheel") == 0) {
    if (g_mwheel)
      g_mwheel(id, v_double(args, "x"), v_double(args, "y"),
               v_double(args, "deltaX"), v_double(args, "deltaY"));
  } else if (strcmp(method, "dragTargetDragEnter") == 0) {
    if (g_drag_enter) {
      const std::string paths_json = v_str_list_json(args, "paths");
      g_drag_enter(id, v_double(args, "x"), v_double(args, "y"),
                   static_cast<int>(v_int(args, "modifiers")),
                   paths_json.c_str());
    }
  } else if (strcmp(method, "dragTargetDragOver") == 0) {
    if (g_drag_over)
      g_drag_over(id, v_double(args, "x"), v_double(args, "y"),
                  static_cast<int>(v_int(args, "modifiers")));
  } else if (strcmp(method, "dragTargetDragLeave") == 0) {
    if (g_drag_leave) g_drag_leave(id);
  } else if (strcmp(method, "dragTargetDrop") == 0) {
    if (g_drag_drop)
      g_drag_drop(id, v_double(args, "x"), v_double(args, "y"),
                  static_cast<int>(v_int(args, "modifiers")));
  } else if (strcmp(method, "key") == 0) {
    if (g_key)
      g_key(id, static_cast<int>(v_int(args, "type")),
            static_cast<int>(v_int(args, "windowsKeyCode")),
            static_cast<int>(v_int(args, "nativeKeyCode")),
            static_cast<int>(v_int(args, "modifiers")),
            static_cast<int>(v_int(args, "character")));
  } else if (strcmp(method, "imeSetComposition") == 0) {
    if (g_ime_set)
      g_ime_set(id, v_str(args, "text").c_str(),
                static_cast<int>(v_int(args, "selectionStart")),
                static_cast<int>(v_int(args, "selectionEnd")));
  } else if (strcmp(method, "imeCommitText") == 0) {
    if (g_ime_commit) g_ime_commit(id, v_str(args, "text").c_str());
  } else if (strcmp(method, "imeFinishComposing") == 0) {
    if (g_ime_finish)
      g_ime_finish(id, v_bool(args, "keepSelection", true) ? 1 : 0);
  } else if (strcmp(method, "imeCancelComposition") == 0) {
    if (g_ime_cancel) g_ime_cancel(id);
  } else if (strcmp(method, "closeBrowser") == 0) {
    if (g_close) g_close(id);
  } else if (strcmp(method, "shutdown") == 0) {
    if (self->pump_timer) {
      g_source_remove(self->pump_timer);
      self->pump_timer = 0;
    }
    if (g_shutdown) g_shutdown();
    self->initialized = false;
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}

static void cef_webview_plugin_dispose(GObject* object) {
  CefWebviewPlugin* self = CEF_WEBVIEW_PLUGIN(object);
  if (self->pump_timer) {
    g_source_remove(self->pump_timer);
    self->pump_timer = 0;
  }
  g_clear_object(&self->channel);
  G_OBJECT_CLASS(cef_webview_plugin_parent_class)->dispose(object);
}

static void cef_webview_plugin_class_init(CefWebviewPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = cef_webview_plugin_dispose;
}

static void cef_webview_plugin_init(CefWebviewPlugin* self) {
  self->pump_timer = 0;
  self->initialized = false;
}

void cef_webview_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  CefWebviewPlugin* self = CEF_WEBVIEW_PLUGIN(
      g_object_new(cef_webview_plugin_get_type(), nullptr));
  self->registrar = registrar;

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "cef_webview",
      FL_METHOD_CODEC(codec));

  // 回调依赖的全局 Flutter 句柄（单宿主窗口）。
  g_tex_reg = fl_plugin_registrar_get_texture_registrar(registrar);
  g_channel = self->channel;
  g_registrar = registrar;  // 供 GTK 文件框获取父窗口

  // 注册期（registrar 必定有效）取一次 FlView 缓存，供文件框取父窗口；
  // 用 weak pointer 跟随其销毁自动置空，避免悬垂。见 g_fl_view 说明与 cb_on_file_dialog。
  if (FL_IS_PLUGIN_REGISTRAR(registrar)) {
    FlView* view = fl_plugin_registrar_get_view(registrar);
    if (view && FL_IS_VIEW(view)) {
      g_fl_view = view;
      g_object_add_weak_pointer(G_OBJECT(view),
                                reinterpret_cast<gpointer*>(&g_fl_view));
    }
  }

  fl_method_channel_set_method_call_handler(
      self->channel, method_call_cb, g_object_ref(self), g_object_unref);
}

void cef_webview_plugin_pre_initialize(void) {
  if (!g_textures) g_textures = new std::map<int64_t, CefFlTexture*>();
  if (!g_gl_textures) g_gl_textures = new std::map<int64_t, CefFlTextureGl*>();
  if (!g_sw_textures) g_sw_textures = new std::map<int64_t, CefFlTextureSw*>();
  // Flutter 软件渲染器下外部纹理整体不可用（embedder 层的 FlTextureGL/
  // FlPixelBufferTexture 都走 GL），必须改用位图 + Dart 侧 ui.Image 显示。
  {
    const char* r = getenv("FLUTTER_LINUX_RENDERER");
    g_no_texture = (r && strcmp(r, "software") == 0);
    if (g_no_texture && !g_bitmap_frames) {
      g_bitmap_frames = new std::map<int64_t, CefBitmapFrame*>();
    }
  }
  // 软件模式纹理实现：**默认 pixbuf**（FlPixelBufferTexture，由 Flutter 用它自身的
  // GL 绑定上传，跨 GLX/EGL、各家驱动最稳）。插件自带的 GL 上传(CefFlTextureSw)从
  // libGLESv2 取符号，在桌面 GL(GLX) 上下文（如统信 AMD OLAND / radeonsi / Mesa）下
  // 与 Flutter 的 GLX 上下文错配 → 打开网页/上传重绘时崩溃。故仅在显式
  // CEFWV_SW_TEX=gl 时才启用该优化路径。
  {
    const char* e = getenv("CEFWV_SW_TEX");
    g_sw_use_gl = (e && strcmp(e, "gl") == 0);
  }
  if (!load_engine()) {
    g_warning("[cef_webview] 加载 CEF 引擎 (libcef_webview_engine.so) 失败");
    return;
  }
  const std::string lib_dir = g_runtime_dir;  // load_engine 设定：CEF 运行时目录
  // 子进程与引擎同源（都编了 common/），同样认 app 自带的那份；旧布局兜底到运行时目录。
  std::string subprocess = executable_dir() + "/lib/cef_webview_subprocess";
  if (access(subprocess.c_str(), X_OK) != 0)
    subprocess = lib_dir + "/cef_webview_subprocess";
  log_module_stamp("subprocess", subprocess);
  // 子进程是 CEF 另起的独立进程，它的 DT_RPATH 同样是 $ORIGIN，从 bundle/lib 起来时
  // 找不到运行时目录里的 libcef.so。父进程这里提前把该目录塞进 LD_LIBRARY_PATH——
  // 子进程是 fork+exec 出来的，会在自己启动时重新读这个变量，因此有效。
  {
    const char* old = getenv("LD_LIBRARY_PATH");
    std::string v = lib_dir;
    if (old && *old) v += std::string(":") + old;
    setenv("LD_LIBRARY_PATH", v.c_str(), 1);
  }
  // locale pak 在运行时目录的 locales/ 子目录（传错会报 Could not load locale pak）
  const std::string locales_dir = lib_dir + "/locales";
  std::string cache = std::string(g_get_user_data_dir()) + "/cef_webview/cache";
  g_mkdir_with_parents(cache.c_str(), 0755);

  g_init(&g_callbacks, nullptr, cache.c_str(), "zh-CN", "", subprocess.c_str(),
         lib_dir.c_str(), locales_dir.c_str(), /*log_severity=*/2,
         /*remote_debugging_port=*/0);

  // 读取引擎最终决定的渲染模式，决定 create_texture 用 FlTextureGL 还是 pixbuf。
  g_gpu = g_gpu_enabled_fn && g_gpu_enabled_fn() != 0;
  g_printerr("[cef_webview] render mode = %s%s\n",
             g_gpu ? "GPU (DMABUF zero-copy)" : "software (OnPaint)",
             g_no_texture ? " + bitmap(FFI→ui.Image，Flutter 软件渲染器)" : "");
}

// ===========================================================================
// FFI 导出：供 Dart 在「Flutter 软件渲染器」下直接拉取 CEF 位图帧
//
// 用 DynamicLibrary.process() 即可解析这些符号（插件 .so 已随 app 加载）。
// apply_standard_settings() 会带 -fvisibility=hidden，故必须显式标 default 可见性，
// 否则 Dart 侧会报 "Failed to lookup symbol"。
// ===========================================================================
#define CEFWV_FFI_EXPORT extern "C" __attribute__((visibility("default")))

// 接口刻意设计成「无 out 参数、无需调用方分配内存」，这样 Dart 侧只用 dart:ffi 就够，
// 不必引入 package:ffi 的 calloc。Dart 调用顺序：
//   seq() 判断有无新帧 → acquire() 做快照拿指针 → snapshot_size() 取快照尺寸 → 读像素

// 最新帧序号。0 = 尚无帧或槽位不存在。Dart 每帧调用，与上次相同就直接跳过。
CEFWV_FFI_EXPORT int64_t cefwv_bitmap_seq(int64_t id) {
  CefBitmapFrame* f = bitmap_find(id);
  if (!f) return 0;
  std::lock_guard<std::mutex> lock(f->mutex);
  return f->seq;
}

// 在持锁状态下把最新帧拷进内部快照，返回快照首地址（BGRA8888）。
// 返回 nullptr = 无帧/槽位不存在。返回后锁已释放，Dart 可安全读取快照：
// CEF 后续新帧只会写 buf，不会动 snapshot，直到下一次 acquire。
CEFWV_FFI_EXPORT const uint8_t* cefwv_bitmap_acquire(int64_t id) {
  CefBitmapFrame* f = bitmap_find(id);
  if (!f) return nullptr;
  std::lock_guard<std::mutex> lock(f->mutex);
  if (f->seq == 0 || f->buf.empty()) return nullptr;
  const size_t need = static_cast<size_t>(f->w) * f->h * 4;
  if (need == 0 || f->buf.size() < need) return nullptr;
  if (f->snapshot.size() != need) f->snapshot.resize(need);
  memcpy(f->snapshot.data(), f->buf.data(), need);
  f->snap_w = f->w;
  f->snap_h = f->h;
  return f->snapshot.data();
}

// 上一次 acquire 得到的快照尺寸：高 32 位 = 宽，低 32 位 = 高。
// 必须用快照own的尺寸而不是当前帧尺寸——两者之间 CEF 可能已因窗口缩放换了分辨率，
// 用错尺寸解释像素会花屏或越界。
CEFWV_FFI_EXPORT int64_t cefwv_bitmap_snapshot_size(int64_t id) {
  CefBitmapFrame* f = bitmap_find(id);
  if (!f) return 0;
  return (static_cast<int64_t>(f->snap_w) << 32) |
         (static_cast<int64_t>(f->snap_h) & 0xFFFFFFFF);
}
