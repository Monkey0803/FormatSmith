#!/bin/bash
# 构建 FormatSmith.app 并组装成可双击运行的 macOS 应用包。
#
# 用法:
#   ./scripts/build-app.sh                 # 构建到 ./dist/FormatSmith.app（当前架构）
#   ./scripts/build-app.sh --universal     # 构建 arm64 + x86_64 通用二进制
#   ./scripts/build-app.sh --install       # 构建后复制到 ~/Applications
#   ./scripts/build-app.sh --dmg           # 额外产出 dist/FormatSmith-<版本>.dmg
#
# 版本号唯一来源是仓库根目录的 VERSION 文件，这里会写进 Info.plist。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FormatSmith"
DIST="$ROOT/dist"
BUNDLE="$DIST/$APP_NAME.app"
ICONSET="$DIST/AppIcon.iconset"
UNIVERSAL=false
INSTALL=false
MAKE_DMG=false

for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --install) INSTALL=true ;;
        --dmg) MAKE_DMG=true ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[ -n "$VERSION" ] || { echo "VERSION file is empty" >&2; exit 1; }

BUILD_ARGS=(-c release --package-path "$ROOT")
if [ "$UNIVERSAL" = true ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

ARCH_LABEL="current arch"; [ "$UNIVERSAL" = true ] && ARCH_LABEL="universal"
echo "▶ Building FormatSmith $VERSION (release, $ARCH_LABEL)…"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"

if [ ! -x "$BIN_PATH" ]; then
    echo "✗ Executable not found: $BIN_PATH" >&2
    exit 1
fi

echo "▶ Generating app icon…"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$DIST/AppIcon.icns"

echo "▶ Assembling bundle…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$DIST/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# 本地化：以标准 .lproj 目录放进 Contents/Resources，用 Bundle.main 解析。
for lproj in "$ROOT/Resources/i18n"/*.lproj; do
    [ -e "$lproj" ] || continue
    cp -R "$lproj" "$BUNDLE/Contents/Resources/"
done

# 版本号注入
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$BUNDLE/Contents/Info.plist"

# 本地 ad-hoc 签名：让应用能被正常启动，并让「打开方式」等系统功能生效。
if ! codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1; then
    echo "  (note: ad-hoc signing failed; the app usually still runs)"
fi

# 刷新 Launch Services，让图标与「打开方式」立即生效。
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$BUNDLE" >/dev/null 2>&1 || true

echo "✓ Built: $BUNDLE"

if [ "$MAKE_DMG" = true ]; then
    "$ROOT/scripts/make-dmg.sh" "$VERSION"
fi

if [ "$INSTALL" = true ]; then
    TARGET_DIR="$HOME/Applications"
    mkdir -p "$TARGET_DIR"
    rm -rf "$TARGET_DIR/$APP_NAME.app"
    cp -R "$BUNDLE" "$TARGET_DIR/$APP_NAME.app"
    echo "✓ Installed: $TARGET_DIR/$APP_NAME.app"
fi
