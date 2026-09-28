// 平台无关的「Flutter 外部纹理」抽象。
//
// 三端各自实现：
//   - Linux  : FlTextureGL / FlPixelBufferTexture (flutter_linux)
//   - Windows: FlutterDesktopTextureRegistrar + FlutterDesktopPixelBuffer
//   - macOS  : FlutterTexture + CVPixelBuffer (Metal)
//
// CEF OSR 的 OnPaint 回调产出 BGRA32 像素缓冲，统一经由本接口提交到 Flutter。
#ifndef CEF_WEBVIEW_FLUTTER_TEXTURE_BRIDGE_H_
#define CEF_WEBVIEW_FLUTTER_TEXTURE_BRIDGE_H_

#include <cstdint>

namespace cef_webview {

// CEF OnAcceleratedPaint 路径的一帧 GPU 共享纹理信息（平台无关承载）。
//   Windows: shared_handle = D3D11 Texture2D 的共享 HANDLE（CEF 144 无 keyed mutex）
//   macOS  : shared_handle = IOSurfaceRef
//   Linux  : 用 planes（DMABUF fd）承载，shared_handle 不使用
// 注意：CEF 的底层资源用帧池分发，句柄仅在 OnAcceleratedPaint 回调内有效、
// 回调返回后即回收，实现方必须在回调内把内容拷贝到自己拥有的纹理。
struct AcceleratedFrameInfo {
  int width = 0;
  int height = 0;
  int format = 0;                 // cef_color_type_t 数值（0 = 默认 BGRA8888）
  void* shared_handle = nullptr;  // Windows HANDLE / macOS IOSurfaceRef
  int plane_count = 0;            // Linux DMABUF plane 数（其余端为 0）
  struct Plane {
    int fd = -1;
    uint32_t stride = 0;
    uint32_t offset = 0;
    uint64_t size = 0;
  } planes[4];
  uint64_t modifier = 0;          // Linux DMABUF format modifier
};

class FlutterTextureBridge {
 public:
  virtual ~FlutterTextureBridge() = default;

  // 注册一个新的外部纹理（设备像素 width*height），返回 Flutter textureId。
  // 返回 -1 表示失败。
  virtual int64_t CreateTexture(int width, int height) = 0;

  // CEF UI 线程在 OnPaint 中调用：提交一帧 BGRA32 数据
  // （buffer 长度 = width*height*4，行序自上而下）。
  // 实现需做必要的 BGRA→RGBA 转换（macOS 的 CVPixelBuffer 可直接用 BGRA），
  // 上传/拷贝后通知 Flutter「帧可用」。
  virtual void OnFrame(int64_t texture_id,
                       const void* buffer,
                       int width,
                       int height) = 0;

  // 软件 OSR 增量帧：同 OnFrame，但附带本次变化的脏矩形包围盒（设备像素，
  // 自上而下）。实现方可据此只转色/上传变化区域，省掉每帧全画幅 CPU 开销。
  // 默认转调 OnFrame（忽略脏矩形），保证旧实现零改动可用。
  virtual void OnFrameRect(int64_t texture_id,
                           const void* buffer,
                           int width,
                           int height,
                           int dirty_x,
                           int dirty_y,
                           int dirty_w,
                           int dirty_h) {
    (void)dirty_x;
    (void)dirty_y;
    (void)dirty_w;
    (void)dirty_h;
    OnFrame(texture_id, buffer, width, height);
  }

  // CEF OnAcceleratedPaint（GPU 共享纹理零拷贝）路径提交一帧。默认空实现：
  // 未启用 GPU 加速、或该平台尚未实现加速路径时不生效（继续走 OnFrame 软件路径）。
  virtual void OnAcceleratedFrame(int64_t texture_id,
                                  const AcceleratedFrameInfo& info) {}

  // 调整纹理后备存储尺寸（窗口/控件尺寸变化时）。
  virtual void ResizeTexture(int64_t texture_id, int width, int height) = 0;

  // 注销并释放纹理。
  virtual void DisposeTexture(int64_t texture_id) = 0;
};

}  // namespace cef_webview

#endif  // CEF_WEBVIEW_FLUTTER_TEXTURE_BRIDGE_H_
