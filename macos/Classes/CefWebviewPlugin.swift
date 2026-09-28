import Cocoa
import FlutterMacOS

public class CefWebviewPlugin: NSObject, FlutterPlugin {
  private let bridge: CefMacBridge

  init(bridge: CefMacBridge) {
    self.bridge = bridge
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "cef_webview",
      binaryMessenger: registrar.messenger)

    let bridge = CefMacBridge(
      registry: registrar.textures,
      channel: channel)

    // 主进程加载 CEF framework；子进程由独立 Helper 承载（见 PACKAGING.md）。
    _ = bridge.loadCefLibrary()

    let instance = CefWebviewPlugin(bridge: bridge)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // CefMacBridge 的 ObjC 选择器 handleMethodCall:result: 被 Flutter 的 apinotes
    // 重命名为 Swift 的 handle(_:result:)，故此处用桥接后的名字调用。
    bridge.handle(call, result: result)
  }
}
