#!/usr/bin/env bash
#
# Build-time CEF SDK bootstrap for Linux (linux64 / linuxarm64 minimal).
#
# Picks the package matching the current machine arch (uname -m):
#   - aarch64 / arm64  -> linuxarm64  (统信/麒麟等国产 ARM 机)
#   - otherwise        -> linux64
#
# If third_party/cef/cef_binary_${VERSION}_${PLATFORM}_minimal/ is missing, download
# from https://cef-builds.spotifycdn.com (or use a local archive), extract, validate,
# then install into third_party/cef/. Idempotent when already present.
#
# Intranet: copy the official .tar.bz2 once, then:
#   bootstrap_cef_linux.sh --archive /path/to/cef_binary_..._minimal.tar.bz2
# or:
#   CEF_SDK_ARCHIVE=/path/to/....tar.bz2 bootstrap_cef_linux.sh
#
# Manual:
#   package/cef_webview/tools/bootstrap_cef_linux.sh
#
set -eu

CEF_VERSION="144.0.29+g0b1a012+chromium-144.0.7559.256"

# Select the CEF distribution by current machine architecture.
_ARCH="$(uname -m)"
case "${_ARCH}" in
  aarch64|arm64) CEF_PLATFORM="linuxarm64" ;;
  *)             CEF_PLATFORM="linux64" ;;
esac
PKG_NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}_minimal"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TP_DIR="${REPO_ROOT}/third_party/cef"
PKG_DIR="${TP_DIR}/${PKG_NAME}"

ARCHIVE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ARCHIVE="${2:-}"; shift 2;;
    -h|--help)
      echo "Usage: bootstrap_cef_linux.sh [--archive /path/to/${PKG_NAME}.tar.bz2]"
      echo "  arch=${_ARCH} -> ${CEF_PLATFORM}"
      exit 0
      ;;
    *) echo "[bootstrap_cef_linux] unknown arg: $1" >&2; exit 1;;
  esac
done
[[ -n "$ARCHIVE" ]] || ARCHIVE="${CEF_SDK_ARCHIVE:-}"

log() { echo "[bootstrap_cef_linux] $*"; }

if [[ -f "${PKG_DIR}/include/cef_version.h" ]] \
   && [[ -f "${PKG_DIR}/Release/libcef.so" ]]; then
  log "already present: ${PKG_NAME} (skip)"
  exit 0
fi

TMP_DIR="${TP_DIR}/.bootstrap-$$"
EXTRACT_DIR="${TMP_DIR}/extract"
mkdir -p "${EXTRACT_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

if [[ -n "$ARCHIVE" ]]; then
  [[ -f "$ARCHIVE" ]] || { echo "[bootstrap_cef_linux] error: archive not found: $ARCHIVE" >&2; exit 1; }
  log "using local archive: $ARCHIVE"
  cp -f "$ARCHIVE" "${TMP_DIR}/pkg.tar.bz2"
else
  URL="https://cef-builds.spotifycdn.com/${PKG_NAME//+/%2B}.tar.bz2"
  log "downloading CEF SDK (${CEF_PLATFORM}): ${URL}"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "${TMP_DIR}/pkg.tar.bz2" "${URL}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${TMP_DIR}/pkg.tar.bz2" "${URL}"
  else
    echo "[bootstrap_cef_linux] error: neither curl nor wget found" >&2
    exit 1
  fi
fi

log "extracting and validating..."
tar -xjf "${TMP_DIR}/pkg.tar.bz2" -C "${EXTRACT_DIR}"

SRC_PKG="${EXTRACT_DIR}/${PKG_NAME}"
if [[ ! -f "${SRC_PKG}/include/cef_version.h" ]] \
   || [[ ! -f "${SRC_PKG}/Release/libcef.so" ]]; then
  echo "[bootstrap_cef_linux] error: include/cef_version.h or Release/libcef.so missing after extract" >&2
  exit 1
fi

mkdir -p "${TP_DIR}"
rm -rf "${PKG_DIR}"
mv "${SRC_PKG}" "${PKG_DIR}"

log "done: ${PKG_DIR}"
