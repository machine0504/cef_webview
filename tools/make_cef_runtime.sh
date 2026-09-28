#!/usr/bin/env bash
#
# 制作 CEF「运行期下载包」并生成/更新 manifest.json。
#
# 背景：本插件把 CEF 大体积运行时（libcef / framework / 资源）改为「运行期按
# 平台-架构从自有服务器下载」。本脚本从官方 CEF 分发包的 Release/ 与 Resources/
# 提取运行期所需文件，并入我方自编的 subprocess（三端）/ engine（仅 Linux），
# 打成 <out>/<safeVer>/<platform>.tar.gz，并把 size/sha256 写入 <out>/manifest.json。
#
# 客户端（lib/src/cef_runtime_manager.dart）按自身平台-架构拉取 manifest.json、
# 下载对应包、校验 sha256、解压到用户数据目录后加载。
#
# 用法：
#   tools/make_cef_runtime.sh \
#     --platform   windows-x64|linux-x64|linux-arm64|macos-arm64|macos-x64 \
#     --cef-root   <解压后的官方 CEF 包目录(含 Release/ Resources/)> \
#     --out        <输出目录，即服务器根目录> \
#     [--subprocess <cef_webview_subprocess(.exe) 路径>] \
#     [--engine     <libcef_webview_engine.so 路径，仅 linux 需要>] \
#     [--cef-version <版本号，默认 144.0.29+g0b1a012+chromium-144.0.7559.256>]
#
# 示例（在本仓库根目录）：
#   TP=third_party/cef
#   tools/make_cef_runtime.sh --platform macos-arm64 \
#     --cef-root "$TP/cef_binary_144.0.29+g0b1a012+chromium-144.0.7559.256_macosarm64_minimal" \
#     --out dist/cef
#
set -euo pipefail

DEFAULT_CEF_VERSION="144.0.29+g0b1a012+chromium-144.0.7559.256"

PLATFORM=""
CEF_ROOT=""
OUT_DIR=""
SUBPROCESS=""
ENGINE=""
CEF_VERSION="$DEFAULT_CEF_VERSION"

err() { echo "[make_cef_runtime] 错误: $*" >&2; exit 1; }
log() { echo "[make_cef_runtime] $*"; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)    PLATFORM="${2:-}"; shift 2;;
    --cef-root)    CEF_ROOT="${2:-}"; shift 2;;
    --out)         OUT_DIR="${2:-}"; shift 2;;
    --subprocess)  SUBPROCESS="${2:-}"; shift 2;;
    --engine)      ENGINE="${2:-}"; shift 2;;
    --cef-version) CEF_VERSION="${2:-}"; shift 2;;
    -h|--help)     usage;;
    *) err "未知参数: $1";;
  esac
done

[[ -n "$PLATFORM" ]] || usage
[[ -n "$CEF_ROOT" ]] || err "缺少 --cef-root"
[[ -n "$OUT_DIR"  ]] || err "缺少 --out"
[[ -d "$CEF_ROOT" ]] || err "CEF 包目录不存在: $CEF_ROOT"

REL="$CEF_ROOT/Release"
RES="$CEF_ROOT/Resources"

# 跨平台 sha256
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  elif command -v shasum  >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else err "未找到 sha256sum / shasum"; fi
}

# 仅保留这两种语言包，按需增删（与各端 CMake 的 CEF_LOCALES 一致）。
LOCALES=("zh-CN.pak" "en-US.pak")

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

copy_in() { # copy_in <src> <dst-relative>
  local src="$1" dst="$STAGING/$2"
  [[ -e "$src" ]] || err "缺少文件: $src"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
}

case "$PLATFORM" in
  windows-x64)
    for f in libcef.dll chrome_elf.dll libEGL.dll libGLESv2.dll \
             vk_swiftshader.dll vulkan-1.dll d3dcompiler_47.dll \
             vk_swiftshader_icd.json v8_context_snapshot.bin; do
      copy_in "$REL/$f" "$f"
    done
    for f in icudtl.dat chrome_100_percent.pak chrome_200_percent.pak resources.pak; do
      copy_in "$RES/$f" "$f"
    done
    for l in "${LOCALES[@]}"; do copy_in "$RES/locales/$l" "locales/$l"; done
    [[ -n "$SUBPROCESS" ]] && copy_in "$SUBPROCESS" "cef_webview_subprocess.exe" \
      || log "警告: 未提供 --subprocess，包内将缺少 cef_webview_subprocess.exe"
    ;;
  linux-x64|linux-arm64)
    for f in libcef.so libEGL.so libGLESv2.so libvk_swiftshader.so \
             libvulkan.so.1 vk_swiftshader_icd.json \
             v8_context_snapshot.bin; do
      copy_in "$REL/$f" "$f"
    done
    # 裁剪调试符号：官方 minimal 包的 libcef.so 带 debug_info（arm64 实测 ~2.3GB），
    # 不 strip 时整包压缩后高达 ~550MB；strip --strip-unneeded 后 libcef.so 约 240MB、
    # 整包压缩降至 ~90-120MB。--strip-unneeded 仅移除调试/无用符号，保留 dlopen 运行所需
    # 的动态符号表，不影响加载与运行。只操作 STAGING 内的副本，不改动 SDK 源文件。
    if command -v strip >/dev/null 2>&1; then
      for so in libcef.so libEGL.so libGLESv2.so libvk_swiftshader.so libvulkan.so.1; do
        [[ -f "$STAGING/$so" ]] || continue
        before="$(wc -c < "$STAGING/$so" | tr -d ' ')"
        if strip --strip-unneeded "$STAGING/$so" 2>/dev/null; then
          after="$(wc -c < "$STAGING/$so" | tr -d ' ')"
          log "strip $so: $((before/1024/1024))MB -> $((after/1024/1024))MB"
        else
          log "警告: strip $so 失败，保留原文件"
        fi
      done
    else
      log "警告: 未找到 strip 工具，跳过符号裁剪（Linux 包会显著偏大 ~550MB）"
    fi
    if [[ "$PLATFORM" == "linux-arm64" ]]; then
      # CEF 144 官方 arm64 用较老 sysroot 编译：libcef.so 最高仅需 GLIBC_2.25、
      # GL 库仅 GLIBC_2.17，均 ≤ UOS V20 / 麒麟的 2.28，dlopen 不会失败，无需再
      # 降级（CEF 99 时其 libm@GLIBC_2.29 才需要 patch）。跳过 patch，省去对
      # ~2GB libcef.so 的逐字节处理。如换用引用了 >2.28 符号的 CEF 版本需恢复。
      log "CEF 144 arm64 glibc 需求 ≤2.25（GL 库 ≤2.17），跳过 glibc 兼容补丁"
    fi
    for f in icudtl.dat chrome_100_percent.pak chrome_200_percent.pak resources.pak; do
      copy_in "$RES/$f" "$f"
    done
    for l in "${LOCALES[@]}"; do copy_in "$RES/locales/$l" "locales/$l"; done
    [[ -n "$ENGINE" ]]     && copy_in "$ENGINE" "libcef_webview_engine.so" \
      || log "警告: 未提供 --engine，包内将缺少 libcef_webview_engine.so"
    [[ -n "$SUBPROCESS" ]] && copy_in "$SUBPROCESS" "cef_webview_subprocess" \
      || log "警告: 未提供 --subprocess，包内将缺少 cef_webview_subprocess"
    ;;
  macos-arm64|macos-x64)
    # 整个 framework（含其内部 Resources/ 与 Libraries/*.bin、locales 等）。
    copy_in "$REL/Chromium Embedded Framework.framework" "Chromium Embedded Framework.framework"
    ;;
  *) err "未知平台: $PLATFORM（应为 windows-x64|linux-x64|linux-arm64|macos-arm64|macos-x64）";;
esac

# 安全版本目录名：URL/路径里避免 '+'。
SAFE_VER="${CEF_VERSION//+/-}"
PKG_REL="$SAFE_VER/$PLATFORM.tar.gz"
PKG_ABS="$OUT_DIR/$PKG_REL"
mkdir -p "$(dirname "$PKG_ABS")"

log "打包 $PLATFORM -> $PKG_ABS"
# -C 进 staging 打包，保留符号链接（framework 内部含 symlink）。
tar -czf "$PKG_ABS" -C "$STAGING" .

SIZE="$(wc -c < "$PKG_ABS" | tr -d ' ')"
SHA="$(sha256_of "$PKG_ABS")"
log "size=$SIZE sha256=$SHA"

# 更新/创建 manifest.json
MANIFEST="$OUT_DIR/manifest.json"
python3 - "$MANIFEST" "$CEF_VERSION" "$PLATFORM" "$PKG_REL" "$SIZE" "$SHA" <<'PY'
import json, os, sys
manifest, ver, platform, url, size, sha = sys.argv[1:7]
data = {"cefVersion": ver, "packages": {}}
if os.path.exists(manifest):
    with open(manifest, "r", encoding="utf-8") as f:
        data = json.load(f)
# 版本变化时重置 packages，避免新旧版本混在一起。
if data.get("cefVersion") != ver:
    data = {"cefVersion": ver, "packages": {}}
data.setdefault("packages", {})[platform] = {
    "url": url, "size": int(size), "sha256": sha,
}
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print("[make_cef_runtime] 已更新 " + manifest)
PY

log "完成。上传 $OUT_DIR 整个目录到服务器即可。"
