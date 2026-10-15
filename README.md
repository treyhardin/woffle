# Font Manager

An actually good font management app for macOS.

Font Manager is a native macOS app for browsing, previewing, and activating or
deactivating the fonts on your system — without deleting them. It's built with
SwiftUI and talks directly to Core Text and AppKit for font enumeration and
activation.

## Install

Download the latest **`Font-Manager-x.y.z.dmg`** from the
[Releases page](https://github.com/treyhardin/font-manager/releases), open it, and
drag **Font Manager** to your Applications folder.

> **First launch:** the app isn't yet notarized by Apple, so macOS will warn that it
> "can't be opened." Right-click the app → **Open** (then **Open** again), or go to
> **System Settings → Privacy & Security → Open Anyway**. You only need to do this once.
> If macOS says the app is "damaged," clear the quarantine flag:
> `xattr -dr com.apple.quarantine "/Applications/Font Manager.app"`

**Homebrew** (once a tap is published):

```sh
brew install --cask --no-quarantine treyhardin/tap/font-manager
```

`--no-quarantine` skips the Gatekeeper prompt above while the app is unsigned.

The app **updates itself** via Sparkle — you'll be notified when a new version is
available — a subtle **Update Available** badge appears in the toolbar when a background
check finds one (toggle in **Settings → Updates**).

## Features

- **Browse** every font installed on macOS — system, user, and third-party.
- **Preview** fonts with customizable sample text and sizes.
- **Activate / deactivate** fonts on demand, without removing the files.
- **Search and filter** by font name, family, style, or classification.
- **Filter by classification** — serif, sans-serif, slab serif, script, blackletter, display,
  monospaced, or symbol, derived automatically from each font (no tagging needed).
- **Filter by width** — condensed, regular, or expanded.
- **Filter by foundry** — read from each font's metadata (with near-complete coverage
  via a vendor-ID fallback) and grouped so a foundry's variant names collapse together.
- **Sort** the main browse view by name (A–Z or Z–A) or most recently added. Your choice
  persists across launches. The sidebar stays A–Z, with an **A–Z bar** beside the scroll
  bar while you scroll — click or drag it to jump to a letter.
- **Show in Finder** — right-click any family in the sidebar to reveal its font files.
- **Welcome and tips** — a short first-launch welcome, a nudge to add your own fonts, and a
  couple of one-time tips.
- **Card grid** — browse all fonts as specimen cards with your own live preview text;
  click any card for full detail.
- **Auto-sync** — source folders are watched, so fonts you drop in appear automatically,
  with a toolbar indicator showing when the library last refreshed. Click it (or press ⌘R)
  to rescan now — handy for network drives changed from another machine.
- **Override Style / Width / Foundry** — when auto-detection is missing or wrong, edit the
  values yourself (foundry with autocomplete against your existing names). Overrides live
  only in this app (font files are untouched), persist on-device, and revert per-field.
  A **Needs Style** toggle surfaces every font that still needs classifying.
- **Collections** — group fonts for a project or client. Collections live in the sidebar;
  add fonts by dragging them onto a collection or from the right-click menu, and activate or
  deactivate a whole collection at once.
- **AI tools (MCP)** — connect Claude or other assistants to search your library, compare
  fonts, pull files converted for the web, read licensing info, and manage collections. For
  metadata cleanup they *suggest* edits, and you accept or reject them in Review Suggestions.
- **Multi-select** to bulk edit, activate/deactivate, or export many families at once.
- **Download as…** — export any font to your choice of format (desktop OTF/TTF,
  WOFF, or WOFF2), per style or the whole family at once. Conversion is invisible:
  pick a format and you get the file. (Apple's built-in system fonts are excluded — their
  license covers use on your Mac only.)
- **Convert fonts in either direction** — the **Convert** sheet lets you upload a
  font, detects its format, and offers one-click downloads in the other formats
  (WOFF, WOFF2, OTF, TTF). Or drop font files onto the window to add them to your
  library as activated desktop fonts.
- **MCP server (optional)** — turn on **Settings → MCP Server** to let AI tools on this
  Mac, or on other machines in your [Tailscale](https://tailscale.com) network, search
  your library and pull fonts already converted for use (WOFF2/WOFF/OTF/TTF, with a
  ready-made `@font-face`). Off by default; listens only on localhost and your Tailscale
  address, never the open network. Editing font attributes is a separate opt-in.

## Tech Stack

- **Language:** Swift 6
- **UI:** SwiftUI
- **Platform:** macOS 14.0+ (native)
- **Frameworks:** Core Text, AppKit (for the font activation/deactivation APIs)
- **Project generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Architecture

| Concern | Approach |
| --- | --- |
| Font enumeration | `CTFontManagerCopyAvailableFontFamilyNames()` and `NSFontManager` |
| Font activation | `CTFontManagerRegisterFontsForURL(_:_:_:)` (`.user` scope) |
| Font deactivation | `CTFontManagerUnregisterFontsForURL(_:_:_:)` (`.user` scope) |
| Font metadata | `CTFontDescriptor` for weight, style, classification, file path |
| Classification | CoreText symbolic traits → PANOSE (OS/2 table) → name heuristic |
| Persistence | Local activation state (UserDefaults / lightweight JSON) |
| Single-face extraction | Assembled from `CTFontCopyTable` (works across `.ttc`/`.dfont`) |
| WOFF wrap/unwrap | Pure Swift via the Compression framework (zlib) |
| WOFF2 wrap/unwrap | Bundled Google [`woff2`](https://github.com/google/woff2) + [`brotli`](https://github.com/google/brotli), via the `WOFF2Kit` C++ target |

The app sandbox is **disabled** (see `FontManager.entitlements`) because the
font activation APIs require access outside the sandbox.

Conversions are lossless container/format changes (e.g. WOFF2 ⇄ OTF). The app
does **not** redraw glyph outlines, so it never converts OTF ⇄ TTF.

## Project Structure

```
FontManager/
├── FontManagerApp.swift            # App entry point + menu commands
├── FontManager.entitlements        # App sandbox disabled (needed for font APIs)
├── FontManager-Bridging-Header.h   # Exposes WOFF2Kit to Swift
├── Models/
│   └── FontItem.swift              # FontItem and FontMember data models
├── Views/
│   ├── ContentView.swift           # Main layout + drag-to-convert + toast
│   ├── FontListView.swift          # Sidebar font list with search
│   ├── FontDetailView.swift        # Detail pane: preview + Download menus
│   ├── DirectoriesView.swift       # Browse fonts by source directory
│   ├── ConversionToast.swift       # Progress/result toast
│   └── PhIcon.swift                # Vendored Phosphor icons
└── Services/
    ├── FontService.swift           # Enumeration, activation, imported fonts, filtering
    ├── FontClassifier.swift        # Serif/sans/script… from CoreText traits + PANOSE
    ├── FontConversionEngine.swift  # Pure SFNT/WOFF plumbing (no app types)
    ├── FontConversionService.swift # Member-aware export/convert bridge
    ├── ConversionManager.swift     # Drives operations + toast state
    ├── WOFF2.swift                 # Swift wrapper over the WOFF2Kit C shim
    └── MCP/                        # Optional embedded MCP server

WOFF2Kit/                           # C++ static-lib target
├── woff2kit.h / woff2kit.cc        # extern "C" shim over woff2

ThirdParty/                         # Vendored, self-contained
├── woff2/                          # Google woff2 (encode + decode)
└── brotli/                         # Google brotli (woff2 dependency)
```

## Development

The `.xcodeproj` is generated from `project.yml` via XcodeGen and is gitignored.

```sh
# Install XcodeGen (once)
brew install xcodegen

# Regenerate the Xcode project (after a fresh clone or editing project.yml)
xcodegen generate

# Build
xcodebuild -scheme FontManager -configuration Debug build

# Build and run
xcodebuild -scheme FontManager -configuration Debug build && \
  open ~/Library/Developer/Xcode/DerivedData/FontManager-*/Build/Products/Debug/Font\ Manager.app
```

### Cutting a release

`scripts/release.sh` builds a universal Release, packages a `.dmg`, and generates the
EdDSA-signed Sparkle `appcast.xml`. It prints the `gh release create` command to publish
them (the `appcast.xml` must be a release asset so `…/releases/latest/download/appcast.xml`
resolves). Sparkle signing keys are created once with `scripts/generate-keys.sh`.

## Privacy

Font Manager collects **no** data — no analytics, no tracking, no accounts. The only
network request it makes is an **update check** against this repo's releases, which you
can turn off in **Settings → Updates**. The optional MCP server (off by default) accepts
connections only from this Mac and your own Tailscale network; it sends nothing anywhere
on its own. Your font files are never modified, and Style/Width
overrides are stored locally in `~/Library/Application Support/Font Manager/`.

## License

Font Manager is released under the [MIT License](LICENSE). Bundled third-party code keeps its own licenses:
[`woff2`](ThirdParty/woff2/LICENSE) (MIT) and
[`brotli`](ThirdParty/brotli/LICENSE) (MIT).

> Note: converting or exporting a font is your responsibility with respect to
> that font's license — some commercial fonts restrict format conversion.
