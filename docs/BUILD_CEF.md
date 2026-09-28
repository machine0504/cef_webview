# CEF 144 三端编译 / 裁剪 / 产物说明

目标分支：`cef_binary_144.0.29+g0b1a012+chromium-144.0.7559.256`（Chromium 144.0.7559.256，CEF 分支号 **7559**）。

> 注：CDN 上 144.0.29 的短哈希是 `g0b1a012`，各端 `DownloadCEF.cmake` 已用正确值。
>
> ⚠️ CEF 99 → 144 的打包差异（已在脚本处理）：① `snapshot_blob.bin` 已并入 `v8_context_snapshot.bin`，不再单独分发；② Windows 新增 `dxcompiler.dll`/`dxil.dll`（D3D12 着色器编译）；③ 官方 minimal 包的 `libcef.so`(arm64) 带 debug_info 达 ~2.3GB，`make_cef_runtime.sh` 已加 `strip --strip-unneeded`，Linux 下载包由 ~554MB 降至 ~118MB。

有两条路线：

- **路线 A（推荐）：直接使用官方预编译分发包**——本插件 CMake/podspec 已支持自动下载或指定本地路径，零编译成本。
- **路线 B：自行从源码编译**——满足「自行编译适配三端架构 + 深度裁剪」的需求，但耗时长（单端数小时、磁盘 60GB+）。

> 大多数情况下建议路线 A；仅当需要剔除 Chromium 模块、定制 UA/特性、或做体积/合规裁剪时才用路线 B。

---

## 路线 A：使用官方预编译分发包

官方 CDN：`https://cef-builds.spotifycdn.com/index.html`（按 `144.0.29` 过滤）。

各端 minimal 包（仅 Release + Resources + wrapper 源码 + cmake，**不含示例**，体积最小）：

| 平台/架构 | 文件名 |
| --- | --- |
| Linux x86_64 | `cef_binary_144.0.29+g0b1a012+chromium-144.0.7559.256_linux64_minimal.tar.bz2` |
| Linux arm64 | `cef_binary_144.0.29+g0b1a012+chromium-144.0.7559.256_linuxarm64_minimal.tar.bz2` |
| Windows x86_64 | `cef_binary_144.0.29+g0b1a012+chromium-144.0.7559.256_windows64_minimal.tar.bz2` |
| macOS x86_64 | `cef_binary_144.0.29+g0b1a012+chromium-144.0.7559.256_macosx64_minimal.tar.bz2` |
| macOS arm64 | `cef_binary_144.0.29+g0b1a012+chromium-144.0.7559.256_macosarm64_minimal.tar.bz2` |

> URL 中的 `+` 需转义为 `%2B`（`DownloadCEF.cmake` 已自动处理）。

分发包解压后目录结构（关键）：

```
cef_binary_144.../
├── include/                 # CEF C++ 头文件
├── libcef_dll/              # libcef_dll_wrapper 源码（需编译为静态库）
├── Release/                 # 运行时库
│   ├── libcef.so / libcef.dll / Chromium Embedded Framework.framework
│   ├── libEGL.* libGLESv2.* libvk_swiftshader.* (vulkan)
│   ├── v8_context_snapshot.bin   # CEF 144 已并入 snapshot_blob.bin（后者不再单独存在）
│   └── (Windows: chrome_elf.dll d3dcompiler_47.dll dxcompiler.dll dxil.dll vulkan-1.dll ...)
├── Resources/
│   ├── icudtl.dat
│   ├── *.pak (chrome_100_percent / chrome_200_percent / resources)
│   └── locales/*.pak
└── cmake/ + CMakeLists.txt  # CEF 自带构建脚本（编译 wrapper）
```

### A.1 让插件自动下载（最省事）

无需手动操作：`linux/CMakeLists.txt`、`windows/CMakeLists.txt` 会调用 `download_cef(...)`
自动下载并解压到构建目录，随后编译 `libcef_dll_wrapper`。首次构建联网即可。

### A.2 指定本地 CEF（离线/已编译）

```bash
# Linux/Windows：构建时传入
flutter build linux --dart-define=... \
  ; # 通过 CMake 缓存：在 example 的 linux/ 下 cmake -DCEF_ROOT=/abs/cef_binary_144...
# 或导出环境变量
export CEF_ROOT=/abs/path/cef_binary_144.0.29+...._linux64_minimal
```

### A.3 编译 libcef_dll_wrapper（仅 macOS 需手动产出 .a）

Linux/Windows 由各端 `CMakeLists.txt` 通过 `add_subdirectory(${CEF_ROOT})` 自动编译。
macOS 走 CocoaPods，建议预先编译好静态库放入 `macos/cef/`：

```bash
cd $CEF_ROOT
mkdir build && cd build
cmake -G Ninja -DPROJECT_ARCH=arm64 -DCMAKE_BUILD_TYPE=Release ..   # x86_64 改 -DPROJECT_ARCH=x86_64
ninja libcef_dll_wrapper
# 产物：libcef_dll_wrapper/libcef_dll_wrapper.a
cp libcef_dll_wrapper/libcef_dll_wrapper.a "<plugin>/macos/cef/"
cp -R "$CEF_ROOT/Release/Chromium Embedded Framework.framework" "<plugin>/macos/cef/"
cp -R "$CEF_ROOT/include" "<plugin>/macos/cef/"
```

> 通用二进制（x86_64+arm64）：分别编译两份再 `lipo -create` 合并 `.a`，framework 同理用 `lipo` 合并其中的 dylib。

---

## 路线 B：从源码编译 CEF 144（含裁剪）

### B.1 准备 depot_tools

```bash
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH=$PATH:/abs/depot_tools
```

### B.2 拉取并编译（automate-git.py）

```bash
mkdir ~/code/cef && cd ~/code/cef
# 取 CEF 的 automate 脚本
wget https://bitbucket.org/chromiumembedded/cef/raw/master/tools/automate/automate-git.py

python3 automate-git.py \
  --download-dir=$PWD/chromium_git \
  --branch=7559 \
  --minimal-distrib \
  --client-distrib \
  --force-clean \
  --x64-build            # Windows/Linux x86_64；macOS/Linux arm64 用 --arm64-build
```

- `--branch=7559` 对应 Chromium 144.0.7559.x（即本插件目标）。
- `--minimal-distrib --client-distrib` 直接产出可用分发包到 `chromium_git/chromium/src/cef/binary_distrib/`。
- 三端在各自原生系统上编译（Windows 用 VS2022、macOS 用 Xcode 命令行、Linux 用 clang）。

### B.3 GN 编译参数（Release + 裁剪）

可通过 `GN_DEFINES` 环境变量传入（automate 会透传）：

```bash
export GN_DEFINES="\
 is_official_build=true \
 is_debug=false \
 symbol_level=0 blink_symbol_level=0 \
 dcheck_always_on=false \
 enable_nacl=false \
 use_thin_lto=true \
 proprietary_codecs=false ffmpeg_branding=Chromium \
 enable_widevine=false \
 enable_print_preview=false \
 enable_pdf=false"
```

**裁剪要点（按需取舍）：**

| 目标 | 参数 / 做法 |
| --- | --- |
| 关闭调试符号、精简体积 | `symbol_level=0 blink_symbol_level=0`、`is_official_build=true`、strip |
| 剔除专有音视频编码（合规/体积） | `proprietary_codecs=false ffmpeg_branding=Chromium`（不支持 H.264/AAC） |
| 剔除 PDF / 打印预览 | `enable_pdf=false enable_print_preview=false` |
| 剔除 Widevine DRM | `enable_widevine=false` |
| 剔除 NaCl | `enable_nacl=false` |
| 体积进一步压缩 | 链接期 `use_thin_lto=true`；分发后 `strip` 掉 `libcef.so` 调试段 |
| 仅保留所需语言包 | 删除 `Resources/locales/` 中除 `zh-CN.pak`、`en-US.pak` 外的 `.pak`（见各端 CMake 的 `CEF_LOCALES`） |

> ⚠️ OSR 离屏渲染必须保留 GPU/SwiftShader 相关库（`libvk_swiftshader`、`libGLESv2`、`libEGL`），
> 不要为了减体积删除它们，否则 Linux 下软件回退渲染会失败。

### B.4 三端架构注意

- **Windows x86_64**：VS2022 + Windows 10/11 SDK；CEF 默认动态 CRT（`/MD`），与 Flutter 一致（见 `windows/CMakeLists.txt` 已 `set(CEF_RUNTIME_LIBRARY_FLAG "/MD")`）。
- **macOS x86_64 / arm64**：分别 `--x64-build` / `--arm64-build`；通用包用 `lipo` 合并。
- **Linux x86_64 / arm64**：使用 CEF 提供的 sysroot（`use_sysroot=true`，默认）以兼容旧 glibc（统信 UOS V20、麒麟、Ubuntu 18.04+）；开启 GTK 兼容（CEF 144 Linux 默认 X11/GTK3）。CEF 144 官方 arm64 包 `libcef.so` 仅需 GLIBC_2.25、GL 库 ≤2.17，均 ≤ UOS/麒麟的 2.28，无需 glibc 补丁。

---

## 产物校验

编译/下载完成后，确认 `Release/` 含 `libcef.{so,dll}` 或 framework、`*.bin`，`Resources/` 含 `icudtl.dat` 与 `*.pak`。
打包分发见 `PACKAGING.md`。
