#!/bin/bash
# CLI 冒烟测试：用真实二进制跑几条转换，检查产物与退出码。
#
# 用法: ./scripts/smoke-test-cli.sh
#
# 不依赖任何仓库内的二进制素材：样本 PDF 由 scripts/make-sample-pdf.swift 现场生成。
# 比较适合在 CI 里作为「打包出来的东西真的能跑」的最后一道检查。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BINARY="$ROOT/dist/FormatSmith.app/Contents/MacOS/FormatSmith"

# 应用包里的二进制可能比源码旧；那样会「测试上一版代码」而不自知，必须避开。
USE_BUNDLE=false
if [ -x "$APP_BINARY" ]; then
    STALE_SOURCE="$(find "$ROOT/Sources" "$ROOT/Resources" -type f -newer "$APP_BINARY" 2>/dev/null | head -1)"
    if [ -n "$STALE_SOURCE" ]; then
        echo "⚠ app bundle is older than $(basename "$STALE_SOURCE") — falling back to a fresh build" >&2
    else
        USE_BUNDLE=true
    fi
fi

if [ "$USE_BUNDLE" = true ]; then
    BIN="$APP_BINARY"
    echo "using bundled binary: $BIN"
else
    swift build --package-path "$ROOT" -c release >/dev/null
    BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)/FormatSmith"
    echo "using build product: $BIN"
fi

[ -x "$BIN" ] || { echo "✗ binary not found: $BIN" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; FAILURES=$((FAILURES + 1)); }

# 断言：退出码
expect_exit() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" = "$actual" ]; then pass "$label (exit $actual)"; else fail "$label: expected exit $expected, got $actual"; fi
}

# 断言：文件存在
expect_file() {
    if [ -f "$1" ]; then pass "$2"; else fail "$2 — missing $1"; fi
}

# 断言：图片像素尺寸
expect_size() {
    local file="$1" want_w="$2" want_h="$3" label="$4"
    local got_w got_h
    got_w="$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    got_h="$(sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight/{print $2}')"
    if [ "$got_w" = "$want_w" ] && [ "$got_h" = "$want_h" ]; then
        pass "$label (${got_w}×${got_h})"
    else
        fail "$label — expected ${want_w}×${want_h}, got ${got_w}×${got_h}"
    fi
}

echo "▶ Generating a sample PDF…"
SAMPLE="$(swift "$ROOT/scripts/make-sample-pdf.swift" "$WORK/sample.pdf" 3)"
[ -f "$SAMPLE" ] || { echo "✗ could not generate the sample PDF" >&2; exit 1; }
pass "sample PDF generated"

echo "▶ Listing formats…"
if "$BIN" --list-formats | grep -q "PNG"; then pass "--list-formats mentions PNG"; else fail "--list-formats output looks wrong"; fi

echo "▶ PNG at 150 DPI, all pages…"
OUT="$WORK/png"
"$BIN" --convert "$SAMPLE" --format png --dpi 150 --out "$OUT" >/dev/null 2>&1
expect_exit 0 $? "PNG conversion"
# 400×300 pt at 150 dpi → 400/72*150 = 833, 300/72*150 = 625
expect_file "$OUT/sample/sample-1.png" "first page written"
expect_file "$OUT/sample/sample-3.png" "last page written"
expect_size "$OUT/sample/sample-1.png" 833 625 "150 DPI dimensions"

echo "▶ Page range 2-3, JPEG, no subfolder…"
OUT="$WORK/jpeg"
"$BIN" --convert "$SAMPLE" --format jpeg --quality 0.8 --pages 2-3 --out "$OUT" --no-subfolder --pattern "doc-{page}" >/dev/null 2>&1
expect_exit 0 $? "JPEG conversion"
expect_file "$OUT/doc-2.jpg" "page 2 written with .jpg extension"
if [ -f "$OUT/doc-1.jpg" ]; then fail "page 1 should not have been written"; else pass "page range respected"; fi

echo "▶ Transparency and background…"
OUT="$WORK/alpha"
"$BIN" --convert "$SAMPLE" --format png --pages 1 --background transparent --out "$OUT" --no-subfolder --pattern "alpha" >/dev/null 2>&1
expect_exit 0 $? "PNG with transparent background"

OUT="$WORK/black"
"$BIN" --convert "$SAMPLE" --format jpeg --pages 1 --background black --out "$OUT" --no-subfolder --pattern "black" >/dev/null 2>&1
expect_exit 0 $? "JPEG with black background"

echo "▶ HEIC output…"
OUT="$WORK/heic"
"$BIN" --convert "$SAMPLE" --format heic --scale 1 --pages 1 --out "$OUT" --no-subfolder --pattern "shot" >/dev/null 2>&1
expect_exit 0 $? "HEIC conversion"
expect_size "$OUT/shot.heic" 400 300 "scale 1x dimensions"

echo "▶ Refusing to overwrite…"
OUT="$WORK/dup"
"$BIN" --convert "$SAMPLE" --format png --scale 1 --pages 1 --out "$OUT" --no-subfolder --pattern "same" >/dev/null 2>&1
"$BIN" --convert "$SAMPLE" --format png --scale 1 --pages 1 --out "$OUT" --no-subfolder --pattern "same" >/dev/null 2>&1
expect_file "$OUT/same.png" "original kept"
expect_file "$OUT/same-1.png" "second run wrote a suffixed file"

echo "▶ Error handling…"
"$BIN" --convert "$WORK/does-not-exist.pdf" --format png --out "$WORK/none" >/dev/null 2>&1
expect_exit 1 $? "missing input file"

"$BIN" --convert "$SAMPLE" --format definitely-not-a-format --out "$WORK/none" >/dev/null 2>&1
expect_exit 2 $? "unknown format"

"$BIN" --convert "$SAMPLE" --format png --dpi 20000 --pages 1 --out "$WORK/none" >/dev/null 2>&1
expect_exit 1 $? "absurd resolution is rejected"

echo "▶ Version and help…"
"$BIN" --version >/dev/null 2>&1
expect_exit 0 $? "--version"
if "$BIN" --help | grep -q -- "--convert"; then
    pass "--help mentions --convert"
else
    fail "--help does not mention --convert"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "✓ CLI smoke test passed"
    exit 0
else
    echo "✗ CLI smoke test failed: $FAILURES problem(s)" >&2
    exit 1
fi
