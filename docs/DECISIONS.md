# OfflineReader Implementation Decisions

## 2026-06-24

- Created a standalone `OfflineReader/` Xcode project under the existing workspace because the root directory is an unrelated Cloudflare/TypeScript project.
- Used XcodeGen to keep the project reproducible and reviewable instead of hand-editing a generated `.pbxproj`.
- Declared only two direct third-party package dependencies: Readium Swift Toolkit `3.9.0` and FlyingFox `0.26.x` from `0.26.0`. Transitive dependencies are owned by those fixed packages.
- Readium 3.9.0 no longer needs `ReadiumAdapterGCDWebServer`; the project only links `ReadiumShared`, `ReadiumStreamer`, and `ReadiumNavigator`.
- EPUB import/opening follows the Readium 3.9.0 `AssetRetriever` + `PublicationOpener` APIs from the fixed tag and keeps DRM content protections empty.
- Vendored the fixed upstream tags into `Vendor/readium-swift-toolkit-3.9.0` and `Vendor/FlyingFox-0.26.0` after SwiftPM repeatedly failed to clone GitHub during local verification. This keeps the project buildable offline while preserving the fixed upstream versions required by the PRD.
- Narrowed the vendored Readium package manifest to the products used by OfflineReader (`ReadiumShared`, `ReadiumStreamer`, `ReadiumNavigator`) so SwiftPM does not resolve unused LCP, OPDS, GCDWebServer adapter, SQLite adapter, DocC, or test dependencies.
