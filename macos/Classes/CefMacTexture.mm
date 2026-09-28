#import "CefMacTexture.h"
#import <mutex>

@implementation CefMacTexture {
  std::mutex _mutex;
  CVPixelBufferRef _pixelBuffer;  // 当前可呈现帧
  int _width;
  int _height;
}

- (instancetype)init {
  if (self = [super init]) {
    _pixelBuffer = nullptr;
    _width = 0;
    _height = 0;
  }
  return self;
}

- (void)dealloc {
  std::lock_guard<std::mutex> lock(_mutex);
  if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
}

- (void)ensureBuffer:(int)width height:(int)height {
  if (_pixelBuffer && _width == width && _height == height) return;
  if (_pixelBuffer) {
    CVPixelBufferRelease(_pixelBuffer);
    _pixelBuffer = nullptr;
  }
  NSDictionary *attrs = @{
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                      kCVPixelFormatType_32BGRA,
                      (__bridge CFDictionaryRef)attrs, &_pixelBuffer);
  _width = width;
  _height = height;
}

- (void)updateWithBuffer:(const void *)buffer
                   width:(int)width
                  height:(int)height {
  std::lock_guard<std::mutex> lock(_mutex);
  [self ensureBuffer:width height:height];
  if (!_pixelBuffer) return;

  CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
  uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(_pixelBuffer);
  size_t dstStride = CVPixelBufferGetBytesPerRow(_pixelBuffer);
  const uint8_t *src = (const uint8_t *)buffer;
  size_t srcStride = (size_t)width * 4;
  for (int y = 0; y < height; ++y) {
    memcpy(dst + y * dstStride, src + y * srcStride, srcStride);
  }
  CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
}

// GPU 路径：把 CEF 交付的 IOSurface 直接包成 CVPixelBuffer 呈现（零拷贝）。
// CVPixelBufferCreateWithIOSurface 会持有该 IOSurface；我们仅保留「最新一帧」，
// 上一帧的 CVPixelBuffer 释放时其对 IOSurface 的引用一并释放，交还 CEF 帧池复用。
// 参考 webview_cef：呈现共享纹理本身而非再拷贝；CEF 帧池有多块 surface 轮转，
// 呈现最近一块通常不撕裂。若个别机型出现撕裂/花屏，可改为 Metal blit 到自有纹理。
- (void)updateWithIOSurface:(IOSurfaceRef)ioSurface
                     width:(int)width
                    height:(int)height {
  if (!ioSurface) return;
  NSDictionary *attrs = @{
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  CVPixelBufferRef pb = nullptr;
  CVReturn r = CVPixelBufferCreateWithIOSurface(
      kCFAllocatorDefault, ioSurface, (__bridge CFDictionaryRef)attrs, &pb);
  if (r != kCVReturnSuccess || !pb) return;

  std::lock_guard<std::mutex> lock(_mutex);
  if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
  _pixelBuffer = pb;  // 持有；copyPixelBuffer 再 +1 retained 交给 Flutter
  _width = width;
  _height = height;
}

// FlutterTexture：返回 +1 retained 的 CVPixelBuffer。
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  std::lock_guard<std::mutex> lock(_mutex);
  if (!_pixelBuffer) return nullptr;
  return CVPixelBufferRetain(_pixelBuffer);
}

@end
