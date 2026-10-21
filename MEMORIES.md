# MEMORIES.md

## Key Decisions
- License: MIT (settled 2026-10-13). Chosen over GPL-3.0 for adoption/simplicity; a closed-source rebrand is an accepted, low risk.
- Conversions are container/format changes only (WOFF/WOFF2 ⇄ OTF/TTF); OTF ⇄ TTF is intentionally out of scope — outlines are never redrawn.
- App sandbox is disabled (`FontManager.entitlements`) because font activation APIs require it.
- Distributed unsigned as a `.dmg` from GitHub Releases; notarization deferred until an Apple Developer ID is available.
- Auto-updates via Sparkle with EdDSA-signed appcast at `…/releases/latest/download/appcast.xml`.
- `.xcodeproj` is gitignored and generated from `project.yml` via XcodeGen.
- Style/Width overrides live only in the app (UserDefaults / `~/Library/Application Support/Woffle/`); font files are never modified.
- No analytics or tracking; the only network request is the Sparkle update check (toggleable in Settings → Updates).

## Useful Details
- Sparkle private signing key lives in the maintainer's login Keychain — must be backed up; without it, existing users won't accept signed updates.
- Classification cascade: CoreText symbolic traits → PANOSE (OS/2 table) → name heuristic.
- Single faces are extracted from any container (`.ttc`/`.dfont`) via `CTFontCopyTable`.
- WOFF uses the Compression framework (zlib); WOFF2 uses vendored Google woff2 + brotli via the `WOFF2Kit` C++ shim (bridging header exposes it to Swift).
- Imported fonts tracked in UserDefaults, re-activated on launch (`FontSource.imported`).
- Homebrew cask at `Casks/woffle.rb`; install requires `--no-quarantine` while unsigned.
- Targets macOS 14.0+, Swift 6.
- App is MIT-licensed (`LICENSE`, © 2026 Trey Hardin); vendored woff2 and brotli are also MIT.

## Open Questions
- When to invest in Apple Developer ID + notarization.
- Publishing the Homebrew tap.
