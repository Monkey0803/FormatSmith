# Contributing to FormatSmith

Thanks for taking the time to contribute. This document covers what you need to build, test and
submit changes.

## Before you start

For anything larger than a bug fix — a new conversion direction, a change to the engine's public API,
a new dependency — please open an issue first so we can agree on the shape of the change before you
write it.

## Requirements

- macOS 14 or later
- Xcode 15.3 or later (`swift --version` should print 5.10 or later)

There are no third-party Swift dependencies, and we would like to keep it that way. Everything is
built on system frameworks (PDFKit, Core Graphics, ImageIO, SwiftUI). If you think a dependency is
unavoidable, explain why in the issue.

## Getting set up

```bash
git clone https://github.com/Monkey0803/FormatSmith.git
cd FormatSmith
swift build          # compile
swift test           # run the test suite
swift run            # launch the app without building a bundle
```

To produce a real `.app`:

```bash
./scripts/build-app.sh            # dist/FormatSmith.app
./scripts/build-app.sh --install  # …and copy it to ~/Applications
```

## The bar for a change

Before opening a pull request, all three of these must be clean:

```bash
swift build -c release
swift test
swift format lint --configuration .swift-format --recursive Sources Tests
```

The repository is formatted with `swift format` using the checked-in `.swift-format`. To fix
formatting rather than just report it:

```bash
swift format --configuration .swift-format --in-place --recursive Sources Tests
```

CI runs the same commands on `macos-26`, so a green local run means a green CI run.

## Where code goes

- **`Sources/FormatSmithCore`** — the engine. It must not import SwiftUI, and it must not depend on
  anything in the app target. If a change can be tested without a window, it belongs here.
- **`Sources/FormatSmithApp`** — SwiftUI views and the CLI. Keep logic thin; push anything worth
  testing down into the core.
- **`Tests/FormatSmithCoreTests`** — unit tests, plus integration tests under `Integration/`.

## Tests

Two things matter more than coverage numbers:

1. **Pure logic gets unit tests.** Page-range parsing, output naming, the `/Rotate` transform maths
   and the format capability tables all have tests. When you touch them, extend the tests first.
2. **Rendering gets pixel tests.** Sizes alone only prove that nothing crashed. The integration tests
   generate a PDF with coloured shapes at known coordinates, render it, and sample specific pixels —
   that is how the rotation bug in this project was found. If you change anything about geometry,
   add or update a pixel assertion.

Test fixtures are generated at runtime by `FixtureFactory`. Please do not commit binary fixtures.

## User-facing strings

English is the source language, and **the English string is the key**:

```swift
Text(Localized.text("Drop files here"))
```

Add the Simplified Chinese translation to `Resources/i18n/zh-Hans.lproj/Localizable.strings`. Keep
format specifiers (`%@`, `%d`, `%.0f`) in the same order and count as the English string.
`swift test` fails if a key used in the code has no translation.

### If you add a new view that shows text

`Localized.text(...)` is a plain function, so SwiftUI has no way of knowing a view used it, and the
view will not re-render when the user switches language. Any view whose body contains localized text
must declare that dependency:

```swift
var body: some View {
    VStack { Text(Localized.text("Files")) }
        .localizedText(model.language)   // 读取当前语言 → 切换时重新取词
}
```

Views that only pass already-resolved strings to a child do not need it. For text that is *stored*
rather than recomputed each render (like the status line), store a `StatusMessage` (key + typed
arguments) and call `resolved()` in the view.

## Clickable controls

SwiftUI only hit-tests what a view actually draws. Two traps we have already been bitten by:

- `.frame(maxWidth: .infinity)` creates transparent space that is **not** clickable. Wrap the label
  in `.contentShape(Rectangle())` if the whole cell should respond.
- A `.background(...)` applied *outside* the `Button` does not extend the button's hit area; one
  applied to the label does.

Both are covered by `FormatSmithAppTests/HitAreaTests.swift`, which clicks the real view in a real
window and checks the action fired — so a regression fails CI. Use `ChipButtonStyle` for anything
that should behave like a tile or a chip rather than rebuilding the pattern.

## Commits and pull requests

- Keep commits focused; one logical change per commit.
- Write the subject line in the imperative mood ("Fix rotation for quarter-turned pages").
- Explain *why* in the body when it is not obvious from the diff.
- Add a `CHANGELOG.md` entry under `## [Unreleased]` for anything user-visible.

## Reporting bugs

Use the issue template and include your macOS version, the FormatSmith version, what you did, what you
expected, and what happened. If a specific file triggers the bug, say what kind of file it is
(page count, rotation, whether it is encrypted). Please do not attach confidential documents — a
minimal reproduction is far more useful.

## Code of conduct

Participation is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).
