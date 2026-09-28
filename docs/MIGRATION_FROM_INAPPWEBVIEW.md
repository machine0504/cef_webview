# 桌面端 WebView 迁移方案：flutter_inappwebview / native_webview → cef_webview

> 目标：把桌面端（Windows / macOS / Linux）所有内嵌网页从 **WebView2 / 系统 WebView** 迁移到自研 **`cef_webview`（CEF 144 + OSR + Texture）**，统一为单一 Chromium 内核。

状态：进行中（本文件随迁移推进持续更新）。
负责：报告助手页已作为 CEF 参考实现完成。

### 已确认决策（2026-05-30）
- **范围**：`flutter_inappwebview`(Stack A) 与 `native_webview`(Stack B) **都迁** → CEF，目标是彻底移除 WebView2。
- **Stack A 方式**：在 `webview_bridge` 内把 `UnifiedWebView` 底层换成 CEF（带 feature flag 可灰度/回退）。
- **起步**：先迁**工具箱**（与已完成的报告助手最像，复用桥协调器）。
- **Quill 笔记渲染器/编辑器**：**不走 CEF**，团队将改为**纯 Flutter 渲染**，已移出本迁移范围（原 Phase 3 取消）。

---

## 1. 背景与动机

### 1.1 现状：桌面端同时存在三套 WebView

| 栈 | 载体 | Windows 实际内核 | 使用方 |
|----|------|------------------|--------|
| **A** | `webview_bridge` 的 `UnifiedWebView`（内部用 `flutter_inappwebview` 6.2.0-beta.2 / `flutter_inappwebview_windows` 0.7.0-beta.2） | **WebView2** | Quill 富文本编辑器、文件预览(OnlyOffice)、新闻预览、公告 |
| **B** | `native_webview`（HWND/NSView/GTK 原生悬浮窗覆盖） | **WebView2** | 工具箱 toolbox（+ 上传/下载/嵌入桥协调器） |
| **C** | `cef_webview`（OSR 离屏渲染 → Flutter `Texture`） | **CEF 144** | 报告助手（已迁移，参考实现） |

### 1.2 为什么要迁移（关键动机）

- **消除双内核共存导致的“无响应”**：主工程里 Stack A、Stack B 都把 **WebView2** 加载进同一个进程，而报告助手又加载 **CEF**。两个 Chromium 内核（各自带 ANGLE 的 `libEGL.dll`/`libGLESv2.dll`、GPU/合成线程）在同进程共存，是主工程“loading 一点点后无响应”的最大嫌疑。
  - 佐证：`package/cef_webview/example` 单独跑 CEF（最大化窗口 + 持续全屏动画）**全程响应、不卡死**；问题只在“CEF + WebView2 共存”的主工程出现。
- **统一与可控**：三套内核 → 一套 CEF，版本、能力、调试（remote-debugging）、分发全部统一；不再依赖系统/运行时 WebView2。
- **能力一致**：Linux 端已用 CEF，桌面三端统一后行为一致。

> ⚠️ 重要范围提示：用户最初表述为“替换 flutter_inappwebview”，但**只换 Stack A 并不能消除 WebView2**——工具箱的 `native_webview`(Stack B) 在 Windows 上同样是 WebView2。**要真正解决无响应，必须把 Stack A 和 Stack B 都迁到 CEF**，本方案两者都覆盖。

---

## 2. 目标架构

### 2.1 核心决策：在 `webview_bridge` 内把 `UnifiedWebView` 改由 CEF 实现

Stack A 的 4 个使用方都只依赖 `webview_bridge` 暴露的 **`UnifiedWebView` / `UnifiedWebViewController`** API，并不直接 import `flutter_inappwebview`。因此**最优做法是：保持 `UnifiedWebView` 对外 API 不变，把其内部实现从 `flutter_inappwebview` 换成 `cef_webview`**。

收益：
- 4 个页面（Quill / 文件预览 / 新闻 / 公告）**几乎零改动**即可迁移。
- 单点替换、单点回归，风险集中可控。
- 保留 `UnifiedWebView` 的实例上限、最小化收缩等既有逻辑。

工具箱(Stack B) 则按报告助手范式，从 `native_webview` 悬浮窗改为 `CefWebviewWidget`（在组件树内渲染）。

```
┌─ 业务页面（不变 / 极小改动） ────────────────────────────┐
│  Quill编辑器 · 文件预览 · 新闻 · 公告      工具箱            │
│        │ UnifiedWebView API                │ CefWebviewWidget │
└────────┼───────────────────────────────────┼────────────────┘
         ▼ （改内部实现）                       ▼ （直接用）
   webview_bridge::UnifiedWebView ────────►  cef_webview
         （CEF 适配层）                      （CEF 144 + OSR + Texture）
```

### 2.2 `cef_webview` 现有 API（可直接复用）

- 初始化：`CefWebview.ensureInitialized(CefInitOptions(...))`
- 实例：`CefWebviewController.create({url,width,height,devicePixelRatio,settings})`
- 导航：`loadUrl / reload / stopLoad / goBack / goForward`
- JS：`evaluateJavascript(src)`（单向触发）、`addJavaScriptHandler(name,cb)` / `onJsMessage`（页面 `window.cefBridge.callHandler(name,payload)`）
- 视图/输入：`resize / setVisible / 鼠标 / 键盘 / IME / setFocus`
- 事件：`navigation`(ValueNotifier) · `onLoadError` · `onTitleChanged` · `onNewWindowRequested`
- Widget：`CefWebviewWidget(controller, placeholder)`；另有 `CefLinkInterceptor`、`CefBrowserWindow`

---

## 3. 能力差距（cef_webview 需补齐）

| # | 差距 | 现状 | 影响页面 | 处理方案 |
|---|------|------|----------|----------|
| **G1** | **加载 HTML 字符串** | cef 只能 `create({url})`/`loadUrl`；inappwebview 用 `htmlContent + baseUrl:about:blank` | Quill、文件预览、公告 | 给 `cef_webview` 增加 `loadHtmlString(html,{baseUrl})` 与 `create(html: ...)`：Dart 侧写临时文件并 `file://` 加载（参考报告助手 `_loadTestHtmlUrl`），或 `data:` URI。**纯 Dart 即可，无需改原生。** |
| **G2** | **本地资源访问** | Quill 模板引用本地 Quill JS/CSS | Quill | 优先**内联**资源进 HTML；若需外链则把资源与临时 HTML 同目录，`file://` baseUrl 解析。已在 init 开 `--allow-file-access-from-files`（确认 CEF 侧等价）。 |
| **G3** | **JS handler 返回值** | inappwebview `callHandler` 可向 JS 返回 Promise 结果；cef 的 `QueryHandler` 恒 `Success("")`（单向） | 需逐个审计 | 现有用法均为**单向 / requestId 回调**（Quill `getContent` 用 `requestId+contentResponse`）。保持单向即可；如确有需要再扩展 `cef_message_router` 支持异步返回。 |
| **G4** | **桥接函数名差异** | 页面/模板里有三种发消息写法：`flutter_inappwebview.callHandler`、`flutterBridge.sendMessage`、`chrome.webview.postMessage` | 文件预览(`flutterBridge.sendMessage`)、Quill(`callHandler`) | 注入**兼容垫片**（参考报告助手 `_kCompatShimJs`），把上述写法统一映射到 `window.cefBridge.callHandler`。垫片集中放进 `webview_bridge`。 |
| **G5** | **`evaluateJavascript` 返回值** | inappwebview 返回执行结果；cef 为 fire-and-forget | 确认无依赖 | 现有 Dart→JS 调用都不取返回值（主题注入、setContent、getContentWithCallback）。保持现状。 |
| **G6** | **`UnifiedWebView` 配套行为** | 实例上限 15、最小化收缩、透明背景、加载进度 | 全部 Stack A | 在 CEF 适配层重新实现：透明用 `CefBrowserSettings.transparent`；最小化用 `setVisible(false)`；上限沿用现有计数。 |

> 设计原则：**优先在 `cef_webview` 补通用能力（G1/G3）**，让它成为完整内嵌浏览器；页面级差异（G4 垫片、G6 行为）放进 `webview_bridge` 适配层。

---

## 4. 分阶段迁移计划（按风险从低到高）

### Phase 0 — 基础设施（不动业务页面）
- **0.1** `cef_webview` 增加 `loadHtmlString(html,{baseUrl})` 与 `create(html:...)`（临时文件 + `file://`）。【G1】
- **0.2** `cef_webview` 增加/集中通用兼容垫片常量（`flutter_inappwebview.callHandler` / `flutterBridge.sendMessage` / `chrome.webview.postMessage` → `cefBridge.callHandler`），可由适配层注入。【G4】
- **0.3** 在 `webview_bridge` 新增一个 **CEF 后端**实现（与现 `flutter_inappwebview` 后端并存，feature flag 切换），实现 `UnifiedWebView` / `UnifiedWebViewController` 的全部对外 API（htmlContent/url/settings/onPageStarted/onPageFinished/onError/onLoaded/jsHandlers/onExecuteJavaScript/onWebViewMessage/evaluateJavascript）。【G6】
- 验收：`cef_webview/example` 加一个“加载 HTML 字符串”用例，三端可渲染。

### Phase 1 — 低风险页面（验证 CEF 后端的 UnifiedWebView）
- **1.1** 新闻预览 `news_preview_page.dart`：纯 URL + 生命周期回调（最简单）。
- **1.2** 公告 `announcement_content_widget.dart`：静态 HTML 片段，几乎无 JS 桥。
- 验收：新闻能加载远程页、公告能渲染富文本片段、内外网图片地址重写正常。

### Phase 2 — 文件预览（OnlyOffice）
- **2.1** `file_preview_widget.dart` + `file_preview_template.dart`：修正桥接（`flutterBridge.sendMessage` → 垫片 → `cefBridge`），保证 `documentReady`/`error` 回到 Dart；主题注入用 `evaluateJavascript`；远程 OnlyOffice 脚本/文件 URL 验证可加载。
- 验收：Office 文档预览、水印、禁用下载/打印、主题切换。

### Phase 3 — Quill 富文本编辑器 ❌ 已移出范围
笔记的**渲染器与编辑器**（`zd_quill_editor`）将由团队改为**纯 Flutter 渲染**，不再使用 WebView，因此**不在本次 CEF 迁移范围内**。
- 影响：去掉了原本最复杂的双向桥迁移。
- 注意：若“笔记内容渲染”有了纯 Flutter 实现，**公告页**（渲染 Quill HTML 片段）也可考虑改用同一渲染器；本方案暂仍按 CEF 处理公告，待团队确认。

### Phase 4 — 工具箱（native_webview → CEF）
- **4.1** `toolbox_page.dart`：从 `NativeWebviewController.show/updateBounds` 悬浮窗改为 `CefWebviewWidget`（组件树内，免 z-order/挖洞）。
- **4.2** 协调器 `host_web_file_upload_coordinator` / `host_web_file_download_coordinator` / `host_web_embed_bridge`：已具备 `withEval`/`deliverWith` CEF 适配，切到 CEF 的 `evaluateJavascript`/`onJsMessage`。
- 复用报告助手的下载（Dio + blob）、上传、嵌入上下文（token/用户/主题/权限）逻辑。
- 验收：工具箱页打开、`toolboxWebReady`、文件预览/上传/下载、Word 导出、可见性/模态切换。

### Phase 5 — 收尾与依赖清理
- **5.1** 移除依赖：`flutter_inappwebview*`、`native_webview`、（确认无用后）`webview_flutter*`、`webview_windows`、`webview_win_floating`。
- **5.2** WebView2 运行时检测/安装（`webview2_runtime_manager.dart`、`WebViewInitializer`）：WebView2 完全移除后可删；过渡期保留。
- **5.3** `main.dart` 的 `WebViewInitializer.initialize()` / `WebViewStateProvider` 按需调整为 CEF 初始化路径。
- **5.4** 删除/归档 `credit_template_page.dart` 中已注释的旧实现。

### Phase 6 — 三端验证
- Windows（重点：确认无响应消失、无 WebView2 进程）、macOS、Linux 全量回归各页面。
- 检查 `cef_cache`、`debug.log`、子进程数量、内存/CPU。

---

## 5. 风险与对策

| 风险 | 说明 | 对策 |
|------|------|------|
| Quill 双向桥复杂 | 10 handler + 频繁 Dart↔JS | 先在 example 复刻最小 Quill 用例打通桥，再接业务 |
| 本地资源/相对路径 | `file://` 下相对路径、CORS、`about:blank` 语义差异 | 资源内联优先；必要时临时目录同置资源 |
| OnlyOffice 远程脚本 | 远程 JS + 跨域 | 保留远程加载，CEF 默认允许；必要时加命令行开关 |
| OSR 输入/IME | 编辑器重度依赖键盘/IME/焦点 | cef_webview 已实现鼠标/滚轮/键盘/IME；Quill 阶段重点回归中文输入 |
| 性能（Debug） | OSR BGRA→RGBA 逐像素转换在 Debug 较慢 | 大窗口持续动画已验证仍响应；如需可后续上 SIMD/GPU 共享纹理优化 |
| 字体/媒体编解码 | CEF 自带编解码与系统不同 | 用 example 的“能力自动检测页”核对差异 |
| 回滚 | 迁移中途出问题 | Phase 0 用 feature flag 让 `UnifiedWebView` 可在 inappwebview/CEF 后端间切换，逐页灰度 |

---

## 6. 验证清单（每页通用）

- [ ] 页面加载（远程 URL / 本地 HTML）成功，无白屏
- [ ] JS → Dart 消息到达（各 handler）
- [ ] Dart → JS 调用生效（注入/主题/内容）
- [ ] 透明背景 / 缩放 / 右键菜单 行为符合预期
- [ ] 文件上传 / 下载链路通
- [ ] 中文 IME 输入（编辑器）
- [ ] 窗口最大化 / 最小化 / 多实例 不卡死
- [ ] 关闭页面后资源释放（无悬挂子进程）

---

## 7. 参考实现

- **URL + 下载 + 嵌入桥 + 垫片**：`desktop/lib/pages/home_page/report_assistant_page/report_assistant_page.dart`
- **CEF API**：`package/cef_webview/lib/src/cef_webview_controller.dart`、`cef_webview_widget.dart`
- **CEF 示例**：`package/cef_webview/example/lib/main.dart`（含能力自动检测页）
- **桥协调器（已 CEF 适配）**：`host_web_file_upload_coordinator.dart`、`host_web_embed_bridge.dart`
