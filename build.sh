#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product ScreenSwitch
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p dist
APP_PATH="${1:-dist/ScreenSwitch.app}"

package_app() {
    local app="$1"
    local identifier="$2"
    local display_name="$3"
    local menu_only="$4"
    mkdir -p "$app/Contents/MacOS"
    mkdir -p "$app/Contents/Resources"
    cp "$BIN_DIR/ScreenSwitch" "$app/Contents/MacOS/ScreenSwitch"
    cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>ScreenSwitch</string>
    <key>CFBundleIdentifier</key><string>$identifier</string>
    <key>CFBundleName</key><string>$display_name</string>
    <key>CFBundleDisplayName</key><string>$display_name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.2.6</string>
    <key>CFBundleVersion</key><string>8</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><$menu_only/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
</dict></plist>
EOF
    plutil -lint "$app/Contents/Info.plist"
    codesign --force --sign - "$app"
}

package_app "$APP_PATH" "local.ScreenSwitch" "ScreenSwitch" false
printf '\n已构建（含恢复功能）：\n%s\n' "$APP_PATH"
