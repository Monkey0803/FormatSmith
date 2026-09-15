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
expect_file "$OUT/sample-1.png" "first page written"
expect_file "$OUT/sample-3.png" "last page written"
expect_size "$OUT/sample-1.png" 833 625 "150 DPI dimensions"

echo "▶ Page range 2-3, JPEG, no subfolder…"
OUT="$WORK/jpeg"
"$BIN" --convert "$SAMPLE" --format jpeg --quality 0.8 --pages 2-3 --out "$OUT" --no-subfolder --pattern "doc-{page}" >/dev/null 2>&1
expect_exit 0 $? "JPEG conversion"
expect_file "$OUT/doc-2.jpg" "page 2 written with .jpg extension"
if [ -f "$OUT/doc-1.jpg" ]; then fail "page 1 should not have been written"; else pass "page range respected"; fi

echo "▶ Subfolder opt-in…"
OUT="$WORK/sub"
"$BIN" --convert "$SAMPLE" --to png --dpi 72 --pages 1 --subfolder --out "$OUT" >/dev/null 2>&1
expect_exit 0 $? "conversion with --subfolder"
expect_file "$OUT/sample/sample-1.png" "file placed in a per-source subfolder"

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

echo "▶ PDF → PNG (used as image input below)…"
IMG_DIR="$WORK/images"
"$BIN" --convert "$SAMPLE" --to png --dpi 72 --out "$IMG_DIR" >/dev/null 2>&1
expect_exit 0 $? "PDF to PNG"
expect_file "$IMG_DIR/sample-1.png" "image available for the next checks"

echo "▶ Image → image…"
OUT="$WORK/img2img"
"$BIN" --convert "$IMG_DIR/sample-1.png" --to jpeg --quality 0.8 --out "$OUT" --pattern "shot" >/dev/null 2>&1
expect_exit 0 $? "PNG to JPEG"
expect_file "$OUT/shot.jpg" "JPEG written with .jpg extension"

OUT="$WORK/half"
"$BIN" --convert "$IMG_DIR/sample-1.png" --to png --scale 0.5 --out "$OUT" --pattern "half" >/dev/null 2>&1
expect_exit 0 $? "image scaling"
expect_size "$OUT/half.png" 200 150 "50% of 400×300"

echo "▶ Image → PDF…"
OUT="$WORK/album"
"$BIN" --convert "$IMG_DIR/sample-1.png" "$IMG_DIR/sample-2.png" "$IMG_DIR/sample-3.png" \
    --to pdf --out "$OUT" --pattern "album" >/dev/null 2>&1
expect_exit 0 $? "merge three images into one PDF"
expect_file "$OUT/album.pdf" "merged PDF written"

OUT="$WORK/a4"
"$BIN" --convert "$IMG_DIR/sample-1.png" --to pdf --pdf-page-size a4 --pdf-compress \
    --quality 0.6 --out "$OUT" --pattern "a4" >/dev/null 2>&1
expect_exit 0 $? "A4 page size with JPEG compression"

OUT="$WORK/separate"
"$BIN" --convert "$IMG_DIR/sample-1.png" "$IMG_DIR/sample-2.png" --to pdf --no-merge \
    --out "$OUT" --pattern "{name}" >/dev/null 2>&1
expect_exit 0 $? "one PDF per image when merging is off"
expect_file "$OUT/sample-1.pdf" "first separate PDF"
expect_file "$OUT/sample-2.pdf" "second separate PDF"

echo "▶ PDF toolbox…"
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
swift "$ROOT/scripts/make-sample-pdf.swift" "$TOOLS/b.pdf" 2 >/dev/null

OUT="$TOOLS/merge"
"$BIN" --convert "$SAMPLE" "$TOOLS/b.pdf" --pdf-tool merge --out "$OUT" --pattern "combined" >/dev/null 2>&1
expect_exit 0 $? "merge two PDFs"
expect_file "$OUT/combined.pdf" "merged PDF written"

OUT="$TOOLS/split"
"$BIN" --convert "$SAMPLE" --pdf-tool split --split-every 2 --out "$OUT" --pattern "{name}-{page}" >/dev/null 2>&1
expect_exit 0 $? "split every 2 pages"
expect_file "$OUT/sample-1.pdf" "first split part"
expect_file "$OUT/sample-3.pdf" "second split part"

OUT="$TOOLS/extract"
"$BIN" --convert "$SAMPLE" --pdf-tool extract --pages 1,3 --out "$OUT" --pattern "picked" >/dev/null 2>&1
expect_exit 0 $? "extract pages 1 and 3"
expect_file "$OUT/picked.pdf" "extracted PDF written"

OUT="$TOOLS/rotate"
"$BIN" --convert "$SAMPLE" --pdf-tool rotate --rotate 90 --out "$OUT" --pattern "rotated" >/dev/null 2>&1
expect_exit 0 $? "rotate 90 degrees"
expect_file "$OUT/rotated.pdf" "rotated PDF written"
# sips 报的是 MediaBox（400×300），不含 /Rotate，所以直接确认旋转角度写进去了；
# 「显示尺寸互换」由单测 PDFToolkitTests.testRotate90SwapsDisplayedPageSize 覆盖。
if grep -aq "/Rotate 90" "$OUT/rotated.pdf"; then
    pass "rotation written into the page dictionary"
else
    fail "rotated PDF does not contain /Rotate 90"
fi

OUT="$TOOLS/compress"
"$BIN" --convert "$SAMPLE" --pdf-tool compress --dpi 72 --pdf-compress --quality 0.5 \
    --out "$OUT" --pattern "small" >/dev/null 2>&1
expect_exit 0 $? "compress"
expect_file "$OUT/small.pdf" "compressed PDF written"

echo "▶ Error handling…"
"$BIN" --convert "$WORK/does-not-exist.pdf" --format png --out "$WORK/none" >/dev/null 2>&1
expect_exit 1 $? "missing input file"

"$BIN" --convert "$SAMPLE" --format definitely-not-a-format --out "$WORK/none" >/dev/null 2>&1
expect_exit 2 $? "unknown format"

"$BIN" --convert "$SAMPLE" --format png --dpi 20000 --pages 1 --out "$WORK/none" >/dev/null 2>&1
expect_exit 1 $? "absurd resolution is rejected"

# WebP 只能读不能写，错误信息应当说明这一点，而不是笼统的「未知格式」
WEBP_MSG="$("$BIN" --convert "$IMG_DIR/sample-1.png" --to webp --out "$WORK/none" 2>&1)"
if printf '%s' "$WEBP_MSG" | grep -qi "not written"; then
    pass "read-only format explains itself"
else
    fail "WebP rejection message is unhelpful: $WEBP_MSG"
fi

# 文档输入仍未实现，必须明确说明而不是静默失败
printf 'hello' > "$WORK/notes.md"
DOC_MSG="$("$BIN" --convert "$WORK/notes.md" --to pdf --out "$WORK/none" 2>&1)"
if printf '%s' "$DOC_MSG" | grep -qi "not supported yet"; then
    pass "unsupported input reports clearly"
else
    fail "document input message is unclear: $DOC_MSG"
fi

# PDF → PDF 现在默认是「合并」，单个输入等同于复制一份
OUT="$WORK/pdfcopy"
"$BIN" --convert "$SAMPLE" --to pdf --out "$OUT" --pattern "copy" >/dev/null 2>&1
expect_exit 0 $? "PDF to PDF defaults to merge/copy"
expect_file "$OUT/copy.pdf" "copied PDF written"

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
