// FlutterTexture 实现：用 CVPixelBuffer(32BGRA) 承载 CEF OSR 帧。
// - 软件路径（OnPaint）：CPU BGRA 缓冲 → CVPixelBuffer（每帧全画幅 memcpy）。
// - GPU 路径（OnAcceleratedPaint）：CEF 交付的 IOSurface 直接包成 CVPixelBuffer
//   （CVPixelBufferCreateWithIOSurface），零拷贝、跳过软件合成，复杂页面不掉帧。
#import <Foundation/Foundation.h>
#import <FlutterMacOS/FlutterMacOS.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

@interface CefMacTexture : NSObject <FlutterTexture>

@property(nonatomic, assign) int64_t textureId;

// 由 CEF UI 线程调用：提交一帧 BGRA 数据（软件 OnPaint 路径）。
- (void)updateWithBuffer:(const void *)buffer
                   width:(int)width
                  height:(int)height;

// 由 CEF UI 线程调用：提交一帧 GPU 共享纹理（OnAcceleratedPaint 路径）。
// 把 [ioSurface] 直接包成 CVPixelBuffer 呈现，无 CPU 拷贝。
- (void)updateWithIOSurface:(IOSurfaceRef)ioSurface
                     width:(int)width
                    height:(int)height;

@end

NS_ASSUME_NONNULL_END
