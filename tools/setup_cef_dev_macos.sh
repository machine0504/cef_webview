#!/usr/bin/env bash
#
# macOS 本地 Debug 开发：从 third_party/cef 安装 CEF 运行时，并构建 4 个 Helper.app
# 嵌入到最近一次 flutter build/run 产出的 .app 中。
#
# 用法（仓库根目录）：
#   package/cef_webview/tools/setup_cef_dev_macos.sh
#   package/cef_webview/tools/setup_cef_dev_macos.sh --app /path/to/YourApp.app
#
set -euo pipefail

CEF_VERSION="144.0.29+g0b1a012+chromium-144.0.7559.256"
SAFE_VER="${CEF_VERSION//+/-}"
HELPER_BASE="cef_webview Helper"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLUGIN="$REPO_ROOT/package/cef_webview"
TP="$REPO_ROOT/third_party/cef"
COMMON="$PLUGIN/common"

RUNTIME_DIR="$HOME/Library/Application Support/cef_webview/cef/$SAFE_VER"
BUILD_DIR="/tmp/cef_webview_helpers_$$"
HELPER_ENT="$REPO_ROOT/desktop/macos/Runner/CefHelper.entitlements"

log() { echo "[setup_cef_dev_macos] $*"; }
err() { echo "[setup_cef_dev_macos] 错误: $*" >&2; exit 1; }

APP_BUNDLE=""
EMBED_ONLY=0
QUIET=0
RELEASE_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_BUNDLE="${2:-}"; shift 2;;
    --embed-only) EMBED_ONLY=1; shift;;
    --quiet) QUIET=1; shift;;
    --release) RELEASE_MODE=1; shift;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) err "未知参数: $1";;
  esac
done

_qlog() { [[ "$QUIET" == 1 ]] || log "$@"; }

# ---------- 1. 选择 CEF 包（按本机架构） ----------
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  CEF_PKG="$TP/cef_binary_${CEF_VERSION}_macosarm64_minimal"
else
  CEF_PKG="$TP/cef_binary_${CEF_VERSION}_macosx64_minimal"
fi
[[ -d "$CEF_PKG/Release/Chromium Embedded Framework.framework" ]] \
  || err "未找到 CEF framework: $CEF_PKG/Release/（请先解压 third_party/cef 对应包）"

# ---------- 2. 安装运行期 CEF 到 Application Support（Release/在线模式由 Dart 下载，此处跳过） ----------
FW_DST="$RUNTIME_DIR/Chromium Embedded Framework.framework"
if [[ "$RELEASE_MODE" == 1 ]]; then
  _qlog "Release/在线模式：跳过 Application Support 安装（由客户端 manifest 下载）"
elif [[ "$EMBED_ONLY" == 1 && -f "$RUNTIME_DIR/.ready" && -d "$FW_DST" ]]; then
  _qlog "跳过 Application Support 安装（已就绪）"
else
  log "安装 CEF 运行时 -> $RUNTIME_DIR"
  mkdir -p "$RUNTIME_DIR"
  FW_SRC="$CEF_PKG/Release/Chromium Embedded Framework.framework"
  FW_DST="$RUNTIME_DIR/Chromium Embedded Framework.framework"
  if [[ -L "$FW_DST" || -d "$FW_DST" ]]; then
    rm -rf "$FW_DST"
  fi
  cp -R "$FW_SRC" "$FW_DST"
  echo "$CEF_VERSION" > "$RUNTIME_DIR/.ready"
  _qlog "已写入 .ready 标记"
fi
FW_SRC="$CEF_PKG/Release/Chromium Embedded Framework.framework"

# ---------- 3. 编译 Helper 可执行文件（增量缓存） ----------
HELPER_CACHE="$REPO_ROOT/desktop/build/.cef_helper_cache/$HELPER_BASE"
HELPER_SOURCES=("$COMMON/cef_subprocess_main.cc" "$COMMON/cef_webview_app.cc")
need_build=1
if [[ -f "$HELPER_CACHE" ]]; then
  need_build=0
  for src in "${HELPER_SOURCES[@]}"; do
    if [[ "$src" -nt "$HELPER_CACHE" ]]; then need_build=1; break; fi
  done
  if [[ "$PLUGIN/macos/cef/libcef_dll_wrapper.a" -nt "$HELPER_CACHE" ]]; then
    need_build=1
  fi
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
if [[ "$need_build" == 1 ]]; then
  _qlog "编译 Helper 可执行文件（universal: arm64 + x86_64）..."
  # 与 universal App 一致编出双架构 Helper（libcef_dll_wrapper.a 已是 universal）。
  # 这样 Intel(x86_64) 与 Apple 芯片(arm64) 上各自的 App 都能拉起匹配架构的子进程。
  clang++ -std=c++17 -arch arm64 -arch x86_64 -O2 \
    -mmacosx-version-min=10.15 \
    -I"$CEF_PKG" -I"$COMMON" -I"$COMMON/include" \
    "${HELPER_SOURCES[@]}" \
    "$PLUGIN/macos/cef/libcef_dll_wrapper.a" \
    -framework Cocoa -framework CoreFoundation \
    -o "$BUILD_DIR/$HELPER_BASE"
  mkdir -p "$(dirname "$HELPER_CACHE")"
  cp "$BUILD_DIR/$HELPER_BASE" "$HELPER_CACHE"
else
  _qlog "复用 Helper 缓存"
  cp "$HELPER_CACHE" "$BUILD_DIR/$HELPER_BASE"
fi

# ---------- 4. 打包 4 个 Helper.app ----------
HELPER_NAMES=(
  "$HELPER_BASE"
  "$HELPER_BASE (GPU)"
  "$HELPER_BASE (Plugin)"
  "$HELPER_BASE (Renderer)"
)
HELPER_SUFFIXES=(helper helper.gpu helper.plugin helper.renderer)

make_helper_app() {
  local name="$1"
  local suffix="$2"
  local app_dir="$BUILD_DIR/${name}.app"
  local macos_dir="$app_dir/Contents/MacOS"
  mkdir -p "$macos_dir"
  cp "$BUILD_DIR/$HELPER_BASE" "$macos_dir/$name"
  chmod +x "$macos_dir/$name"
  cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>com.example.cef-webview.${suffix}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
}

for i in "${!HELPER_NAMES[@]}"; do
  make_helper_app "${HELPER_NAMES[$i]}" "${HELPER_SUFFIXES[$i]}"
done
log "已构建 ${#HELPER_NAMES[@]} 个 Helper.app"

# ---------- 5. 嵌入到 Debug .app ----------
if [[ -z "$APP_BUNDLE" ]]; then
  CANDIDATES=(
    "$REPO_ROOT/desktop/build/macos/Build/Products/Debug/"*.app
    "$REPO_ROOT/package/cef_webview/example/build/macos/Build/Products/Debug/"*.app
  )
  for c in "${CANDIDATES[@]}"; do
    if [[ -d "$c" ]]; then APP_BUNDLE="$c"; break; fi
  done
fi

if [[ -z "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
  log "未找到 Debug .app，Helper 已构建在 $BUILD_DIR"
  log "请先 flutter run/build macos，再执行："
  log "  $0 --app /path/to/YourApp.app"
  exit 0
fi

FW_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FW_DIR"

# 内嵌 framework 到 .app（Release 不内嵌，走运行期下载；Debug 内嵌便于本地开发）。
if [[ "$RELEASE_MODE" != 1 ]]; then
  _qlog "内嵌 CEF framework -> $FW_DIR"
  FW_EMBED="$FW_DIR/Chromium Embedded Framework.framework"
  rm -rf "$FW_EMBED"
  cp -R "$FW_SRC" "$FW_EMBED"
  codesign --force --sign - --deep "$FW_EMBED" >/dev/null 2>&1 || true
else
  _qlog "在线模式：不内嵌 framework，并移除 .app 内旧副本"
  rm -rf "$FW_DIR/Chromium Embedded Framework.framework"
fi

[[ -f "$HELPER_ENT" ]] || err "缺少 Helper entitlements: $HELPER_ENT"
# codesign 不接受 CRLF entitlements。
sed -i '' $'s/\r$//' "$HELPER_ENT" 2>/dev/null || true

# 签名身份：CefHelper.entitlements 用 sandbox `inherit`，要求 Helper 与主 App 由「同一
# Team」签名才能继承沙箱并加入主 App 的 App Group 作用域（ad-hoc 无法继承/授予 App Group）。
# Xcode 构建期会把真实身份放在 EXPANDED_CODE_SIGN_IDENTITY；本地裸跑无身份时回退 ad-hoc。
for name in "${HELPER_NAMES[@]}"; do
  dst="$FW_DIR/${name}.app"
  rm -rf "$dst"
  cp -R "$BUILD_DIR/${name}.app" "$dst"
  if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
      --entitlements "$HELPER_ENT" --options runtime --timestamp=none "$dst" \
      || codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        --entitlements "$HELPER_ENT" --options runtime "$dst"
  else
    codesign --force --sign - --entitlements "$HELPER_ENT" --options runtime "$dst"
  fi
done

_qlog "已将 framework + Helper 复制并签名到: $FW_DIR"
if [[ "$QUIET" != 1 ]]; then
  log ""
  log "完成。请重新启动 Debug 应用（若已在运行需完全退出后重开）。"
  log "CEF 运行时目录: $RUNTIME_DIR"
  log "验证: ls \"$FW_DIR/${HELPER_BASE}.app\""
fi
