# pdff

A native macOS PDF viewer, filler, and signature tool built with SwiftUI, AppKit, and PDFKit.

## Current MVP

- Open a PDF in a native PDFKit viewer.
- Detect fillable spots from real PDF widgets and common blank/checkbox patterns.
- Step through a guided field queue with trackpad haptic feedback where supported.
- Fill text, dates, checkboxes, choices, and signature fields without reflowing document text.
- Save local field memory and reusable signatures in Keychain-backed storage.
- Export a flattened filled PDF.
- Optionally improve field labels with GPT-5.5 or Claude Opus 4.7 after adding an API key in Settings.

## Run

```sh
swift run pdff
```

## Test

```sh
swift test
```
