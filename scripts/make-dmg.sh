#!/bin/bash
# 把 dist/FormatSmith.app 打包成可分发的 DMG。
#
# 用法: ./scripts/make-dmg.sh [版本号]
#
# 只用系统自带的工具，不需要 create-dmg。
# 产物: dist/FormatSmith-<版本>.dmg 与同名 .sha256

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FormatSmith"
DIST="$ROOT/dist"
BUNDLE="$DIST/$APP_NAME.app"
VERSION="${1:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
DMG="$DIST/$APP_NAME-${VERSION}.dmg"

if [ ! -d "$BUNDLE" ]; then
    echo "✗ ${BUNDLE} not found; run scripts/build-app.sh first" >&2
    exit 1
fi

echo "▶ Packaging ${APP_NAME} ${VERSION}…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$BUNDLE" "$STAGE/"
# 拖拽安装的惯例：DMG 里放一个 /Applications 软链
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# diskutil image 是新接口；老系统上退回 hdiutil。
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from "$STAGE" \
        --volumeName "$APP_NAME ${VERSION}" \
        --format UDZO \
        "$DMG" >/dev/null
else
    hdiutil create \
        -volname "$APP_NAME ${VERSION}" \
        -srcfolder "$STAGE" \
        -ov -format UDZO \
        "$DMG" >/dev/null
fi

# 自己先验一遍：挂得上、里面有应用、有软链。发布前发现问题好过发布后。
MOUNT="$(mktemp -d)"
if hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet; then
    if [ ! -d "$MOUNT/${APP_NAME}.app" ] || [ ! -L "$MOUNT/Applications" ]; then
        echo "✗ the DMG does not contain the app and an /Applications link" >&2
        hdiutil detach "$MOUNT" -quiet || true
        exit 1
    fi
    hdiutil detach "$MOUNT" -quiet
else
    echo "✗ the DMG could not be mounted" >&2
    exit 1
fi
rmdir "$MOUNT" 2>/dev/null || true

( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

echo "✓ $(basename "$DMG")  ($(du -h "$DMG" | cut -f1))"
echo "✓ $(basename "$DMG").sha256"
cat "${DMG}.sha256"
