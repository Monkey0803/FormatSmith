# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-15

### Added

- Presets: Web (2× PNG), Email, Print (300 DPI TIFF), Archive, and Scanned PDF, each setting format,
  resolution, quality and background in one click.
- Parallel conversion: `ConversionEngine.convertBatch` runs several files at once, capped at 4 by
  default and configurable in the app or per batch. Progress events now carry the document they
  belong to, so concurrent runs report accurately.
- The CLI uses the same batch engine, so `--convert` with many files is no longer serial.

- Document → PDF: Office, OpenDocument and RTF via a locally installed LibreOffice (run headless with
  a private profile so it never collides with the copy you have open); HTML, Markdown and plain text
  via WebKit with no extra dependency. Markdown prefers pandoc and falls back to a built-in renderer.
- `ToolLocator` and `--check-dependencies`: detects LibreOffice and pandoc from an environment
  override, well-known install locations, or `PATH`, and the app shows a Missing tools card with a
  copyable install command when a queued file needs one.
- An external process runner with a hard timeout, and a main-thread bridge so WebKit work is safe to
  call from a background conversion *and* from the command line.

- PDF toolbox: merge several PDFs, split every N pages, extract a page selection, rotate by
  90/180/270°, and compress by re-rasterising at a lower DPI. Available from the app's PDF tool
  picker and from the CLI (`--pdf-tool`, `--split-every`, `--rotate`).
- Image → image conversion: any readable format to any writable one, with scaling from 0.5× to 4×
  (or any custom factor). WebP, JPEG XL, HEIC and camera RAW files can now be used as input.
- Image → PDF conversion, including merging a multi-file selection into one document. Page size can
  match the image (1 px = 1 pt) or fit A4/Letter with a configurable margin, and embedded images can
  optionally be JPEG-compressed to shrink the output.
- `ConversionRouter`: one table that decides which pipeline a combination uses, shared by the app and
  the CLI. Combinations that are planned but not built yet, and those that are impossible, are
  reported with a reason instead of failing generically.
- CLI: `--to pdf`, `--pdf-page-size`, `--pdf-margin`, `--pdf-compress`, `--merge` / `--no-merge`,
  `--subfolder`, and image inputs for `--convert`.
- `FormatSmithCore` library split out from the app so the conversion engine can be tested headlessly.
- Runtime capability detection for image formats, driven by ImageIO instead of a hardcoded list.
- English/Simplified-Chinese localization (`Resources/i18n`), with English source strings as the keys.
- Test suite: page-range parsing, output naming, `/Rotate` transform math, format registry, settings
  persistence, plus pixel-level integration tests that render real PDFs and sample the result.
- Scripts for building the app bundle, generating the icon, and packaging a DMG.

### Changed

- Renamed the project from `PDF2Image` to `FormatSmith` to match its broader scope.
- Output file names for JPEG now use the `.jpg` extension (the system reports `.jpeg`).
- CLI output is always English, whatever the system language, so scripts can parse it. The app window
  remains localized.
- Images embedded in a PDF are no longer silently upscaled: they are placed at their native pixel
  size, because DPI is a PDF concept and the 200 DPI default was scaling photos by 2.78×.
- The CLI writes straight into `--out` by default; pass `--subfolder` for a folder per source file.
  The app keeps per-file folders on by default.
- `InputKind` recognises image files by extension when no UTType is available.

### Fixed

- Non-alpha formats (JPEG, BMP, HEIC, AVIF) with a transparent background filled nothing, producing
  a black background instead of white.
- Scaling an image up (`2x` and above) silently returned the original size, because the ImageIO
  thumbnail API never upscales.
- File name templates left a trailing separator when a placeholder expanded to nothing (`{name}-{page}`
  for single-image output produced `photo-.png`).
- ICO output that is not a 16–256 px square now reports what is wrong instead of a generic
  "finalize failed" error.

### Fixed

- Long HTML and Markdown documents no longer collapse into a single page thousands of points tall.
  `WKWebView.pdf(configuration:)` does not paginate, so the converter measures block positions and
  slices the content into A4 pages itself.

### Changed

- Conversion failures show their full message in the queue (wrapped over two lines and available as a
  tooltip) instead of being cut off.

### Removed

- Icon and game-texture container formats (ICNS, DDS, KTX, KTX2, ASTC, PVR, ATX) are no longer offered
  as output formats. Their size rules are undocumented and inconsistent; ICNS, for example, rejects
  64×64 and 1024×1024 while accepting 48×48.

[Unreleased]: https://github.com/Monkey0803/FormatSmith/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Monkey0803/FormatSmith/releases/tag/v1.0.0
