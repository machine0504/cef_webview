#ifndef FLUTTER_PLUGIN_CEF_WEBVIEW_PLUGIN_H_
#define FLUTTER_PLUGIN_CEF_WEBVIEW_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/texture_registrar.h>
#include <windows.h>

#include <map>
#include <memory>
#include <mutex>
#include <vector>

#include "cef_webview/cef_event_sink.h"
#include "cef_webview/flutter_texture_bridge.h"

namespace cef_webview {

class CefWebviewPlugin : public flutter::Plugin,
                         public FlutterTextureBridge,
                         public CefEventSink {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar);

  explicit CefWebviewPlugin(flutter::PluginRegistrarWindows* registrar);
  ~CefWebviewPlugin() override;

  // FlutterTextureBridge
  int64_t CreateTexture(int width, int height) override;
  void OnFrame(int64_t texture_id, const void* buffer, int width,
               int height) override;
  // GPU 零拷贝路径：消费 CEF OnAcceleratedPaint 交付的 D3D11 共享句柄，经 Flutter
  // GpuSurfaceTexture(DxgiSharedHandle) 直接上屏（免 CPU 回读/转色）。
  void OnAcceleratedFrame(int64_t texture_id,
                          const AcceleratedFrameInfo& info) override;
  void ResizeTexture(int64_t texture_id, int width, int height) override;
  void DisposeTexture(int64_t texture_id) override;

  // CefEventSink
  void OnLoadingStateChange(int id, bool loading, bool back, bool fwd,
                            double progress) override;
  void OnAddressChange(int id, const std::string& url) override;
  void OnTitleChange(int id, const std::string& title) override;
  void OnLoadError(int id, int code, const std::string& text,
                   const std::string& url) override;
  void OnJsMessage(int id, const std::string& handler,
                   const std::string& data_json) override;
  void OnBeforePopup(int id, const std::string& target_url) override;
  void OnGlobalError(const std::string& message) override;
  void OnImeCursorRect(int id, int x, int y, int width, int height) override;
  void OnCursorChange(int id, int cursor_type) override;

 private:
  struct TextureEntry {
    std::unique_ptr<flutter::TextureVariant> variant;
    std::mutex mutex;
    std::vector<uint8_t> pending;  // OnFrame 写入（RGBA）
    std::vector<uint8_t> present;  // 返回给 Flutter
    int pending_w = 0, pending_h = 0;
    int width = 0, height = 0;
    bool dirty = false;
    FlutterDesktopPixelBuffer fb{};
    int64_t id = -1;
    // GPU 加速（共享纹理）路径：CEF 交付的 D3D11 共享 HANDLE + 尺寸，交给
    // Flutter 的 GpuSurfaceTexture 描述符（DxgiSharedHandle）。句柄由 CEF 帧池
    // 分发，回调返回后可能被复用/回收（与 mac/linux 同）；此处透传，靠 CEF 帧池
    // 深度 + raster 及时消费规避撕裂，必要时可改为拷贝到自有纹理。
    void* shared_handle = nullptr;
    size_t gpu_w = 0, gpu_h = 0;
    FlutterDesktopGpuSurfaceDescriptor gpu_desc{};
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void EnsureInitialized(const flutter::EncodableMap& args);
  void StartPump();
  void InvokeEvent(const std::string& method, flutter::EncodableMap args);

  flutter::PluginRegistrarWindows* registrar_;
  flutter::TextureRegistrar* textures_;
  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::map<int64_t, std::unique_ptr<TextureEntry>> entries_;
  HWND pump_hwnd_ = nullptr;
  bool initialized_ = false;
  bool gpu_ = false;  // GPU 共享纹理模式（gpuSharedTexture）：CreateTexture 据此选
                      // GpuSurfaceTexture 还是 PixelBufferTexture。
};

}  // namespace cef_webview

#endif  // FLUTTER_PLUGIN_CEF_WEBVIEW_PLUGIN_H_
