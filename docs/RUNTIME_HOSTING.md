# CEF 运行时自有服务器托管

本插件把 CEF 大体积运行时（`libcef` / framework / 资源）从「构建期打进安装包」改为
「运行期按平台-架构从自有服务器下载到用户数据目录」。本文说明**服务器要挂哪些文件**、
**目录结构**与**客户端契约**。

## 一、服务器要挂哪些文件

静态 HTTP 托管即可（OSS / Nginx / CDN 均可）。建议挂在某个基址下，例如
`https://<你们域名>/cef/`，目录结构：

```
cef/
├── manifest.json                                  # 版本与各包 url/size/sha256
└── 144.0.29-g0b1a012-chromium-144.0.7559.256/     # 版本目录（'+' 已换成 '-'）
    ├── windows-x64.tar.gz
    ├── linux-x64.tar.gz
    ├── linux-arm64.tar.gz
    ├── macos-arm64.tar.gz
    └── macos-x64.tar.gz
```

客户端会把上述基址（去掉 `manifest.json`）作为 `baseUrl`，再拼接 manifest 中各包的
相对 `url`。即客户端只需配置一个 `manifest.json` 的完整地址。

### 各包内容（由 `tools/make_cef_runtime.sh` 自动生成）

- windows-x64：`libcef.dll chrome_elf.dll libEGL.dll libGLESv2.dll vk_swiftshader.dll
  vulkan-1.dll d3dcompiler_47.dll vk_swiftshader_icd.json snapshot_blob.bin
  v8_context_snapshot.bin icudtl.dat chrome_100_percent.pak chrome_200_percent.pak
  resources.pak locales/{zh-CN,en-US}.pak` + `cef_webview_subprocess.exe`
- linux-x64 / linux-arm64：上述对应的 `.so` 版本 + `libcef_webview_engine.so` + `cef_webview_subprocess`（各自在对应架构机器上构建）
- macos-arm64 / macos-x64：`Chromium Embedded Framework.framework`（整包）

> `cef_webview_subprocess(.exe)` 与 `libcef_webview_engine.so` 是本插件自编、且与 CEF
> 版本绑定的产物，必须随对应版本的包一起发布。macOS 的 `libcef_dll_wrapper.a` 与 4 个
> `Helper.app` 是**编译期**产物，随 App 一起打包签名，不在下载包内（见 PACKAGING.md）。

## 二、制作与发布

```bash
# 0) 准备：解压官方 CEF 包到 third_party/cef/...，并各端构建出 subprocess / engine。
TP=third_party/cef
OUT=dist/cef

# macOS（两种架构各一份；分别在 arm64 / Intel 机器或交叉编译产出 framework）
tools/make_cef_runtime.sh --platform macos-arm64 \
  --cef-root "$TP/cef_binary_144.0.29+g0b1a012+chromium-144.0.7559.256_macosarm64_minimal" \
  --out "$OUT"
tools/make_cef_runtime.sh --platform macos-x64 \
  --cef-root "$TP/cef_binary_144.0.29+g0b1a012+chromium-144.0.7559.256_macosx64_minimal" \
  --out "$OUT"

# Windows（在 Windows 上构建出 cef_webview_subprocess.exe 后）
tools/make_cef_runtime.sh --platform windows-x64 \
  --cef-root "$TP/cef_binary_..._windows64_minimal" \
  --subprocess build/.../cef_webview_subprocess.exe \
  --out "$OUT"

# Linux x86_64（构建出 engine.so 与 subprocess 后）
tools/make_cef_runtime.sh --platform linux-x64 \
  --cef-root "$TP/cef_binary_..._linux64_minimal" \
  --engine build/.../libcef_webview_engine.so \
  --subprocess build/.../cef_webview_subprocess \
  --out "$OUT"

# Linux ARM64（统信/麒麟等国产 ARM；engine/subprocess 必须在 ARM64 机器上构建）
tools/make_cef_runtime.sh --platform linux-arm64 \
  --cef-root "$TP/cef_binary_..._linuxarm64_minimal" \
  --engine build/.../libcef_webview_engine.so \
  --subprocess build/.../cef_webview_subprocess \
  --out "$OUT"

# 把 dist/cef/ 整个目录上传到服务器对应基址即可。
```

## 三、manifest.json 格式

见 [tools/manifest.example.json](../tools/manifest.example.json)。字段：

- `cefVersion`：CEF 分支版本号；客户端内置的 `kExpectedCefVersion` 必须与之一致。
- `packages.<platform>.url`：相对 manifest 所在目录的下载路径。
- `packages.<platform>.size`：字节数（用于进度与校验）。
- `packages.<platform>.sha256`：解压前压缩包的 sha256，客户端校验通过才安装。

`<platform>` 取值：`windows-x64` `linux-x64` `linux-arm64` `macos-arm64` `macos-x64`。

## 四、客户端落地

- 落地目录（用户级，免管理员）：
  - macOS：`~/Library/Application Support/<app>/cef/<cefVersion>/`
  - Windows：`%APPDATA%\<app>\cef\<cefVersion>\`（ApplicationSupport）
  - Linux：`~/.local/share/<app>/cef/<cefVersion>/`
- 原子安装：下载到临时文件 → 校验 sha256 → 解压到临时目录 → 重命名到版本目录 → 写
  `.ready` 标记。命中 `.ready` 即视为就绪，直接加载，不再重复下载。
- 详见 [lib/src/cef_runtime_manager.dart](../lib/src/cef_runtime_manager.dart)。
