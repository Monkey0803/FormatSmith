# FormatSmith

**A native macOS file converter.** Drop files in, pick an output format, done. Everything runs
locally through Apple's own frameworks — nothing is uploaded, and there is no third-party dependency
in the app itself.

> Status: PDF → image, image → image, image → PDF, the PDF toolbox and **document → PDF** all work
> today, in both the app and the CLI. See the [roadmap](#roadmap) for what is still coming.

## Features

- **Drag and drop** PDFs and images, click to pick them, drop a whole folder (supported files inside
  are found for you), or use *Open With → FormatSmith*.
- **Seven output formats** by default — PNG, JPEG, HEIC, AVIF, TIFF, GIF, BMP — plus the long tail
  (JPEG 2000, Photoshop, Targa, OpenEXR, PBM, Windows Icon) behind one switch.
- **HD or print resolution**: pick a DPI (72–600) or a scale factor (1×–4×).
- **Backgrounds**: white, black, or transparent (transparency only where the format can store it).
- **Page ranges**: all pages, or something like `1-3,5,8-10`.
- **Naming you control**: `{name}`, `{page}`, `{total}`, `{date}`, `{time}`, per-file subfolders,
  zero-padded page numbers. Existing files are never overwritten.
- **Honest feedback**: per-file progress, a running total, cancel at any time, and "Show in Finder"
  when a file is done.
- **Images → PDF**: one PDF per image, or merge a whole selection into a single multi-page document,
  with a page size that either matches the image or fits A4/Letter with a margin. Embed losslessly, or
  JPEG-compress the images to keep the file small.
- **Images → images**: convert between formats and scale up or down (50%–400% or any custom factor).
- **PDF toolbox**: merge several PDFs, split one every N pages, extract just the pages you list,
  rotate every page by 90/180/270°, or compress by re-rasterising at a lower DPI. Compressing is
  lossy by design and the app says so before you run it.
- **Documents → PDF**: Office, OpenDocument and RTF through a LibreOffice you already have; HTML,
  Markdown and plain text through the system WebKit, with no extra installation. Markdown uses pandoc
  when it is around and falls back to a built-in renderer when it is not.
- **A real CLI** in the same binary, for scripts and batch jobs. Its output stays in English
  regardless of system language, so scripts can rely on it.

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
| `--convert <file …>` | Files to convert (PDF or image) |
| `--to <target>` | An image format (`png`, `jpeg`, `heic`, …) or `pdf` (default `png`) |
| `--format <name>` | Alias of `--to` |
| `--quality <0.05-1>` | Quality for lossy formats (default `0.9`) |
| `--dpi <n>` / `--scale <n>` | Resolution (default `200` DPI) |
| `--pages <range>` | e.g. `1-3,5,8-10` (default: all) |
| `--out <dir>` | Output directory (default: current directory) |
| `--pattern <template>` | File name template using `{name}` `{page}` `{total}` `{date}` `{time}` |
| `--background <c>` | `white`, `black`, `transparent` |
| `--subfolder` | Create a subfolder per source file (off by default in the CLI) |
| `--pdf-page-size <s>` | `fit`, `a4`, or `letter` (default `fit`) |
| `--pdf-margin <pt>` | Margin for fixed page sizes (default `24`) |
| `--pdf-compress` | JPEG-compress embedded images to shrink the PDF |
| `--merge` / `--no-merge` | Merge several images into one PDF (default: merge) |
| `--pdf-tool <tool>` | `merge`, `split`, `extract`, `rotate`, or `compress` (PDF in, PDF out) |
| `--split-every <n>` | Pages per file when splitting |
| `--rotate <deg>` | `90`, `180`, or `270` |
| `--check-dependencies` | Report whether LibreOffice and pandoc were found |
| `--list-formats` | List output formats available on this Mac |
| `--version`, `--help` | Version / usage |

Exit codes: `0` success, `1` one or more files failed, `2` bad arguments. Data goes to stdout,
diagnostics to stderr.

Set `FORMATSMITH_DEBUG=1` for a trace of file intake and metadata reads.

## Roadmap

- [x] PDF → image (PNG, JPEG, HEIC, AVIF, TIFF, GIF, BMP, …)
- [x] Image → image, including WebP, JPEG XL, HEIC and RAW input
- [x] Image → PDF (combine several images into one document)
- [x] PDF toolbox: merge, split, extract pages, rotate, compress
- [x] Documents → PDF (Office via LibreOffice, HTML natively, Markdown via pandoc)
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
- **Image → PDF goes through `CGPDFContext`, not ImageIO**, because ImageIO writes a page per image
  sized in pixels and gives no control over page size or margins. When JPEG compression is on, the
  compressed image is re-imported so Core Graphics can embed it with `DCTDecode` instead of
  re-encoding it losslessly — verify with `grep -c DCTDecode` if you ever doubt it.

## Which direction goes through which pipeline

`ConversionRouter` decides, and the UI reads the same table, so a route is either available
everywhere or reported as unavailable everywhere:

| Input | Target | Pipeline |
| --- | --- | --- |
| PDF | image | Rasterise each page at the chosen DPI |
| PDF | PDF | `PDFToolkit`: merge, split, extract, rotate, compress |
| image | image | Decode, scale, re-encode |
| image | PDF | `PDFComposer`, optionally merging several files |
| Office / OpenDocument / RTF | PDF | LibreOffice, run headless with a private profile |
| HTML / Markdown / plain text | PDF | WebKit, rendered to A4 and paginated; pandoc first for Markdown |
| Office / HTML / Markdown | image | Rejected with an explanation — go through PDF first |

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The short version:
`swift test` must pass, and `swift format lint --configuration .swift-format --recursive Sources Tests`
must be clean.

## Optional external tools

Two features can use tools you may already have. Nothing is bundled, and nothing is required:

| Tool | Used for | Without it |
| --- | --- | --- |
| [LibreOffice](https://www.libreoffice.org) | Word, Excel, PowerPoint, OpenDocument, RTF | Those inputs report that LibreOffice is needed, and how to install it |
| [pandoc](https://pandoc.org) | Higher-fidelity Markdown | Markdown still converts, using the built-in renderer |

`--check-dependencies` reports what was found, and the app shows a **Missing tools** card with a
copyable `brew install` command when a queued file needs something you do not have.

## Known limitations

- **HTML/Markdown pagination slices at block boundaries.** Long documents become proper A4 pages, and
  the renderer avoids splitting paragraphs where it can, but a single element taller than a page
  (a huge code block, a very long table) will still be cut.
- **Compress is lossy.** It re-rasterises each page, so text stops being selectable and vector art is
  flattened. The app labels it as lossy; there is no "lossless shrink" mode.
- **WebP and JPEG XL can be read but not written**, because macOS itself does not write them. Rather
  than bundle a third-party encoder, the app leaves them out of the output list and says why.
- **Office documents need LibreOffice**, which is not installed for you. (Not wired up yet.)
- Builds are ad-hoc signed, not notarized, so the first launch needs a right-click → Open.

## License

[MIT](LICENSE).
