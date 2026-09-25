#!/bin/bash
# Package SmartFocus into a versioned, drag-to-install DMG.
# Usage: ./package.sh [--skip-build]   (skip rebuild, reuse build/SmartFocus.app)
#
# The .app stays ad-hoc signed (see build.sh): without a Developer ID
# certificate the DMG cannot be notarized, so Gatekeeper will challenge it
# on machines other than the build machine (right-click → Open to pass).
set -euo pipefail

APP_NAME="SmartFocus"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
STAGE_DIR="${BUILD_DIR}/dmg-stage"

if [[ "${1:-}" != "--skip-build" ]]; then
    ./build.sh
fi

[[ -d "${APP_BUNDLE}" ]] || { echo "❌ ${APP_BUNDLE} missing — run without --skip-build" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"

# A stale mount of the same volume name would make hdiutil create fail
hdiutil detach "/Volumes/${APP_NAME}" >/dev/null 2>&1 || true

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
cp -R "${APP_BUNDLE}" "${STAGE_DIR}/"
# Classic drag-to-install layout: drop the app onto the Applications symlink
ln -s /Applications "${STAGE_DIR}/Applications"

rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE_DIR}" -ov -format UDZO -quiet "${DMG}"
hdiutil verify -quiet "${DMG}"

echo "✅ Packaged ${DMG}"
