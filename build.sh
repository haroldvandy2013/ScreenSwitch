#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product ScreenSwitch
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p dist

package_app() {
    local app="$1"
    local identifier="$2"
    local display_name="$3"
    local menu_only="$4"
    mkdir -p "$app/Contents/MacOS"
    cp "$BIN_DIR/ScreenSwitch" "$app/Contents/MacOS/ScreenSwitch"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>ScreenSwitch</string>
    <key>CFBundleIdentifier</key><string>$identifier</string>
    <key>CFBundleName</key><string>$display_name</string>
    <key>CFBundleDisplayName</key><string>$display_name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
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

package_app "dist/ScreenSwitch.app" "local.ScreenSwitch" "ScreenSwitch" false
printf '\n已构建（含恢复功能）：\n%s/dist/ScreenSwitch.app\n' "$PWD"
