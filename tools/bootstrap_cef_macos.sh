#!/usr/bin/env bash
#
# Build-time CEF SDK bootstrap for macOS.
#
# Why: macos/cef_webview.podspec references, via relative symlinks,
#   third_party/cef/cef_binary_${VERSION}_macos{arm64|x64}_minimal/
# (include/ and "Chromium Embedded Framework.framework"). If that directory is
# missing, pod install / xcodebuild fail.
#
# Behavior: if the arch-matching CEF macOS minimal package is missing, download
# it from https://cef-builds.spotifycdn.com, extract into a temp dir, validate,
# then atomically move into third_party/cef/. Any interruption (Ctrl-C / failure)
# leaves no partial package. Idempotent: returns immediately if already present.
#
# Invoked automatically by the podspec prepare_command on every pod install
# (so each developer's first macOS build downloads it). Can also be run manually:
#   package/cef_webview/tools/bootstrap_cef_macos.sh
#
# NOTE: keep this script ASCII-only. CocoaPods runs prepare_command under a
# non-UTF-8 locale; non-ASCII bytes here can (a) glue into bash variable names
# (set -u "unbound variable") and (b) make CocoaPods raise
# Encoding::CompatibilityError when it captures output.
#
set -eu

CEF_VERSION="144.0.29+g0b1a012+chromium-144.0.7559.256"

# This script lives in package/cef_webview/tools/ ; 3 levels up is the branch root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TP_DIR="${REPO_ROOT}/third_party/cef"

# Pick the package for the current arch.
ARCH="$(uname -m)"
if [ "${ARCH}" = "arm64" ]; then
  PKG_NAME="cef_binary_${CEF_VERSION}_macosarm64_minimal"
else
  PKG_NAME="cef_binary_${CEF_VERSION}_macosx64_minimal"
fi
PKG_DIR="${TP_DIR}/${PKG_NAME}"

log() { echo "[bootstrap_cef_macos] $*"; }

# Idempotent: already present -> done.
if [ -d "${PKG_DIR}/Release/Chromium Embedded Framework.framework" ] \
   && [ -f "${PKG_DIR}/include/cef_version.h" ]; then
  log "already present: ${PKG_NAME} (skip download)"
  exit 0
fi

# '+' must be percent-encoded as %2B in the URL.
URL="https://cef-builds.spotifycdn.com/${PKG_NAME//+/%2B}.tar.bz2"
TMP_DIR="${TP_DIR}/.bootstrap-$$"
ARCHIVE="${TMP_DIR}/pkg.tar.bz2"
EXTRACT_DIR="${TMP_DIR}/extract"

mkdir -p "${EXTRACT_DIR}"
# Always clean the temp dir on exit (incl. Ctrl-C / failure); never leave a
# half-extracted package inside third_party/cef.
trap 'rm -rf "${TMP_DIR}"' EXIT

log "downloading macOS CEF SDK (~88MB): ${URL}"
if command -v curl >/dev/null 2>&1; then
  curl -fL --progress-bar -o "${ARCHIVE}" "${URL}"
elif command -v wget >/dev/null 2>&1; then
  wget -O "${ARCHIVE}" "${URL}"
else
  echo "[bootstrap_cef_macos] error: neither curl nor wget found" >&2
  exit 1
fi

log "extracting and validating..."
tar -xjf "${ARCHIVE}" -C "${EXTRACT_DIR}"

SRC_PKG="${EXTRACT_DIR}/${PKG_NAME}"
if [ ! -d "${SRC_PKG}/Release/Chromium Embedded Framework.framework" ] \
   || [ ! -f "${SRC_PKG}/include/cef_version.h" ]; then
  echo "[bootstrap_cef_macos] error: framework or include/cef_version.h not found after extract" >&2
  exit 1
fi

# Atomic install: remove any partial dir, then move into place.
mkdir -p "${TP_DIR}"
rm -rf "${PKG_DIR}"
mv "${SRC_PKG}" "${PKG_DIR}"

log "done: ${PKG_DIR}"
