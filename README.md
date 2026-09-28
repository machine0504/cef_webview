# cef_webview

Flutter 桌面端内嵌浏览器。基于 CEF 144 离屏渲染，把页面画到 Flutter `Texture` 上。支持 Windows、macOS、Linux（x86_64 与 arm64）。

## 环境

- Flutter 3.13+
- 桌面端。不支持 iOS / Android。
- 按 [docs/BUILD_CEF.md](docs/BUILD_CEF.md) 准备 CEF 运行时。二进制不在本仓库里。

## 接入

```yaml
dependencies:
  cef_webview:
    git:
      url: https://github.com/machine0504/cef_webview.git
```

```dart
import 'package:cef_webview/cef_webview.dart';

await CefWebViewManager.instance.initialize();

CefWebView(
  initialUrl: 'https://flutter.dev',
)
```

Linux 必须在进程很早的时候初始化 CEF，见 `docs/RUNTIME_HOSTING.md`。macOS 需要按文档把 CEF 辅助进程放进 App 包并签名。

示例：

```bash
cd example
flutter run -d macos
```

## 链接白名单

`whitelist` 只放你自己的域名，例如 `['example.com']`。不要把内部域名写进公开示例。
