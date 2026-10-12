# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.7.0] - 2026-10-10

### Added

- **The CLI prints notes.** Choosing *Text (.txt)* on a scan reports "2 page(s) had no text layer and
  were recognised" in the app — and now in scripts too. A note the interface shows but the CLI hides is
  the same tool wearing two faces, and these notes are often how you tell whether the run did what you
  meant.
- **A warning before a very large output.** A 108-megapixel image needs roughly 1.3 GB of memory
  (measured: 1259 MB peak converting a 108 MP JPEG). Outputs above 40 MP now say so, and suggest a
  longest edge.
- **The CLI accepts folders** (`--convert ~/Pictures`), using the same rules as the app.

### Fixed

- **Folders ignored their subfolders — in the app as well as the CLI.** The enumeration read
  `while let child = …, isSupported(child)`, and a `while let` loop **ends** when its condition fails:
  the walk stopped at the first entry it did not recognise (a subdirectory), so files below the top
  level were never seen. Dragging a folder into the app has always missed subfolders, silently.
- **Preset descriptions lost their Chinese.** Making the preset names store an English key (so they
  follow the language setting) also hid those keys from the localization completeness scan, and the
  next regeneration of the translation table deleted all 20 entries. The scan now covers that entry
  point — the point of the test being that a table rebuilt from usage must not silently drop text.

## [1.6.0] - 2026-10-10

### Added

- **The text preview shows the text.** Choosing *Text (.txt)* now displays what will actually be
  written, instead of only the source picture — a preview that shows the input tells you nothing about
  the output.
- **Page selection for PDF → text** (`--pages`), with the order you write preserved, matching
  *Extract pages*. Choosing pages now also makes the panel show the page controls again.

### Fixed

- **Concurrent conversions overwrote each other's output — silently.** Converting 500 files with a
  fixed filename pattern reported success 500 times while only 322 files landed: each task looked up a
  free name, several computed the same one, and they wrote over each other. The same thing happened
  with two same-named files from different folders under a `{name}` pattern. Output names are now
  reserved atomically inside the process, so every file survives (verified: 500 files → 500 outputs,
  all non-empty).
- **Preset names and descriptions ignored the language setting.** `PresetLibrary.all` is a `static let`,
  and the names were resolved once at construction, so switching to Simplified Chinese left the preset
  tiles reading Web / Email / Print… The names now store the English key and resolve on every read.

## [1.5.0] - 2026-10-10

### Added

- **Images can go straight to text.** Choosing *Text (.txt)* — or `--to text` — turns a photo or a
  screenshot into a `.txt` file in one step, with no detour through PDF. PDFs use the same target and
  keep the per-page rule: pages that already carry a text layer are reused, only scans are recognised.
- Settings that cannot affect text output (quality, background, longest edge, metadata, ID photo) are
  now correctly reported as inactive in that mode, and DPI applies only to PDF input, where it changes
  the resolution the pages are recognised at.

### Fixed

- **Saved settings could silently reset on upgrade.** Swift's synthesised decoder requires every key to
  be present, so adding *any* field to the settings made previously saved settings fail to decode —
  and the caller recovers with `try?` plus defaults, so the user's configuration quietly reverted and
  looked like their own mistake. Every field now decodes with `decodeIfPresent` (37 of them), which
  makes future additions safe too.

## [1.4.0] - 2026-10-10

### Added

- **Text output (OCR).** A scanned PDF becomes a `.txt` file. Pages that already carry a text layer are
  reused as they are, and **only pages that are pure images are recognised** — a half-typed,
  half-scanned document keeps its accurate text instead of being re-recognised wholesale. The result
  reports how many pages had to be recognised.
- **The queue shows what came out.** `Done · 5 file(s) written · 2.4 MB → 380 KB`, comparing the source
  with the real size on disk.
- **`--preset`** on the command line, by the ten preset names. A preset is a starting point: switches
  given after it still win.
- **Reordering by dragging a row**, using the platform's own list mechanism.

### Fixed

- **The toolbox preview contradicted the output.** On a three-page document, "Extract 3" previewed
  page 1 while the output began with page 3; the page count shown was the input's; the Rotate preview
  claimed rotated dimensions while the picture stayed put. The preview now takes its page order from
  the same single source the real operations use, and a rotation tool rotates what you see.
- **⌘A did nothing.** The item was added *next to* the system's own Select All, so two ⌘A collided and
  the system's won — which does nothing when no text field has focus. The app now owns the key, and
  asks the responder chain first, so ⌘A still selects text inside a text field.
- **Escape did not clear the selection.** A menu shortcut for Escape is swallowed by the system's
  cancel handling, and `onExitCommand` needs focus the queue does not have.
- **The queue's selection, context menu and drag reordering were never wired to the interface.** The
  model logic and its tests were all in place; the view code existed but was never attached to a row,
  so clicking and dragging did nothing while the suite stayed green.

## [1.3.0] - 2026-10-10

### Added

- **Queue selection and batch removal.** Click to select, ⌘-click to add or remove, ⇧-click for a
  range, ⌘A for all, ⌫ to remove the selection. Removing fifty files no longer means fifty clicks on a
  small ×.
- **A context menu on every row** — Show in Finder, Copy File Name, Remove (or "Remove N files"),
  Show Output in Finder, Select All / Deselect All. Right-clicking a list is second nature on macOS;
  these were previously only reachable through tiny row buttons.
- **Undo after removing.** A bar offers "Removed N file(s) · Undo" and restores them **to their
  original positions**, not appended at the end.
- **Appearance: Follow system / Light / Dark**, remembered across launches.
- **⌘1…⌘0 apply the ten presets**, and a *Keyboard Shortcuts* panel in the Help menu — shortcuts
  nobody can find are shortcuts nobody uses.
- **A notification when a long run finishes** (over 20 seconds). Recognising several hundred scanned
  pages takes minutes; small batches stay quiet.
- Accessibility labels on the icon-only row buttons (remove, move up, move down), which previously
  announced nothing.

### Fixed

- **The status line stayed English in a Chinese interface.** The localization completeness test only
  scanned `Localized.text(...)`, while status messages go through `StatusMessage(...)` — so 15 runtime
  messages (added N files, converting, finished, output folder not writable …) had no translation
  while the suite stayed green. The translations are in, and the scanner now covers both entry points.
- **Switching from Dark back to Follow system did nothing.** SwiftUI's `preferredColorScheme` applies a
  scheme but does not release it when the value becomes nil, so a light system kept a dark window. The
  app now uses `NSApp.appearance`, where "follow system" genuinely means nothing is pinned.

## [1.2.0] - 2026-10-10

### Added

- **Searchable PDFs (OCR).** A scanned PDF becomes searchable: each page is rasterised, the text is
  recognised on-device with Vision, and an **invisible** text layer is written on top. What you see is
  still the original scan; what you search, select and copy is real text. Marked as lossy, like
  Compress, because the pages are rebuilt.
- **Reorder and delete PDF pages.** *Reorder* moves the pages you list to the front and keeps the rest
  in order — it never drops a page, so a typo cannot silently cost you pages. *Delete* removes the
  pages you list. Both share the page-list field with Extract, labelled for what each one does.
- **Metadata policy** — *Keep everything* (the new default), *Remove location*, or *Remove all
  metadata* (`--metadata`). Previously camera, capture time and GPS were silently discarded.
- **Animated GIFs keep their animation** when the target is GIF and nothing resizes the image, with
  frame delays and loop count preserved. When animation cannot be kept (another format, or a resize)
  the result says so and points at GIF instead of quietly returning one frame.
- **About panel** replaced the system default: version, repository and download links, and the fact
  that files never leave the machine. The empty state now lists the three steps for a first run.

### Fixed

- **Rotating a photo twice.** Now that metadata is carried over, the EXIF orientation had to be
  cleared: the pixels are already uprighted during decode, so writing the tag back would make viewers
  rotate an already-correct image. Verified with an orientation-6 source (800×600 in, 600×800 out,
  orientation 1). Stale pixel dimensions are dropped for the same reason.
- **`3,1` did not mean 3 then 1.** The page-range parser sorts its result, which is right for a set of
  pages but destroys a page *order* — reorder could not work. Added an order-preserving parse, now
  used by both Reorder and Extract.
- **Picking Delete with the range mode left on "All" could only fail.** Choosing a page-list tool now
  switches the mode to custom, so the state is never a dead end.
- The README claimed Office conversion was "(Not wired up yet.)" while Word → PDF works; the note now
  describes reality (LibreOffice is detected, not bundled).

## [1.1.0] - 2026-09-16

### Added

- **Longest-edge limit for images** (Original / 1600 / 2048 / 4096 px, `--max-edge`). The Web and Email
  presets claimed to produce smaller files but only changed format and quality — a 48 MP photo came out
  at 48 MP. They now cap the longest edge, and the limit never enlarges a smaller image.
- **`SettingsScope`**: one place that answers whether a setting applies to the current inputs and
  target. The panel derives section visibility from it, and tests assert both the matrix and the
  invariant that an inactive setting cannot change the output. A wiring test fails when a rule is not
  consulted anywhere.
- Images, HTML, Markdown and plain text are declared as openable types (rank *Alternate*), so images
  can be opened with FormatSmith and dropped on its Dock icon.
- **Preview for every pipeline**, not just ID photos: composed PDF pages, page 1 of a PDF at the
  chosen DPI, Office/HTML conversions, ID photos and photo sheets. Large outputs are drawn as
  thumbnails while the caption keeps the real pixel or point size, and page/file counts are shown.
  Preview and export share `PDFComposer.drawPage`, so the layout cannot drift.
- **Batch summary with retry and drag-out**: after a run you see how many succeeded, which files
  failed and why, with one-click retry that re-runs only the failed items, plus dragging a result
  straight out to Finder or another app.
- Two presets for the most common jobs: **Images to PDF** (one PDF, one page per image, original
  size) and **PDF to images** (PNG per page at 150 DPI). Previously converting images to PDF meant
  picking the Print preset — which produces TIFF — and then switching the output format by hand.
- The pixel limit is adjustable in the Output card (120 MP to 1000 MP) instead of being a source-only
  setting.
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
- A test target for the app itself (`FormatSmithAppTests`), starting with hit-area tests: they place a
  real view in a real window, dispatch real mouse events, and assert the action fires. Those tests
  fail against the previous implementation and pass against the fixed one.
- An in-app language switch (English / Simplified Chinese / follow system) in the settings panel and
  the menu bar. It applies immediately without a restart, and the choice is remembered.
- `--check-localization` to see how interface strings resolve per language, and a test that fails CI
  when a string used in the code has no Chinese translation.
- ↑ ↓ buttons on each queue row, and files now keep the order you gave them. Both matter for the ID
  scan case: `add()` used to sort everything by file name, so dragging "front" then "back" silently
  became "back" then "front" and the two sides landed the wrong way round on the page.

### Changed

- **The execution dispatch now lives in one place.** Merge-into-one-PDF, whole-batch PDF tool, or
  per-file — `ConversionEngine.run` decides once and both the app and the CLI call it. Previously each
  kept its own copy of that branch (about forty duplicated lines), which is precisely how two entry
  points drift apart. `run` also guarantees the observer is notified for every result, including the
  merged and whole-batch paths, which previously reported nothing.
- Bitmaps are now created in sRGB rather than DeviceRGB. DeviceRGB follows the display, so the same
  colour value rendered differently on different machines; ID photo backgrounds in particular have to
  be exact. Colours are constructed in sRGB as well, instead of going through GenericRGB.
- Turning on ID photo mode now defaults to 300 DPI. Keeping the previous 200 DPI default produced
  197×276 px instead of the standard 295×413 px.
- The default scale is 1× (original size) instead of 2×.

### Fixed

- **Size-dependent settings silently did nothing for some callers.** `SourceDocument.make(from:)` never
  populated the size or page count, so anything that scales by the source dimensions — the new
  longest-edge limit, output estimates — was a no-op for any caller that had not inspected separately.
  A document now knows its own size and page count.
- **The metadata pass could overwrite a finished item.** The asynchronous inspection wrote `.ready`
  unconditionally, so it could reset an item that had already been converted (or had failed) back to
  "waiting". It now only touches the status while the item is still loading.
- "Cannot read bad.jpg files." — the file-level and format-level errors shared one message template, so
  a file name was substituted into a sentence written for format names. Split into
  `unreadableFile()` ("Cannot read this file.", the file name is already shown next to it) and
  `unreadableFormat(_:)` ("This Mac cannot read %@ files.").
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

[Unreleased]: https://github.com/Monkey0803/FormatSmith/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/Monkey0803/FormatSmith/releases/tag/v1.7.0
[1.6.0]: https://github.com/Monkey0803/FormatSmith/releases/tag/v1.6.0
[1.5.0]: https://github.com/Monkey0803/FormatSmith/releases/tag/v1.5.0
[1.4.0]: https://github.com/Monkey0803/FormatSmith/releases/tag/v1.4.0
[1.3.0]: https://github.com/Monkey0803/FormatSmith/releases/tag/v1.3.0
[1.2.0]: https://github.com/Monkey0803/FormatSmith/releases/tag/v1.2.0
[1.1.0]: https://github.com/Monkey0803/FormatSmith/releases/tag/v1.1.0
[1.0.0]: https://github.com/Monkey0803/FormatSmith/releases/tag/v1.0.0
