# OfflineReader

OfflineReader is an iOS/iPadOS 18+ offline EPUB reader MVP implemented from `docs/OfflineReader_iOS_MVP_PRD.md`.

## What is included

- SwiftUI library, import, reader, typography, table of contents, notes placeholder, and book grouping screens.
- SwiftData-backed local library with EPUB, PDF, and TXT file install/delete handling.
- EPUB/PDF/TXT validation, SHA-256 duplicate detection, and Readium Swift Toolkit based EPUB/PDF opening.
- Local Files import plus same-Wi-Fi browser upload flow with token-gated multi-file chunked uploads.
- Unit tests for file storage, hashing, publication opening, TXT/PDF reader sessions, and upload sessions; UI smoke tests cover the library shelf and group editing flow.

## Build

```sh
cd OfflineReader
xcodegen generate
xcodebuild -project OfflineReader.xcodeproj -scheme OfflineReader -destination 'platform=iOS Simulator,id=<simulator-udid>' -skipPackagePluginValidation test
```

You can also run the CI script. It uses the booted simulator when one is available, otherwise the first available iPhone simulator.

```sh
cd OfflineReader
./Scripts/ci.sh
```

If your simulator has a different name, override it:

```sh
DESTINATION='platform=iOS Simulator,name=iPhone 15,OS=18.5' ./Scripts/ci.sh
```

Dependencies are vendored under `Vendor/` so the project can build without re-cloning GitHub packages during verification.

The app intentionally has no account system, cloud sync, analytics SDK, book store, DRM support, online TTS, or audiobook/listen mode.
