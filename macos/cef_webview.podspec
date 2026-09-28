#
# cef_webview macOS 插件（CEF 99 + OSR）
#
# 构建前置（见 docs/BUILD_CEF.md / docs/PACKAGING.md）：把 CEF macOS 分发包内容放入 macos/cef/：
#   macos/cef/include/                                   ← CEF 头文件目录
#   macos/cef/Chromium Embedded Framework.framework      ← 来自分发包 Release/
#   macos/cef/libcef_dll_wrapper.a                       ← 用 cmake 预编译的包装库
#
Pod::Spec.new do |s|
  s.name             = 'cef_webview'
  s.version          = '1.0.0'
  s.summary          = 'CEF 99 OSR 内嵌浏览器（macOS）'
  s.description      = 'Off-Screen Rendering webview backed by CEF 99 for Flutter macOS.'
  s.homepage         = 'https://example.com'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'lzccb' => 'dev@lzccb.com' }
  s.source           = { :path => '.' }

  s.platform         = :osx, '10.13'
  s.dependency 'FlutterMacOS'

  # CocoaPods 的 PathList 仅用 Dir.glob("**/*") 枚举 pod 根(macos/)内的文件，且不会
  # 进入“目录软链”，也不纳入根之外(../common)的文件——因此 ../common/** 或 common->../common
  # 目录软链都会被丢弃。但“文件软链”会被枚举，故在根内建实体目录 common/，放入指向跨端共享
  # 实现的文件软链，仅链 macOS 直链模型需要的 3 个核心 .cc（排除含 main() 的子进程入口
  # cef_subprocess_main.cc 与 Linux 引擎 C ABI cef_engine_api.cc）。各端共享头由 HEADER_SEARCH_PATHS 解析。
  # NOTE: keep this prepare_command ASCII-only and never let the helper script's
  # output reach CocoaPods. The script prints CJK progress text; if CocoaPods
  # captures non-ASCII bytes it raises
  #   Encoding::CompatibilityError - incompatible character encodings: UTF-8 and BINARY
  # so we redirect ALL of its stdout/stderr to a log file.
  s.prepare_command = <<-CMD
    # Self-heal CRLF: a CRLF script makes bash fail with "set: pipefail: invalid option name".
    perl -i -pe 's/\\r$//' "${PWD}/../tools/bootstrap_cef_macos.sh" 2>/dev/null || true
    # Auto-download macOS CEF SDK on first build if missing (idempotent, ~88MB).
    CEF_LOG="${TMPDIR:-/tmp}/cef_webview_bootstrap_macos.log"
    if ! bash "${PWD}/../tools/bootstrap_cef_macos.sh" > "$CEF_LOG" 2>&1; then
      echo "[cef_webview] CEF SDK bootstrap failed; see log: $CEF_LOG"
      exit 1
    fi
    rm -rf common && mkdir -p common
    for f in cef_browser_manager cef_webview_handler cef_webview_app; do
      ln -sfn "../../common/$f.cc" "common/$f.cc"
    done
  CMD

  s.source_files = 'Classes/**/*.{h,m,mm,swift}', 'common/*.cc'
  s.public_header_files = 'Classes/CefMacBridge.h', 'Classes/CefMacTexture.h'

  # 预编译 libcef_dll_wrapper 静态库：内含 cef_* C API 的「动态加载桩」，链接期即可解析，
  # 运行期再由 CefScopedLibraryLoader dlopen 真正的 framework。
  s.vendored_libraries  = 'cef/libcef_dll_wrapper.a'

  # 注意：不要用 vendored_frameworks 引入 "Chromium Embedded Framework.framework"。
  # 该 framework 名含空格，CocoaPods 会生成 `-framework Chromium Embedded Framework` 被拆词，
  # 导致链接报错（no such file: 'Embedded'/'Framework'）；且 OSR 模型本就不应在链接期链接它
  # （由 CefScopedLibraryLoader 运行期加载）。framework 进 .app/Contents/Frameworks 的「嵌入」
  # 属打包步骤（连同 4 个 Helper.app），见 docs/PACKAGING.md，与本插件的「编译/链接」无关。

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/cef"',          # 使 #include "include/cef_app.h" 可用
      '"$(PODS_TARGET_SRCROOT)/.."',           # 使 #include "common/cef_browser_manager.h" 可用（与 win/linux 一致）
      '"$(PODS_TARGET_SRCROOT)/../common"',
      '"$(PODS_TARGET_SRCROOT)/../common/include"',
    ].join(' '),
    # framework 在运行期由 CefScopedLibraryLoader 从 Contents/Frameworks 加载，
    # 这里不弱链接符号，避免主进程提前解析。
    # CEF 的 C API 符号（cef_string_* 等）由运行期 CefScopedLibraryLoader 动态加载的
    # framework 提供，链接期不链 framework，故用 -undefined dynamic_lookup 让这些符号
    # 延到运行期解析（mac 动态加载 CEF 的标准做法）。
    'OTHER_LDFLAGS' => '-framework CoreVideo -framework IOSurface -undefined dynamic_lookup',
  }
  s.swift_version = '5.0'
end
