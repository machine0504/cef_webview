#!/usr/bin/env bash
#
# Install CEF *runtime* package (linux-x64.tar.gz from make_cef_runtime.sh) into
# the same directory Dart/native use: ~/.local/share/cef_webview/cef/<safeVer>/
#
# Use when intranet cannot reach the manifest CDN but you have copied linux-x64.tar.gz
# from cef_hosting (or built locally).
#
# Usage:
#   bootstrap_cef_runtime_linux.sh --archive /path/to/linux-x64.tar.gz
# or:
#   CEF_RUNTIME_ARCHIVE=/path/to/linux-x64.tar.gz bootstrap_cef_runtime_linux.sh
#
set -eu

CEF_VERSION="144.0.29+g0b1a012+chromium-144.0.7559.256"
SAFE_VER="${CEF_VERSION//+/-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ARCHIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) ARCHIVE="${2:-}"; shift 2;;
    -h|--help)
      echo "Usage: bootstrap_cef_runtime_linux.sh --archive /path/to/linux-x64.tar.gz"
      exit 0
      ;;
    *) echo "[bootstrap_cef_runtime_linux] unknown arg: $1" >&2; exit 1;;
  esac
done
[[ -n "$ARCHIVE" ]] || ARCHIVE="${CEF_RUNTIME_ARCHIVE:-}"
[[ -n "$ARCHIVE" ]] || { echo "[bootstrap_cef_runtime_linux] error: --archive required" >&2; exit 1; }
[[ -f "$ARCHIVE" ]] || { echo "[bootstrap_cef_runtime_linux] error: not found: $ARCHIVE" >&2; exit 1; }

HOME="${HOME:-/tmp}"
DEST="${HOME}/.local/share/cef_webview/cef/${SAFE_VER}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { echo "[bootstrap_cef_runtime_linux] $*"; }

if [[ -f "${DEST}/.ready" ]] && [[ -f "${DEST}/libcef.so" ]]; then
  log "runtime already installed: ${DEST} (skip)"
  exit 0
fi

log "extracting ${ARCHIVE} -> ${DEST}"
mkdir -p "${TMP}/extract"
tar -xzf "${ARCHIVE}" -C "${TMP}/extract"

# tar root may be flat files or a single top-level directory.
ROOT="${TMP}/extract"
if [[ $(find "${TMP}/extract" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ') -eq 1 ]]; then
  ONLY="$(find "${TMP}/extract" -mindepth 1 -maxdepth 1)"
  if [[ -d "$ONLY" ]]; then
    ROOT="$ONLY"
  fi
fi

[[ -f "${ROOT}/libcef.so" ]] || {
  echo "[bootstrap_cef_runtime_linux] error: libcef.so not found in archive" >&2
  exit 1
}

rm -rf "${DEST}"
mkdir -p "$(dirname "${DEST}")"
mv "${ROOT}" "${DEST}"
echo "${CEF_VERSION}" > "${DEST}/.ready"
chmod +x "${DEST}/cef_webview_subprocess" 2>/dev/null || true

log "done: ${DEST}"
