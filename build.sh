#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AI工具助手"
BUILD_DIR="build"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_NAME="ClaudeTokenUsage"

mkdir -p "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR"
mkdir -p "$BUILD_DIR/ModuleCache"

# Carbon: 全局快捷键 RegisterEventHotKey；AVFoundation/Speech: 语音转写（后续阶段）
swiftc Sources/ClaudeUsageApp.swift \
  -framework Cocoa \
  -framework Carbon \
  -framework AVFoundation \
  -framework Speech \
  -lsqlite3 \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -o "$MACOS_DIR/$EXECUTABLE_NAME"

# 生成 app 图标 AppIcon.icns（蓝→靛渐变 + 白 sparkles，与 app 内 makeAppIcon 一致）。
# best-effort：渲染或 iconutil 失败不阻断构建。
if swift tools/render_icon.swift "$BUILD_DIR/icon_1024.png" 1024 >/dev/null 2>&1; then
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  SRC="$BUILD_DIR/icon_1024.png"
  sips -z 16 16   "$SRC" --out "$ICONSET/icon_16x16.png"      >/dev/null 2>&1
  sips -z 32 32   "$SRC" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null 2>&1
  sips -z 32 32   "$SRC" --out "$ICONSET/icon_32x32.png"      >/dev/null 2>&1
  sips -z 64 64   "$SRC" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null 2>&1
  sips -z 128 128 "$SRC" --out "$ICONSET/icon_128x128.png"    >/dev/null 2>&1
  sips -z 256 256 "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
  sips -z 256 256 "$SRC" --out "$ICONSET/icon_256x256.png"    >/dev/null 2>&1
  sips -z 512 512 "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
  sips -z 512 512 "$SRC" --out "$ICONSET/icon_512x512.png"    >/dev/null 2>&1
  cp "$SRC" "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns" >/dev/null 2>&1 \
    && echo "✓ AppIcon.icns 已生成" || echo "⚠️ iconutil 失败，跳过图标"
else
  echo "⚠️ 图标渲染跳过（swift 不可用）"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.claude-token-usage</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>AI工具助手需要使用麦克风进行语音转文字。</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>AI工具助手需要语音识别将你的语音转写为文字。</string>
</dict>
</plist>
PLIST

# entitlements（麦克风/音频输入）。签名时附带；ad-hoc 构建时仅生成文件不影响。
ENTITLEMENTS="$BUILD_DIR/AIToolHelper.entitlements"
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
</dict>
</plist>
ENT

# 签名：设置 CODESIGN_IDENTITY 环境变量即用开发者身份签名（含 hardened runtime + entitlements）。
# 例： CODESIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" ./build.sh
# 查看可用身份： security find-identity -v -p codesigning
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "Signing with: $CODESIGN_IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$CODESIGN_IDENTITY" \
    "$APP_DIR"
  codesign --verify --verbose "$APP_DIR" || true
else
  # 无签名身份：ad-hoc 签名，保证本机可运行（麦克风/语音权限在已正式签名时最稳）
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR" 2>/dev/null || true
fi

echo "Built: $APP_DIR"
