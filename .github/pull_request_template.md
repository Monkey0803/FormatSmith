## What does this change?

<!-- One or two sentences. Link the issue it closes, if there is one. -->

Closes #

## How was it verified?

<!--
Be specific. "It builds" is not verification. Examples:
- `swift test` passes (added N tests for X)
- Manually converted a 12-page rotated PDF at 300 DPI and checked the output in Preview
- Added a pixel assertion for the corner position
-->

## Checklist

- [ ] `swift build -c release` succeeds
- [ ] `swift test` passes
- [ ] `swift format lint --configuration .swift-format --recursive Sources Tests` is clean
- [ ] New user-visible strings are in English and added to `Resources/i18n/zh-Hans.lproj/Localizable.strings`
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` (for user-visible changes)
- [ ] Engine logic lives in `FormatSmithCore`, not in a view
