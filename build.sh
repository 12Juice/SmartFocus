#!/bin/bash
# Build SmartFocus into a signed .app bundle.
# Usage: ./build.sh
set -euo pipefail

APP_NAME="SmartFocus"
SRC="${APP_NAME}.swift"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

# Rebuild from scratch to avoid stale bundle content
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

# Release build
swiftc -O -whole-module-optimization \
    -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
    "${SRC}"

cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

# Ad-hoc signature: required for stable TCC (screen recording) attribution
codesign --force --sign - "${APP_BUNDLE}" >/dev/null 2>&1

echo "✅ Built ${APP_BUNDLE}"
