# Linux：CEF 进程初始化 / 依赖库 / 崩溃排查

Linux 是本插件最关键、坑最多的一端。本文覆盖进程模型、初始化时机、依赖库、典型崩溃与定位方法。

> ⚠️ **实测结论（务必先读）**：本插件在 Linux 已跑通，最终生效的关键解法（被实际崩溃逼出来的唯一可行解）
> 详见 `DEVELOPMENT_LOG.md` §3/§4。一句话摘要：
> 1. CEF 封装为独立 `libcef_webview_engine.so`，插件 `dlopen(RTLD_DEEPBIND)` 加载，与 Flutter engine
>    （亦基于 Chromium）做全局符号/分配器隔离，否则 `CefInitialize` 死锁。
> 2. `CefInitialize` 必须在 `runner main()` 第一行（单线程）调用（`cef_webview_plugin_pre_initialize`）。
> 3. browser 进程用 `nullptr` CefApp；JS 桥由 subprocess 承载。
> 4. rpath 必须是 `DT_RPATH`（`-Wl,--disable-new-dtags`）且指向含 `icudtl.dat` 的 `lib/`，否则 ICU 加载失败→网络服务无限崩溃。
> 5. 必须在 ext4 等本地盘运行（NTFS/exFAT(FUSE) 上 CEF `mmap` 会死锁）。
> 6. `copy_pixels` 不能返回 FALSE，创建纹理时预填一帧。
>
> 下文「多线程/初始化时机」等早期描述仅作背景，以 `DEVELOPMENT_LOG.md` 为准。

---

## 一、CEF 多进程模型与初始化时机

CEF 是多进程架构：**Browser 主进程 + Render 渲染进程 + GPU 进程 + Utility 进程**。
子进程通过「重新拉起一份可执行 + `--type=renderer/gpu/...`」创建。

### 为什么必须用独立子进程可执行（`cef_webview_subprocess`）

Flutter 插件在宿主 `main()` 启动后才被加载，**无法**在最早期调用 `CefExecuteProcess`。
若让 CEF 复用宿主可执行来拉子进程，会再次启动整个 Flutter 引擎而崩溃。
因此用一个极薄的 helper 可执行（`common/cef_subprocess_main.cc`）承载所有子进程，
并通过 `settings.browser_subprocess_path` 指向它。

### 初始化顺序（本插件实现）

1. Dart `CefWebview.ensureInitialized()` → Linux 插件 `initialize`；
2. 在 **Flutter 平台线程（GTK 主线程）** 上 `CefInitialize(...)`；
3. 该线程即成为 CEF 的 UI 线程，之后由 `g_timeout_add(16ms)` 定时 `CefDoMessageLoopWork()` 泵循环
   （外部消息泵，**不要**调用 `CefRunMessageLoop`，否则会阻塞 GTK 主循环）；
4. 强制 OSR（`SetAsWindowless` + `windowless_rendering_enabled=true`），
   避免 CEF 与 Flutter 争夺 X11 显示上下文 / 窗口焦点 / 子窗口层级。

> 关键约束：所有 `CefBrowserHost` 调用（输入、Resize、关闭）都在平台线程进行，与泵同线程，天然线程安全。

---

## 二、依赖库与定位

CEF 144 Linux 运行时依赖一组系统图形/基础库。**先用 `ldd` 体检**：

```bash
cd build/linux/x64/release/bundle/lib
ldd libcef.so | grep "not found"
```

常见缺失与安装（Debian/UOS/Ubuntu）：

```bash
sudo apt install -y libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
  libcups2 libdrm2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
  libgbm1 libxkbcommon0 libpango-1.0-0 libcairo2 libasound2 \
  libx11-xcb1 libxcb1 libgtk-3-0
```

- `libcef`、`cef_webview_subprocess`、插件 `.so` 的 `rpath` 均为 `$ORIGIN`，三者同处 `lib/`，无需 `LD_LIBRARY_PATH`。
- 若仍报找不到 `libcef.so`：确认它确实被复制进了 `bundle/lib/`（见 `PACKAGING.md`）。

---

## 三、典型崩溃 / 异常与解决

### 1) 启动即退出，日志：`Running without the SUID sandbox!`
- 现象：使用了沙箱但缺少 `chrome-sandbox` 或权限不对。
- 解决：保持 `no_sandbox=true`（默认）；或正确部署 `chrome-sandbox`（`root:root` + `4755`，见 PACKAGING）。

### 2) 找不到资源：`Check failed: ... icudtl.dat / .pak`
- 原因：`resources_dir_path` / `locales_dir_path` 指向错误。
- 解决：确认 `icudtl.dat`、`*.pak`、语言包都在 `bundle/lib/`（本实现把 resources_dir 与 locales_dir 都指向 `lib/`）。

### 3) 子进程拉起失败 / `--type=renderer` 进程立即退出
- 原因：`browser_subprocess_path` 不存在或无执行权限。
- 解决：确认 `bundle/lib/cef_webview_subprocess` 存在且 `chmod +x`；其 `rpath=$ORIGIN` 能找到同目录 `libcef.so`。

### 4) 页面白屏 / GPU 进程反复崩溃
- 原因：部分 Linux（虚拟机、老显卡、统信 UOS 某些驱动）GPU 合成不稳定。
- 解决：通过 `extraCommandLineSwitches` 走软件渲染兜底：

```dart
await CefWebview.ensureInitialized(const CefInitOptions(
  extraCommandLineSwitches: {
    'disable-gpu': '',
    'disable-gpu-compositing': '',
    'disable-software-rasterizer': '',     // 强制 SwiftShader
    'enable-begin-frame-scheduling': '',
  },
));
```
> 务必保留 `libvk_swiftshader.so` / `libGLESv2.so` / `libEGL.so`，否则软件渲染也会失败。

### 5) `X Error` / 多线程 X11 崩溃
- 原因：X11 未启用多线程，或 CEF 与 GTK 抢 X 上下文。
- 解决：已强制 OSR 规避大部分问题；如仍出现，可在 runner `main()` 最早处调用 `XInitThreads();`
  （Flutter Linux runner 的 `my_application.cc`）。

### 6) Wayland 下异常
- CEF 144 默认走 X11。Wayland 桌面（GNOME/KDE Wayland、部分 UOS）请通过 XWayland 运行：

```bash
GDK_BACKEND=x11 ./<app>
```
或在 runner 中 `gdk_set_allowed_backends("x11");`。

### 7) 退出时卡死 / 残留子进程
- 原因：未按序关闭。
- 本插件已实现：`shutdown` 时先 `CloseBrowser(force)` → 多次 `DoMessageLoopWork()` 让关闭流程跑完 → `CefShutdown()`。
- 应用退出前请调用 `await CefWebview.shutdown()`（或在最后一个窗口关闭时）。

### 8) 输入法（中文）无法组字
- 当前仅转发普通字符事件，未接 IME 合成。中文输入需接入
  `CefBrowserHost::ImeSetComposition / ImeCommitText`，可在 `cef_browser_manager` 扩展。

---

## 四、调试手段

- **远程调试**：初始化时设 `remoteDebuggingPort: 9222`，浏览器访问 `http://localhost:9222` 用 DevTools 调试 OSR 页面。
- **CEF 日志**：`logSeverity: CefLogSeverity.info`，日志默认输出到 `cache_path` 同级的 `debug.log`。
- **崩溃栈**：
  ```bash
  gdb --args ./<app>
  (gdb) run
  (gdb) bt        # 崩溃后看主进程栈
  ```
  子进程崩溃可加 `--enable-logging --v=1` 并查看 stderr。
- **核对进程**：`ps aux | grep cef_webview_subprocess` 应能看到 renderer/gpu 等子进程。
