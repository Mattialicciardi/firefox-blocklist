#!/bin/bash
# Assembla FirefoxBlocklist.app: un vero bundle .app con Info.plist, così macOS
# lo lancia come app con finestra (un eseguibile SwiftPM "nudo" non lo fa).
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="FirefoxBlocklist"
BUILD_CONFIG="release"
APP_DIR=".build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
APP_ICON="Resources/AppIcon.icns"

if [ ! -f "${APP_ICON}" ]; then
    echo "Icona mancante: ${APP_ICON}. Rigenerala con ./scripts/make-icon.sh"
    exit 1
fi

echo "→ swift build -c ${BUILD_CONFIG}"
swift build -c "${BUILD_CONFIG}"

BIN_PATH="$(swift build -c ${BUILD_CONFIG} --show-bin-path)/${APP_NAME}"

/bin/rm -rf "${APP_DIR}"
/bin/mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
/bin/cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
/bin/cp "${APP_ICON}" "${RESOURCES_DIR}/AppIcon.icns"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Firefox Blocklist</string>
    <key>CFBundleIdentifier</key>
    <string>com.mattialicciardi.firefoxblocklist</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "✅ Bundle pronto: ${APP_DIR}"
echo "   Lancia con:  open ${APP_DIR}"
