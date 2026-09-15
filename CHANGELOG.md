# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

### Removed

- Icon and game-texture container formats (ICNS, DDS, KTX, KTX2, ASTC, PVR, ATX) are no longer offered
  as output formats. Their size rules are undocumented and inconsistent; ICNS, for example, rejects
  64×64 and 1024×1024 while accepting 48×48.

[Unreleased]: https://github.com/Monkey0803/FormatSmith/commits/main
