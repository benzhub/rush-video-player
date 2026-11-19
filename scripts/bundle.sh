#!/bin/bash
# 建置 release 版本並打包成 build/Rush Video Player.app
#   ./scripts/bundle.sh            # 打包
#   ./scripts/bundle.sh --install  # 打包並複製到 /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Rush Video Player"
APP="build/$APP_NAME.app"

echo "▸ 建置 release…"
swift build -c release --product VideoPlayer
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ 組裝 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/VideoPlayer" "$APP/Contents/MacOS/VideoPlayer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 動態 framework 放進 Contents/Frameworks（MPVKit 目前都是靜態函式庫，已編進執行檔）
shopt -s nullglob
copied=0
for fw in "$BIN_DIR"/*.framework; do
    if file -L "$fw/$(basename "$fw" .framework)" | grep -q "dynamically linked shared library"; then
        cp -R "$fw" "$APP/Contents/Frameworks/"
        copied=1
    fi
done
if ((copied)); then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/VideoPlayer" 2>/dev/null || true
fi
# SwiftPM 的資源 bundle（若有）
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "▸ 產生圖示"
ICON_TMP="$(mktemp -d)"
swift scripts/make-icon.swift "$ICON_TMP/icon.png"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ICON_TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

echo "▸ Ad-hoc 簽名"
codesign --force --deep --sign - "$APP"

echo "✅ 完成：$APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "✅ 已安裝到 /Applications/$APP_NAME.app"
fi
