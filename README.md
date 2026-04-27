# pdff

A native macOS PDF viewer, filler, and signature tool built with SwiftUI, AppKit, and PDFKit.

Website: https://pdff.viraat.dev

## Current MVP

- Open a PDF in a native PDFKit viewer.
- Detect fillable spots from real PDF widgets and common blank/checkbox patterns.
- Step through a guided field queue with trackpad haptic feedback where supported.
- Fill text, dates, checkboxes, choices, and signature fields without reflowing document text.
- Add manual text fields or checkbox squares when automatic detection misses a spot.
- Move and resize placed signatures directly on the PDF.
- Save local field memory and reusable signatures in Keychain-backed storage.
- Save a flattened filled PDF by overwriting the original or saving a new PDF.
- Optionally improve field labels with GPT-5.5 or Claude Opus 4.7 after adding an API key in Settings.

## Run

```sh
swift run pdff
```

## Build App Bundle

```sh
Scripts/build_app_bundle.sh
open .build/Pdff.app
```

To set a release version in the bundle:

```sh
PDFF_VERSION=0.2.0 PDFF_BUILD_NUMBER=12 Scripts/build_app_bundle.sh
```

## Website

The static product site lives in `web/` and is configured for Vercel.

```sh
cd web
npm run build
vercel deploy --prod
```

For GitHub Actions deployment, add these repository secrets:

- `VERCEL_TOKEN`
- `VERCEL_ORG_ID`
- `VERCEL_PROJECT_ID`

Point `pdff.viraat.dev` at the Vercel project from the DNS host for `viraat.dev`.
The Vercel project is also connected to this GitHub repo with `web/` as the root directory, so pushes to `main` deploy the site automatically.

## Test

```sh
swift test
```

## Release

Pushing a tag like `v0.2.0` runs the release workflow, builds the macOS app bundle, zips it, and publishes GitHub release assets:

- `pdff-macos.zip`
- `pdff-macos-<version>.zip`
- `checksums.txt`
