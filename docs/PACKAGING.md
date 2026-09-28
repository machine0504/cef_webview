# 三端打包部署

CEF 运行时（库 + 资源 + 子进程）必须随应用一起分发，并放到插件代码约定的相对路径。
下表为各端运行期查找路径（与 `cef_browser_manager` / 各端插件代码一致）：

| 平台 | libcef | 资源(*.pak/icudtl.dat/*.bin) | locales | 子进程 |
| --- | --- | --- | --- | --- |
| Linux | `bundle/lib/libcef.so` | `bundle/lib/` | `bundle/lib/` | `bundle/lib/cef_webview_subprocess` |
| Windows | `runner 同目录\libcef.dll` | exe 同目录 | exe 同目录 | `exe 同目录\cef_webview_subprocess.exe` |
| macOS | 运行期下载目录内 `Chromium Embedded Framework.framework`（见 RUNTIME_HOSTING.md） | framework/Resources | framework/Resources | `.app/Contents/Frameworks/<App> Helper*.app` |

各端 `CMakeLists.txt` 的 `cef_webview_bundled_libraries` 已声明需要随包复制的文件，
`flutter build` 会自动将其复制到上表位置；**locales 只默认带 `zh-CN.pak`、`en-US.pak`**，按需增删。

---

## 一、Linux

### 1.1 构建

```bash
cd example
flutter build linux --release
# 产物：build/linux/x64/release/bundle/
#   ├── <app>                         # 可执行
#   ├── lib/libcef.so, *.pak, icudtl.dat, *.bin, cef_webview_subprocess, libcef_webview_plugin.so ...
#   └── data/flutter_assets/...
```

`rpath`：插件与 `cef_webview_subprocess` 均设为 `$ORIGIN`（它们与 `libcef.so` 同在 `lib/`），无需 `LD_LIBRARY_PATH`。

### 1.2 沙箱

本实现默认 `no_sandbox=true`，分发最简单。如需启用 SUID sandbox：

```bash
# 需将 chrome-sandbox 复制到 lib/ 并设置 root:root + 4755
sudo chown root:root bundle/lib/chrome-sandbox
sudo chmod 4755 bundle/lib/chrome-sandbox
```
并把 `CefBrowserManager::Initialize` 中 `settings.no_sandbox` 改为 `false`。打包为 deb/AppImage 时该权限较难维持，桌面内网应用通常保留 `no_sandbox=true`。

### 1.3 系统依赖（统信 UOS / Ubuntu）

CEF 144 Linux 依赖以下系统库（用 sysroot 编译可显著降低 glibc 要求）：

```bash
# Debian/UOS/Ubuntu
sudo apt install -y libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
  libcups2 libdrm2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
  libgbm1 libxkbcommon0 libpango-1.0-0 libcairo2 libasound2 libgtk-3-0
```

> 缺库的典型报错与定位方式见 `LINUX_TROUBLESHOOTING.md`。

### 1.4 制作安装包

- **AppImage**：用 `appimagetool` 打包整个 `bundle/`，`AppRun` 指向 `<app>`。
- **deb**：将 `bundle/` 安装到 `/opt/<app>/`，desktop 文件指向可执行；依赖在 `Depends:` 中声明上面的库。

---

## 二、Windows

### 2.1 构建

```bash
cd example
flutter build windows --release
# 产物：build/windows/x64/runner/Release/
#   ├── <app>.exe
#   ├── libcef.dll, chrome_elf.dll, *.pak, icudtl.dat, *.bin, cef_webview_subprocess.exe
#   ├── cef_webview_plugin.dll, flutter_windows.dll ...
#   └── data/
```

所有 CEF 文件与子进程 exe 由 `bundled_libraries` 平铺复制到 `Release/`（与主 exe 同目录），即运行期查找路径。

### 2.2 运行时

- 需要 **VC++ 2015-2022 Redistributable (x64)**，安装包内置或引导安装。
- 若启用沙箱（默认关闭）需链接 `cef_sandbox.lib` 并 `static CRT`，与 Flutter 的 `/MD` 冲突，故本实现保持 `no_sandbox=true`。

### 2.3 制作安装包

- **Inno Setup / WiX(MSI)**：把 `Release/` 整个目录纳入安装；保持 CEF 文件与 exe 同级。
- **MSIX**：注意 MSIX 沙箱对子进程拉起的限制，建议先用 Inno/MSI 验证。

---

## 三、macOS（最复杂：需 Helper 应用）

CEF 在 macOS 用**多个 Helper 应用**承载子进程。需在 Flutter 的 macOS Runner 工程中新增 Helper target。

### 3.1 CEF 的获取（编译期 vs 运行期）

- 编译期（编译/链接插件）只需：
  ```
  macos/cef/include/                  # CEF 头文件
  macos/cef/libcef_dll_wrapper.a      # 预编译静态库（含 cef_load_library 等桩）
  ```
- 运行期 framework **不随 App 打包**：`Chromium Embedded Framework.framework` 改为运行期
  从自有服务器按架构下载到用户数据目录，由 `cef_load_library` 加载。
  见 [RUNTIME_HOSTING.md](RUNTIME_HOSTING.md)。

### 3.2 在 Xcode 新增 4 个 Helper target

CEF 144 需要 4 个 Helper（主、GPU、Plugin、Renderer），可执行均由本插件的
`common/cef_subprocess_main.cc` 编译而来（薄壳，不含 CEF；其 macOS 分支用
`cef_load_library` 从下载目录加载 framework）。

命名（与 `CefMacBridge.mm` 中 `subprocess_path` 对应，默认查找 `cef_webview Helper`）：

```
<App> Helper.app            (com.example.app.helper)
<App> Helper (GPU).app      (com.example.app.helper.gpu)
<App> Helper (Plugin).app   (com.example.app.helper.plugin)
<App> Helper (Renderer).app (com.example.app.helper.renderer)
```

> 若 Helper 名与 App 不同，请把 `CefMacBridge.mm` 中的 `helper` 路径改成实际名称，或改用 CEF 默认 `<MainApp> Helper` 命名约定并清空 `subprocess_path`。

每个 Helper target 配置：
- Build Phase：编译 `common/cef_subprocess_main.cc`，链接 `libcef_dll_wrapper.a`
  （提供 `cef_load_library` / `CefExecuteProcess` 桩）。**不再**链接 framework——运行期由
  `cef_load_library` 加载下载目录里的 framework。
- `Info.plist`：`LSUIElement=YES`，唯一 `CFBundleIdentifier`。
- Entitlements：`CODE_SIGN_ENTITLEMENTS` 指向 `Runner/CefHelper.entitlements`
  （含 `disable-library-validation`、sandbox `inherit` 等）。

### 3.3 嵌入与签名

- framework **不内嵌**：运行期下载到用户数据目录，主进程与各 Helper 均以
  `cef_load_library` 加载。因其非本 App 签名，主 App 与各 Helper 都需 entitlement
  `com.apple.security.cs.disable-library-validation`（主 App 见
  `Runner/{DebugProfile,Release,RunnerDebug}.entitlements`；Helper 见
  `Runner/CefHelper.entitlements`）。
- `Frameworks/` 仅内嵌 4 个 Helper.app（Runner 工程 "Copy Files (Frameworks)" 阶段）。
- 逐个 `codesign` 并对外分发需 **公证（notarize）**；签名顺序：先 Helper，再主 App。
- 下载所得 framework 由 App 内 `NSURLSession` 写入，默认无 quarantine，可被正常 dlopen。

### 3.4 构建

```bash
cd example && flutter build macos --release
```

---

## 四、（可选）真正的独立系统窗口（多窗口）

当前 `CefBrowserWindow` 以全屏路由呈现。若要像微信那样开**独立 OS 窗口**：

1. 引入 `desktop_multi_window`；
2. 在新建的子窗口（独立 FlutterEngine）中挂载 `CefBrowserWindow`/`CefWebviewWidget`；
3. 因每个 FlutterEngine 都会注册一次本插件，`CefBrowserManager` 为进程级单例、`CefInitialize` 只会执行一次（幂等），多窗口可安全共用同一 CEF 运行时与 Cookie。

> 注意：多窗口下纹理注册表是每引擎独立的，`createBrowser` 必须在「要显示该纹理的那个引擎」对应的插件实例上调用。
