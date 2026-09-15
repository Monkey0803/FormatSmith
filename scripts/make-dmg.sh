#!/bin/bash
# 把 dist/FormatSmith.app 打包成可分发的 DMG。
#
# 用法: ./scripts/make-dmg.sh [版本号]
#
# 只依赖系统自带的 hdiutil，不需要 create-dmg。
# 产物: dist/FormatSmith-<版本>.dmg 与同名 .sha256

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FormatSmith"
DIST="$ROOT/dist"
BUNDLE="$DIST/$APP_NAME.app"
VERSION="${1:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

[ -d "$BUNDLE" ] || { echo "✗ $BUNDLE not found; run scripts/build-app.sh first" >&2; exit 1; }

echo "▶ Packaging $APP_NAME $VERSION…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$BUNDLE" "$STAGE/"
# 拖拽安装的惯例：DMG 里放一个 /Applications 软链
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

echo "✓ $(basename "$DMG")  ($(du -h "$DMG" | cut -f1))"
echo "✓ $(basename "$DMG").sha256"
cat "$DMG.sha256"
