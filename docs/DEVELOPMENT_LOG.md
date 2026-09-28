# cef_webview 开发与调试全记录（交接文档）

> 本文档面向「接手本插件的下一位开发者 / AI」。读完即可了解：插件是什么、最终架构为何如此、
> 调试中踩过哪些坑及其根因与解法、当前状态与待办、以及如何继续。
>
> 配套文档：`README.md`（用法/目录）、`BUILD_CEF.md`（CEF 编译/下载）、
> `PACKAGING.md`（打包）、`LINUX_TROUBLESHOOTING.md`（运行排错）。

---

> ⚠️ **更新提示**：本记录写于 Linux 跑通、Windows 尚未验证之时。此后 **Windows 也已跑通**
> （OSR 渲染、鼠标/键盘/滚轮、中文 IME 均通），且做了若干 Windows 专属修复（消息泵由 `WM_TIMER`
> 改为独立线程 `PostMessage`、BGRA→RGBA 改 SIMD、`CreateBrowserSync` 防重入、IME 可编辑几何修复等）。
> **Linux 与 Windows 的最新实现对照以 [`ARCHITECTURE.md`](ARCHITECTURE.md) 为准**；本文保留为调试踩坑史。

> ⚠️ **更新提示（2）— 宿主升级 Flutter 3.35 后的两处根因修复（最新一轮，三端统一）**。
> 细节与「为什么这么改」见 `ARCHITECTURE.md` §6 / §8。
>
> 1. **中文输入法成倍重复（`你好`→`你好你好`）/ 文本通道整条失效**——两个叠加根因：
>    - A：**Flutter 3.32+ 的 Windows 引擎要求 `TextInput.setClient` 携带 `viewId`**，缺失则原生抛
>      `Could not set client, view ID is null.`，文本输入通道整条挂掉（`updateEditingValue` 不再回调，
>      中文组字/上屏全收不到；英文当时只是靠 `_onKey` 的 KEYEVENT_CHAR 旁路“看起来能用”）。
>    - B：原先以 `TextInputClient`「全量回调」承接，为拿“单段文本”而在每次提交后 `setEditingState('')`
>      **重置引擎模型**，会在系统输入法组字途中打断组字区间 → 引擎模型错乱、中文成倍重复。
>    - **修复（根本解）**：`CefWebviewWidget` 改为 **`DeltaTextInputClient` + `enableDeltaModel: true`**，
>      把引擎下发的每条 `TextEditingDelta`（插入/替换/组字/删除）逐条翻译成 CEF 的
>      `imeSetComposition/imeCommitText/imeFinishComposing/imeCancelComposition`，**全程不再 `setEditingState`
>      重置模型**；连接带上 `viewId`；删除 Windows 专属 KEYEVENT_CHAR 旁路（可见字符统一走增量 → `imeCommitText`），
>      `inputType` 用 `text` 让回车只走 `_onKey`。**三端一套路径**（Win/Linux/macOS embedder 均已实现增量通道，
>      已核对源码）。单测见 `test/cef_webview_widget_test.dart`（39 项通过）。
> 2. **IDE 调试器（F5）一进 CEF 页就整窗「无响应」，但 `flutter run` 正常**——
>    - 根因：`CefInitOptions.logSeverity` 开成 `info`，Chromium 海量日志同步写进进程 stderr；调试器下 stderr 经
>      管道转发到 IDE「调试控制台」吞吐慢，缓冲填满即**阻塞写日志的平台线程**（含 CEF 泵）。`flutter run` 经
>      `AttachConsole(ATTACH_PARENT_PROCESS)` 直连终端控制台、吞吐快，故只在调试器复现；`example` 只加载本地小页
>      日志量小也不复现。
>    - 修复：宿主 `desktop/lib/main.dart` 把 `logSeverity` 降为 `warning`（亦为 `CefInitOptions` 默认值）。
>      该项改完需**完全停止后冷启动**（CEF 每进程只初始化一次，`ensureInitialized` 幂等）。

## 0. 一句话现状（截至本记录）

- **Linux：已完整跑通** ✅ —— 标准 `flutter build linux` 构建，CEF 99 OSR 渲染网页 → Flutter `Texture` 显示，
  CEF 多进程（browser/renderer/network/utility/storage/zygote）全部正常，零崩溃，鼠标/键盘/滚轮/触摸板/JS↔Dart 均通。
- **Windows：已跑通** ✅（见上方更新提示与 `ARCHITECTURE.md`）；**macOS：代码已就绪，尚未在真机验证**（架构与 Linux 不同，见 §9）。
- 调试期的临时日志已清理；示例 `example/` 首页含「链接拦截演示」+「本地 HTML 全面测试页」入口。

---

## 1. 这是什么

Flutter 桌面端（Win/macOS/Linux）内嵌浏览器插件，内核用 **CEF 99（Chromium Embedded Framework）离屏渲染（OSR）**。
解决 Flutter Linux 桌面无官方 WebView 的痛点，业务上对标微信桌面端「App 内点链接唤起自研内嵌浏览器」。

- CEF 版本：`99.2.14+g3f796b8+chromium-99.0.4844.84`（注意短哈希是 **g3f796b8**，不是需求文档里的 g50895d1）。
- 渲染：CEF `OnPaint` 输出 BGRA 帧 → 各端 Flutter 外部纹理 → `Texture` widget 显示。
- 通信：Dart ↔ C++ 用 `MethodChannel`；JS ↔ C++ 用 `CefMessageRouter`（`window.cefBridge`）。

---

## 2. 最终架构（Linux 跑通版）

```
Flutter 进程（单进程，含 Flutter engine —— 它本身也基于 Chromium）
│
├─ runner main()  ← 第一行调用 cef_webview_plugin_pre_initialize()（关键：必须在单线程早期）
│        │  dlopen("libcef_webview_engine.so", RTLD_NOW|RTLD_LOCAL|RTLD_DEEPBIND)
│        ▼
├─ libcef_webview_engine.so（独立 .so，DEEPBIND 隔离，内部 DT_NEEDED libcef.so）
│        ├─ CefInitialize（nullptr CefApp，windowless OSR，单线程+外部泵）
│        ├─ CefBrowserManager：CreateBrowserSync / 输入分发 / DoMessageLoopWork
│        └─ CefWebviewHandler(CefClient)：OnPaint(BGRA) → 回调插件
│                                          OnLoadError/OnTitleChange/... → 回调插件
│        ▲  通过 C 回调（CefwvCallbacks，见 common/cef_engine_api.h）与插件通信
├─ libcef_webview_plugin.so（Flutter 插件，正常链接 flutter，不链接 libcef）
│        ├─ 实现回调：create_texture/on_frame/dispose_texture（FlPixelBufferTexture）
│        ├─ 实现回调：on_loading_state/on_address/... → fl_method_channel_invoke_method
│        ├─ g_timeout_add(16ms) → cefwv_engine_pump()  （外部消息泵）
│        └─ method handler：把 Dart 调用转成 cefwv_engine_* 函数指针调用
│
└─ Dart 层（lib/）：CefWebview/Controller/Widget/LinkInterceptor/BrowserWindow
         │ MethodChannel "cef_webview"
         └ Texture(textureId) 显示 OSR 画面

另有子进程（CEF 多进程，由 lib/cef_webview_subprocess 承载，rpath=$ORIGIN 走 DT_RPATH）：
   renderer / network / storage / utility / zygote（in-process-gpu，无独立 GPU 进程）
```

**渲染数据流**：CEF UI 线程（=Flutter 平台线程，因外部泵在该线程）`OnPaint`(BGRA)
→ 引擎 `EngineTextureBridge::OnFrame` → C 回调 `on_frame` → 插件 `cb_on_frame`（BGRA→RGBA 写入 `CefFlTexture`）
→ `fl_texture_registrar_mark_texture_frame_available` → Flutter raster 线程 `copy_pixels` 取走 → GL 纹理 → 上屏。

---

## 3. 关键设计决策（为什么这么做）—— 接手必读

这些不是随意选择，而是被具体崩溃/死锁逼出来的唯一可行解：

1. **CEF 封装进独立 `libcef_webview_engine.so`，插件用 `dlopen(RTLD_DEEPBIND)` 加载。**
   - 原因：Flutter engine（`libflutter_linux_gtk.so`）本身基于 Chromium。若插件直接链接 `libcef.so`，
     两个 Chromium 运行时在同进程发生**全局符号/内存分配器（PartitionAlloc）冲突**，`CefInitialize`
     会在创建线程池前 `futex` 死锁（永不返回）。
   - `RTLD_DEEPBIND` 让引擎及其依赖的 `libcef` **优先解析自身作用域内符号**，与 Flutter 隔离。
   - 反例：用 `LD_PRELOAD libcef.so` 也能让 `CefInitialize` 成功，但它全局覆盖分配器，导致 Flutter 在
     `createBrowser` 时段错误（顾此失彼）。DEEPBIND 才是正解。
   - 引擎绝不触碰任何 Flutter 符号；所有 Flutter 纹理/通道操作通过 C 回调交还插件执行。

2. **`CefInitialize` 必须在 `runner main()` 第一行（进程仍单线程时）调用。**
   - 原因：CEF 在多线程进程里初始化会与已有线程/锁冲突。`pre_initialize` 拆出「只做 CefInitialize」，
     插件注册时再 `SetBridges` 提供纹理/事件桥。
   - 代价：此时 Dart 还没运行，所以 Dart 的 `CefInitOptions`（locale 等）在 Linux **被忽略**，
     `pre_initialize` 里用硬编默认值（locale=zh-CN 等）。这是已知限制（见 §7）。

3. **browser 进程使用 `nullptr` CefApp。**
   - 原因：在 DEEPBIND 加载的引擎库里实例化「多重继承的 `CefApp`」会在 `CefInitialize` 崩溃（SIGTRAP）。
   - JS 桥 / 渲染逻辑实际由独立 `cef_webview_subprocess` 的 `CefWebviewApp`（render 进程）承载，browser 进程不需要 CefApp。
   - 命令行开关（`--disable-gpu --in-process-gpu` 等）通过 `CefMainArgs(argv)` 注入（见 `cef_engine_api.cc` 的 `BuildMainArgs`）。

4. **软件渲染 + GPU 进程内化：`--disable-gpu --disable-gpu-compositing --in-process-gpu`。**
   - 原因：虚拟机/无独显环境下独立 GPU 子进程启动失败会触发 `FATAL: GPU process isn't usable`。

5. **`copy_pixels` 必须始终返回有效 buffer（不能返回 FALSE）。**
   - 原因：Flutter 3.35 的 `FlPixelBufferTexture::copy_pixels` 返回 FALSE/空 buffer 会让 engine 段错误。
   - 解法：创建纹理时**预填一帧透明像素**（`cb_create_texture`），首帧即有数据。
   - 另注意：Flutter 3.x 的 `copy_pixels` 是 **5 参签名**（无 `format`，缓冲按 RGBA 解释），不是旧版 6 参。

6. **rpath 必须是 `DT_RPATH`（加 `-Wl,--disable-new-dtags`）且指向 `lib/`。**
   - 原因：**CEF 内部查找 `icudtl.dat` 依赖可执行文件的 `DT_RPATH`**（现代默认的 `DT_RUNPATH` 不被它认）。
     找不到 ICU → 网络服务（utility）子进程无限崩溃重启 → 页面加载不了、无 OnPaint。
   - runner 与 subprocess 都加 `--disable-new-dtags`；subprocess/engine 用 `BUILD_WITH_INSTALL_RPATH TRUE`
     + `INSTALL_RPATH "$ORIGIN"`，确保 bundled 复制后的产物 rpath=`$ORIGIN`（=bundle/lib，含 libcef.so 与 icudtl.dat）。
   - 注意 `icudtl.dat` 在 CEF 包的 `Resources/`，运行时被打到 `lib/`；千万别让 rpath 指向只含 `libcef.so` 的 `Release/`。

7. **必须在 ext4 等本地文件系统运行，不能在 NTFS/exFAT(FUSE) 上跑。**
   - 原因：CEF 用 `mmap` 加载 `libcef.so`/V8 快照/`icudtl.dat`，在 FUSE/NTFS 上会**死锁**。
   - 本仓库工作区在 `/media/.../新加卷`（fuseblk），所以开发时把 bundle 复制到 `~/cefapp_run`（ext4）运行。

---

## 4. 调试历程：踩过的坑与解法（按发现顺序）

| 现象 | 根因 | 解法 / 涉及文件 |
|---|---|---|
| CEF 包 404 下不动 | 短哈希 `g50895d1` 错误；CDN 限速断流 | 实为 `g3f796b8`；`aria2c -x16 -c` 多连接断点续传。`*/cmake/DownloadCEF.cmake` |
| Dart 编译错误 | `gestures` 未 import / `copy_pixels` 6 参 / `WindowOpenDisposition` 多基类歧义 / 宏与导出 / unused-function / 枚举未导出 | 见 git 历史；`cef_webview_widget.dart`、`cef_webview_handler.*`、`linux/cef_webview_plugin.cc`、`lib/cef_webview.dart` |
| `CefInitialize` 任何模式都死锁（单线程 futex、线程池未建、无子进程） | Flutter engine 与 CEF 的 Chromium 全局冲突（PartitionAlloc/符号） | DEEPBIND 独立引擎库（§3.1）。验证方式：写脱离 Flutter 的纯 CEF 程序能 init，链接 flutter + 直接链 libcef 则死锁；DEEPBIND dlopen 引擎则成功 |
| 改 multi_threaded / single_process / 早期 init 仍死锁 | 同上（与线程/进程模型无关） | 同上，只有 DEEPBIND 解决 |
| DEEPBIND 后 `CefInitialize` SIGTRAP | (a) ICU 失败引发 CHECK；(b) 多重继承 CefApp | (a) 修 ICU rpath（§3.6）；(b) browser 用 nullptr app（§3.3） |
| `createBrowser` 后段错误 | `copy_pixels` 返回 FALSE | 预填首帧（§3.5） |
| 网络服务无限「Network service crashed」+「Couldn't mmap icu data file」 | subprocess 的 rpath 指向 `Release/`（无 icudtl.dat）且为 DT_RUNPATH | DT_RPATH + `$ORIGIN`（§3.6） |
| 触摸板双指滚动无效 | 桌面平台触摸板以 PanZoom 手势事件下发，而非 PointerScrollEvent | `cef_webview_widget.dart` 增加 `onPointerPanZoomStart/Update` 转滚轮 |

**重要二分手法（无 gdb 时定位）**：
- `cat /proc/<pid>/task/*/wchan` 看各线程内核等待点（futex/poll/do_wait），判断死锁类型。
- 写最小复现程序对比（纯 CEF vs 链接 flutter vs DEEPBIND）。
- 手编引擎 `.so` 绕过 CMake flags 做二分（命令见 §8）。

---

## 5. 文件结构与职责（关键文件）

```
common/                         跨端共享 C++（编进 engine.so 与 subprocess）
  cef_engine_api.h/.cc          ★ 引擎的纯 C 接口 + 回调结构（插件 dlopen 调用的边界）
  cef_browser_manager.h/.cc     CEF 初始化(nullptr app)/CreateBrowserSync/输入分发/泵；SetBridges/InitializeCef 拆分
  cef_webview_handler.h/.cc     CefClient：OSR(OnPaint/GetViewRect/GetScreenInfo)+各 Handler + JS 路由
  cef_webview_app.h/.cc         CefApp：命令行开关(disable-gpu/in-process-gpu)+渲染进程 JS 桥注入
  cef_subprocess_main.cc        子进程入口（CefExecuteProcess）
  include/cef_webview/          FlutterTextureBridge / CefEventSink 抽象（引擎内部用 Engine* 实现转发到 C 回调）
linux/
  cef_webview_plugin.cc         ★ 插件：dlopen(DEEPBIND)引擎 + CefFlTexture(FlPixelBufferTexture) + 回调实现 + 泵定时器
  include/.../cef_webview_plugin.h  导出 register / pre_initialize
  CMakeLists.txt                ★ engine.so / plugin / subprocess 三 target，DT_RPATH 设置，bundled_libraries
  cmake/DownloadCEF.cmake       下载/定位 CEF
windows/、macos/                各端实现（未真机验证，见 §9）
lib/                            Dart：manager/controller/widget/link_interceptor/browser_window/models
example/
  lib/main.dart                 首页(链接拦截演示+本地HTML按钮) + LocalHtmlPage + 全面测试 _testHtml
  linux/CMakeLists.txt          ★ 给 runner(BINARY_NAME) 加 -Wl,--disable-new-dtags（DT_RPATH）
  linux/runner/main.cc          ★ main() 第一行调用 cef_webview_plugin_pre_initialize()
```

---

## 6. 构建与运行（Linux）

```bash
# 1) CEF 二进制：首次构建会自动下载（aria2c/网络）；或手动指定
export CEF_ROOT=/abs/cef_binary_99.2.14+g3f796b8+chromium-99.0.4844.84_linux64_minimal

# 2) 构建
cd package/cef_webview/example
flutter build linux --debug          # 或 --release

# 3) ★ 必须在 ext4 运行（工作区在 NTFS/FUSE 会死锁）：复制 bundle 到 ext4
rm -rf ~/cefapp_run && cp -r build/linux/x64/debug/bundle ~/cefapp_run
cd ~/cefapp_run && DISPLAY=:0 ./cef_webview_example
```

验证渲染成功（无 gdb 时）：
```bash
ps -eo args | grep "[c]ef_webview_subprocess" | grep -oP 'type=\K[a-z-]+' | sort | uniq -c
# 期望看到 renderer/network/utility/storage/zygote，且无 "Network service crashed" 刷屏
```

---

## 7. 已知限制与待办（接手重点）

- [ ] **Windows / macOS 未真机验证**。它们当前是「插件直接链接 CEF」的常规写法（见各端目录）。
      若也出现与宿主 Chromium 冲突，需参考 Linux 做隔离；macOS 还需配 Helper 应用（见 PACKAGING.md）。
- [ ] **Dart `CefInitOptions` 在 Linux 被忽略**：因 `pre_initialize` 早于 Dart 运行，locale/cachePath/
      remoteDebuggingPort/extraSwitches 目前硬编在 `linux/cef_webview_plugin.cc::cef_webview_plugin_pre_initialize`。
      如需让 Dart 配置生效，可改为：runner 读环境变量 / 编译期常量 / 或在 pre_initialize 后用一个轻量 method 重配（部分项不可热改）。
- [ ] **`cef_engine_api` 的 `user_agent_suffix` / `log_severity` 暂未真正应用**（已留参数位）。
- [x] **中文 IME 组字已接通（三端）**：`CefBrowserHost::ImeSetComposition/ImeCommitText/ImeFinishComposingText`
      已接入；Dart 侧用 `DeltaTextInputClient`（增量模型）承接系统输入法。详见上方「更新提示（2）」与
      `ARCHITECTURE.md` §6。
- [ ] **`<select>` 下拉等 PET_POPUP 未合成**：`handler` 仅处理 `PET_VIEW`。需把 PET_POPUP 缓冲合成到主纹理上。
- [ ] **触摸板缩放(pinch)未实现**：当前只把 PanZoom 的 pan 转滚轮；`scale` 可映射为 Ctrl+滚轮缩放。
- [ ] **真实 https 网页 + 白名单链接拦截流程**未端到端验证（已实现 `CefLinkInterceptor`）。
- [ ] **触摸板滚动方向/速度**可能需按机器微调：见 `cef_webview_widget.dart` 的 `onPointerPanZoomUpdate`
      （目前 `-panDelta`，与鼠标滚轮一致取反）。
- [ ] 文档 `LINUX_TROUBLESHOOTING.md` 的「理论排错」可与本文实测根因进一步合并。

---

## 8. 调试工具与技巧（实测有效）

```bash
# 看线程卡在哪（无 gdb/ptrace 受限时最有用）
PID=$(pgrep -x cef_webview_exa | head -1)
for t in /proc/$PID/task/*; do echo "$(cat $t/comm) -> $(cat $t/wchan)"; done

# 确认可执行/库的 rpath 类型（必须是 RPATH，不是 RUNPATH）
readelf -d <文件> | grep -E "RPATH|RUNPATH"

# DevTools 远程调试（需 remote_debugging_port>0；当前默认 0）
curl -s http://localhost:9222/json/list | python3 -m json.tool

# 手编引擎 .so（绕过 CMake flags 快速二分；rpath 用 $ORIGIN + DT_RPATH）
CEF_ROOT=~/cef99/cef_binary_99.2.14+g3f796b8+chromium-99.0.4844.84_linux64_minimal
CM=<repo>/package/cef_webview/common
WRAP=<repo>/.../build/linux/x64/debug/cef/libcef_dll_wrapper/libcef_dll_wrapper.a
clang++ -shared -fPIC -std=c++17 \
  "$CM/cef_engine_api.cc" "$CM/cef_webview_app.cc" "$CM/cef_webview_handler.cc" "$CM/cef_browser_manager.cc" \
  -I"$CM" -I"$CM/include" -I"$CEF_ROOT" "$WRAP" ~/cefapp_run/lib/libcef.so -lpthread -ldl \
  -o ~/cefapp_run/lib/libcef_webview_engine.so -Wl,-rpath,'$ORIGIN' -Wl,--disable-new-dtags

# CEF 包断点续传下载（CDN 易断流）
aria2c -c -x16 -s16 --max-tries=0 -o cef.tar.bz2 \
  "https://cef-builds.spotifycdn.com/cef_binary_99.2.14%2Bg3f796b8%2Bchromium-99.0.4844.84_linux64_minimal.tar.bz2"
```

加临时日志的常用点（已清理，需要时再加）：
- 引擎：`cef_engine_api.cc` 的 `cefwv_engine_initialize` / `OnFrame`；`cef_browser_manager.cc::CreateBrowser` 各步。
- handler：`OnPaint`/`GetViewRect`。
- 插件：`method_call_cb` 入口、`cb_on_frame`、`copy_pixels`、`pump_cb`。

---

## 9. 三端差异说明（重要）

- **Linux**：本次深度适配的平台。关键全在「DEEPBIND 隔离 + 早期 init + DT_RPATH + 软件渲染 + 预填帧 + ext4」。
- **Windows**：`windows/` 用 `flutter::PixelBufferTexture` + `HWND_MESSAGE` 定时器泵，**插件直接链接 libcef**。
  Windows 的 Flutter engine 是否与 CEF 冲突未验证；若冲突，需类似 Linux 做 DLL 隔离（Windows 无 RTLD_DEEPBIND，
  但可用「单独 host 进程」或保证加载顺序/CRT 一致）。CEF Windows 用 `/MD` 已对齐。
- **macOS**：`macos/` 用 `CVPixelBuffer(32BGRA)` + `NSTimer` 泵 + `CefScopedLibraryLoader`。
  必须在 Xcode 配 4 个 Helper 应用 + framework 嵌入（见 PACKAGING.md）。macOS 不支持 multi_threaded_message_loop。

> 经验法则：凡是「宿主框架也基于 Chromium」的桌面端，CEF 共存的核心难点都是**全局运行时隔离**与**初始化时机**。
> Linux 的解法（独立 .so + DEEPBIND + 早期 init）是范式，移植到其他端时优先复用该思路。

---

## 10. 验收清单（判断是否「还活着」）

- [ ] `flutter build linux --debug` 成功，bundle/lib 下有 `libcef_webview_engine.so`、`cef_webview_subprocess`、
      `libcef.so`、`icudtl.dat`、`*.pak`。
- [ ] ext4 运行后日志**无** `Couldn't mmap icu data file` 致命循环、**无** `Network service crashed` 刷屏、**无**段错误。
- [ ] 点击示例「测试本地 HTML」后，窗口显示渲染页面（标题/动画/Canvas 在动），鼠标点击计数增加、键盘可输入、
      鼠标滚轮与触摸板可滚动、JS→Dart 消息在顶栏显示。
- [ ] `ps` 可见 renderer/network/utility/storage/zygote 子进程且稳定。
