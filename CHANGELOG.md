# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-15

### Added

- A live ID photo preview in the settings panel: it shows the real output (cut-out subject, background,
  framing, exact pixel size) before you export, and the photo sheet when tiling is on. Click to
  enlarge. `IDPhotoSession` caches decoding, face detection and segmentation per photo, so changing
  size or background re-renders in milliseconds — a 12MP photo costs ~110ms once, then ~10ms per
  change. The preview and the export share that session, so the preview cannot drift from the result.
- The image pipeline now reports notes (for example "no person was detected, so the original
  background was kept") on `ConversionResult`, and the preview shows the same messages.

- ID photos: standard sizes (1-inch, 2-inch, ID card, passport, US visa and more) with a white, blue
  or red background. The subject is cut out with on-device person segmentation and the photo is
  composed around the detected face. The result can be tiled onto 5-inch / 6-inch photo paper with
  optional cut guides, ready to print.
- ID scans: `--pdf-layout two` puts two images on one page, which is what front-and-back ID scans
  need. Available as the "ID scan" preset too.
- Three new presets: ID photo, Photo sheet, ID scan.

### Changed

- Bitmaps are now created in sRGB rather than DeviceRGB. DeviceRGB follows the display, so the same
  colour value rendered differently on different machines; ID photo backgrounds in particular have to
  be exact. Colours are constructed in sRGB as well, instead of going through GenericRGB.
- Turning on ID photo mode now defaults to 300 DPI. Keeping the previous 200 DPI default produced
  197×276 px instead of the standard 295×413 px.

### Fixed

- A test target for the app itself (`FormatSmithAppTests`), starting with hit-area tests: they place a
  real view in a real window, dispatch real mouse events, and assert the action fires. Those tests
  fail against the previous implementation and pass against the fixed one.

- An in-app language switch (English / Simplified Chinese / follow system) in the settings panel and
  the menu bar. It applies immediately without a restart, and the choice is remembered.
- `--check-localization` to see how interface strings resolve per language, and a test that fails CI
  when a string used in the code has no Chinese translation.

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

### Added

- ↑ ↓ buttons on each queue row, and files now keep the order you gave them. Both matter for the ID
  scan case: `add()` used to sort everything by file name, so dragging "front" then "back" silently
  became "back" then "front" and the two sides landed the wrong way round on the page.

### Fixed

- **Picking a preset left the previous one's settings in place.** Presets are now complete recipes:
  applying one starts from defaults and keeps only your output preferences (folder, file name pattern,
  subfolder, concurrency, pixel limit). Previously settings were patched in place, so a background
  colour chosen earlier for ID photos stayed active — clicking *Print* and converting an image to PDF
  produced a solid blue page. Any setting added later is now cleared by default too.
- **Converting an image to PDF could come out as a solid blue page with the photo gone.** Vision's
  person segmentation returns a mask even when it finds nobody — an essentially black one (measured:
  0% foreground) — and the code only checked whether a mask *existed*, so it clipped everything away
  and filled the frame with the chosen background colour while reporting success. A mask with
  negligible coverage is now treated as "no person": the photo is kept, drawn to fit, and the app says
  so. Regression tests cover the empty mask, stray specks, and a real Vision run.
- The ID photo controls were hidden when the output was PDF, even though the settings still applied —
  so a background colour chosen earlier could tint a PDF with no way to see or change it. The ID photo
  card is now shown for PDF output too (the photo-sheet options, which produce an image, are not).
- `--id-photo` no longer overrides `--to pdf`; it used to silently turn the target back into a JPEG.

- Choosing "Two per page" now switches the paper setting to A4 instead of leaving the picker showing
  "Match image" while the output was A4 anyway.
- **"This resolution is over the safety limit" was reported for jobs that were nowhere near it.**
  The estimate ignored ID photo mode: with 300 DPI it computed "input size × scale", so a 12 MP photo
  became 212 MP on paper while the actual output was 295×413. Estimates are now computed per pipeline
  (ID photo spec, photo sheet paper size, image pixels × scale, PDF points × DPI), and the message
  names the real numbers.
- **Images were silently enlarged by default.** For image input, DPI was used as a magnification
  factor (200 DPI = 2.78×), so a 48 MP phone photo hit the pixel limit with the default settings.
  Images now scale from their own pixels via the scale control (1× = original), DPI applies to PDFs,
  and the CLI prints a note when `--dpi` is used on image-only input.

### Changed

- The default scale is 1× (original size) instead of 2×.

- **Photo sheets printed one giant photo instead of a grid.** `PhotoSheetTiler.layout` returned
  pixel-based rects while `render` scaled the context to points, so every cell was drawn 4× too
  large. The layout now works in points throughout, and the tests sample every cell centre plus the
  gaps between cells — a whole-sheet size check passed happily while the sheet was wrong.
- **Preset tiles only responded when you clicked the icon or the text.** Two separate causes, both
  fixed: a background applied *outside* the `Button` does not extend its hit area, and the transparent
  space from `.frame(maxWidth: .infinity)` is not hit-testable without an explicit `contentShape`.
  Clicking the gap between the icon and the label — the middle of the tile — did nothing at all.
  The same applies to the DPI/scale chips, which shared the pattern.
- The remove (×) button in the queue had a hit area of about 10pt, the size of the glyph. It now has
  padding and an explicit shape, roughly doubling the target.
- **The language switch did nothing.** `CommandLineTool.runIfNeeded()` forced English *before*
  checking whether the process was actually a command-line invocation, and the app calls it on every
  launch — so the graphical app pinned every string to the English source text. The check now happens
  first, and the debug log prints a resolved sample string so a mistake like this can be seen.
- **Switching language jumped the settings panel back to the top.** The switch used to rebuild the
  whole view tree via `.id(...)`, which also discarded scroll position and input focus. Views that
  display text now declare that dependency explicitly, so only what changed is re-evaluated.
- The status line stayed in the previous language after switching. It now stores the message key and
  typed arguments and re-resolves them, so it follows the selected language too.

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
