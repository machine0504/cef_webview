// Obj-C++ 桥：连接 Flutter(macOS) 与跨端共享的 C++ CEF 管理器。
#import <Foundation/Foundation.h>
#import <FlutterMacOS/FlutterMacOS.h>

NS_ASSUME_NONNULL_BEGIN

@interface CefMacBridge : NSObject

- (instancetype)initWithRegistry:(NSObject<FlutterTextureRegistry> *)registry
                         channel:(FlutterMethodChannel *)channel;

// 仅主进程调用：加载 CEF framework。返回 NO 表示当前进程是子进程或加载失败。
- (BOOL)loadCefLibrary;

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result;

@end

NS_ASSUME_NONNULL_END
