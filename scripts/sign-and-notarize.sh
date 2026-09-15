#!/bin/bash
# 可选：给应用包签名并提交公证。
#
# 默认发布流程**不做**这一步 —— DMG 里是 ad-hoc 签名的应用，
# 用户第一次打开需要右键 → 打开。这个脚本留给以后想启用正式签名的场景。
#
# 需要准备（都放在 CI Secrets 里，不要提交到仓库）：
#   MACOS_CERTIFICATE_P12        开发者 ID 应用证书（base64 编码的 .p12）
#   MACOS_CERTIFICATE_PASSWORD   .p12 的密码
#   MACOS_KEYCHAIN_PASSWORD      临时钥匙串的密码
#   MACOS_TEAM_ID                团队 ID
#   AC_NOTARY_APPLE_ID           用于公证的 Apple ID
#   AC_NOTARY_PASSWORD           该 Apple ID 的 app-specific password
#
# 用法: ./scripts/sign-and-notarize.sh dist/FormatSmith.app
#
# 接进 release.yml 的方式：在 "Build a universal app bundle" 之后、
# "Packaging DMG" 之前调用一次；DMG 本身也要再签一次。

set -euo pipefail

APP="${1:?usage: sign-and-notarize.sh <path to .app>}"

required=(MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD MACOS_TEAM_ID AC_NOTARY_APPLE_ID AC_NOTARY_PASSWORD)
missing=()
for name in "${required[@]}"; do
    [ -n "${!name:-}" ] || missing+=("$name")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "✗ missing environment variables: ${missing[*]}" >&2
    echo "  Leaving the build ad-hoc signed (users will need right-click → Open)." >&2
    exit 1
fi

KEYCHAIN="formatsmith-signing.keychain-db"
KEYCHAIN_PASSWORD="${MACOS_KEYCHAIN_PASSWORD:-$(openssl rand -hex 16)}"
CERT_PATH="$(mktemp -d)/certificate.p12"

echo "▶ Importing the certificate…"
printf '%s' "$MACOS_CERTIFICATE_P12" | base64 --decode > "$CERT_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERT_PATH" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep "Developer ID Application" | head -1 | awk '{print $2}')"
[ -n "$IDENTITY" ] || { echo "✗ no Developer ID Application identity found" >&2; exit 1; }

echo "▶ Signing with hardened runtime…"
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" \
    --entitlements /dev/null \
    "$APP/Contents/MacOS/$(basename "${APP%.app}")" 2>/dev/null || true
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▶ Notarizing (this can take a few minutes)…"
ZIP="$(mktemp -d)/$(basename "$APP").zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
    --apple-id "$AC_NOTARY_APPLE_ID" \
    --password "$AC_NOTARY_PASSWORD" \
    --team-id "$MACOS_TEAM_ID" \
    --wait

echo "▶ Stapling the ticket…"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "✓ Signed and notarized: $APP"
