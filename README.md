# FormatSmith

**A native macOS file converter.** Drop files in, pick an output format, done. Everything runs
locally through Apple's own frameworks — nothing is uploaded, and there is no third-party dependency
in the app itself.

> Status: the conversion engine, the app shell and the CLI are in place for **PDF → image**. The
> remaining directions are being built in the open; see the [roadmap](#roadmap).

## Features

- **Drag and drop** PDFs, click to pick them, drop a whole folder (PDFs inside are found for you), or
  use *Open With → FormatSmith*.
- **Seven output formats** by default — PNG, JPEG, HEIC, AVIF, TIFF, GIF, BMP — plus the long tail
  (JPEG 2000, Photoshop, Targa, OpenEXR, PBM, Windows Icon) behind one switch.
- **HD or print resolution**: pick a DPI (72–600) or a scale factor (1×–4×).
- **Backgrounds**: white, black, or transparent (transparency only where the format can store it).
- **Page ranges**: all pages, or something like `1-3,5,8-10`.
- **Naming you control**: `{name}`, `{page}`, `{total}`, `{date}`, `{time}`, per-file subfolders,
  zero-padded page numbers. Existing files are never overwritten.
- **Honest feedback**: per-file progress, a running total, cancel at any time, and "Show in Finder"
  when a file is done.
- **A real CLI** in the same binary, for scripts and batch jobs.

The format list is not hardcoded. It is read from ImageIO at runtime, so a macOS update that adds a
format adds it here — and the app tells you *why* something is unavailable instead of failing
silently. WebP and JPEG XL, for instance, can be read but not written by macOS, so they are never
offered as outputs.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15.3 or later (only for building)

## Getting started

```bash
git clone https://github.com/Monkey0803/FormatSmith.git
cd FormatSmith
./scripts/build-app.sh --install     # builds, then copies to ~/Applications
```

Then open FormatSmith from `~/Applications` (or Spotlight). Prefer to run it from the build
directory? `./scripts/build-app.sh` leaves the bundle at `dist/FormatSmith.app`.

Because these builds are ad-hoc signed rather than notarized, macOS warns on first launch. Right-click
the app, choose **Open**, then confirm. You only have to do this once.

<details>
<summary>Building a universal binary or a DMG</summary>

```bash
./scripts/build-app.sh --universal   # arm64 + x86_64
./scripts/build-app.sh --dmg         # also produces dist/FormatSmith-<version>.dmg
```

</details>

## Command line

The app bundle ships a CLI entry point, so you can script conversions:

```bash
# A 300 DPI PNG of every page
dist/FormatSmith.app/Contents/MacOS/FormatSmith \
    --convert report.pdf --format png --dpi 300 --out ~/Desktop/images

# Batch: pages 1 and 5-8 only, 92% JPEG, no per-file subfolder
dist/FormatSmith.app/Contents/MacOS/FormatSmith \
    --convert a.pdf b.pdf --format jpeg --quality 0.92 --pages 1,5-8 \
    --out ~/Desktop/out --no-subfolder

# What can this Mac write?
dist/FormatSmith.app/Contents/MacOS/FormatSmith --list-formats
```

| Flag | Meaning |
| --- | --- |
| `--convert <a.pdf …>` | Files to convert |
| `--format <name>` | `png`, `jpeg`, `heic`, `avif`, `tiff`, `gif`, `bmp`, … (default `png`) |
| `--quality <0.05-1>` | Quality for lossy formats (default `0.9`) |
| `--dpi <n>` / `--scale <n>` | Resolution (default `200` DPI) |
| `--pages <range>` | e.g. `1-3,5,8-10` (default: all) |
| `--out <dir>` | Output directory (default: current directory) |
| `--pattern <template>` | File name template using `{name}` `{page}` `{total}` `{date}` `{time}` |
| `--background <c>` | `white`, `black`, `transparent` |
| `--no-subfolder` | Write straight into `--out` |
| `--list-formats` | List output formats available on this Mac |
| `--version`, `--help` | Version / usage |

Exit codes: `0` success, `1` one or more files failed, `2` bad arguments. Data goes to stdout,
diagnostics to stderr.

Set `FORMATSMITH_DEBUG=1` for a trace of file intake and metadata reads.

## Roadmap

- [x] PDF → image (PNG, JPEG, HEIC, AVIF, TIFF, GIF, BMP, …)
- [ ] Image → image, including WebP, JPEG XL, HEIC and RAW input
- [ ] Image → PDF (combine several images into one document)
- [ ] PDF toolbox: merge, split, extract pages, rotate, compress
- [ ] Documents → PDF (Office via LibreOffice, HTML natively, Markdown via pandoc)
- [ ] Presets, concurrent conversion, and dragging results out to Finder

Video and audio conversion is explicitly **not** in scope — that is a different stack, and it would
make this a different app.

## Project layout

```
Sources/FormatSmithCore/     Conversion engine and models. No SwiftUI, so it is testable headlessly.
  Formats/                   Format registry, capability detection, input classification.
  Engine/                    Rasterizing, decoding, encoding, orchestration.
  Model/                     Settings, page ranges, output naming, jobs and results.
Sources/FormatSmithApp/      The SwiftUI app and the CLI entry point.
Tests/FormatSmithCoreTests/  Unit tests plus pixel-level integration tests.
Resources/i18n/              Localized strings, copied into the bundle by the build script.
Resources/Info.plist         Bundle metadata (version injected from VERSION at build time).
scripts/                     build-app.sh, make-dmg.sh, make-icon.swift, smoke-test-cli.sh
```

## How it works, and the sharp edges

Everything is built on PDFKit, Core Graphics, ImageIO and SwiftUI. A few things are worth knowing if
you plan to touch the rendering code:

- **`CGContext.drawPDFPage` does not apply a page's `/Rotate`.** You have to build the transform
  yourself. `PDFRasterizer.pageTransform(rotation:box:)` does that for 0/90/180/270 degrees, and
  `PageTransformTests` pins the maths down by asserting where corners land.
- **The ImageIO thumbnail API only downscales.** Asking for a larger `maxPixelSize` than the source
  silently returns the original pixels, so `ImageDecoder` resamples explicitly when scaling up.
- **Formats are not interchangeable.** Only some can store transparency or accept a quality
  parameter, and container formats like ICO impose size rules. `FormatRegistry` carries that
  knowledge, and the encoder validates before writing.
- **"Transparent" plus an opaque format must degrade to a real colour**, otherwise unpainted areas
  come out black.

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The short version:
`swift test` must pass, and `swift format lint --configuration .swift-format --recursive Sources Tests`
must be clean.

## License

[MIT](LICENSE).
