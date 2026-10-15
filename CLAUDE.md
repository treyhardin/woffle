# font-manager

An actually good font management app for macOS.

## Tech Stack

- **Language**: Swift
- **UI**: SwiftUI
- **Platform**: macOS (native)
- **Key Frameworks**: Core Text, AppKit (for font activation/deactivation APIs)

## Features

- Browse all fonts installed on macOS (system, user, and third-party)
- Preview fonts with customizable sample text and sizes
- Activate and deactivate fonts without deleting them
- Search and filter by font name, family, style, or classification
- Collections in the sidebar: fixed (All / Active / Inactive / Missing Info), smart (rule-based,
  live), and manual (drag fonts onto one to add)

## Architecture

- **Font enumeration**: `CTFontManagerCopyAvailableFontFamilyNames()` and `NSFontManager`
- **Font activation**: `CTFontManagerRegisterFontsForURL(_:_:_:)` with `.user` scope
- **Font deactivation**: `CTFontManagerUnregisterFontsForURL(_:_:_:)` with `.user` scope
- **Font metadata**: `CTFontDescriptor` for weight, style, classification, file path
- **Persistence**: Track activation state locally (UserDefaults or lightweight JSON file)

## Conventions

This project is managed from the [tc-agent](../tc-agent/CLAUDE.md) workspace.
General rules and patterns are in `../tc-agent/.claude/rules/`.

## Project Structure

```
FontManager/
├── FontManagerApp.swift            # App entry point + menu commands
├── FontManager.entitlements        # Open-source build: not sandboxed
├── FontManager-AppStore.entitlements # App Store build: sandboxed (+ bookmarks, network server)
├── PrivacyInfo.xcprivacy           # Privacy manifest (UserDefaults, file timestamps)
├── Resources/Acknowledgements.txt  # Third-party notices (scripts/generate-acknowledgements.sh)
├── Resources/Fonts/PirataOne/      # OFL font for the Blackletter filter label (loaded, never registered)
├── FontManager-Bridging-Header.h   # Exposes WOFF2Kit to Swift
├── Models/
│   └── FontItem.swift              # FontItem and FontMember data models
├── Views/
│   ├── ContentView.swift           # Main layout + drag-to-convert + toast
│   ├── FontListView.swift          # Filters sidebar: search, collections, Style/Width chips, Foundry list
│   ├── FontListColumn.swift        # Font list shown between sidebar and detail once a font is open
│   ├── SmartCollectionEditor.swift # Create/edit smart collection rules
│   ├── FontDetailView.swift        # Detail pane: preview + Download menus
│   ├── DirectoriesView.swift       # Browse fonts by source directory
│   ├── ConversionToast.swift       # Progress/result toast
│   ├── AlphabetScrubber.swift      # A–Z jump bar (sidebar + browse pane)
│   ├── CollectionsViews.swift      # Sidebar collections, Add to Collection menu, name alert
│   ├── ReviewSuggestionsView.swift # Toolbar Review button + sheet for AI-suggested edits
│   ├── WelcomeView.swift           # First-launch welcome + Get Started banner
│   ├── Tips.swift                  # TipKit contextual tips
│   ├── SettingsView.swift          # Settings (Updates section open-source only)
│   ├── UpdaterViews.swift          # Sparkle — compiled out of the App Store build
│   ├── AcknowledgementsView.swift  # Help → Acknowledgements window
│   └── PhIcon.swift                # Ph enum + PhIcon/PhLabel for vendored Phosphor icons
└── Services/
    ├── FontService.swift           # Enumeration, activation, imported fonts, filtering
    ├── AppEnvironment.swift        # Data location + ephemeral Preview mode (open-source Debug)
    ├── BundledFonts.swift          # Loads bundled UI fonts from file (not registered with macOS)
    ├── FontService+Collections.swift # Collections CRUD + collections.json persistence
    ├── FontService+Suggestions.swift # AI suggestion queue (accept/reject) + suggestions.json
    ├── BookmarkStore.swift         # Security-scoped bookmarks for folders/imports
    ├── FontClassifier.swift        # Serif/sans/script… from CoreText traits + PANOSE
    ├── FontConversionEngine.swift  # Pure SFNT/WOFF plumbing (no app types)
    ├── FontConversionService.swift # Member-aware export/convert bridge
    ├── ConversionManager.swift     # Drives operations + toast state
    ├── WOFF2.swift                 # Swift wrapper over the WOFF2Kit C shim
    └── MCP/                        # Embedded MCP server (see "MCP server" below)
        ├── MCPServerController.swift  # Settings/lifecycle + Tailscale IP auto-detect
        ├── FontMCPServer.swift        # SDK Server + transport + tool registration
        ├── HTTPListener.swift         # Hand-written NWListener ↔ HTTPRequest bridge
        ├── TailnetOriginValidator.swift # Allows loopback/Tailscale/*.ts.net hosts
        ├── FontMCPTools.swift         # find_fonts / get_font / list_attributes logic
        ├── FontMCPWrite.swift         # set_font_attributes (override edits via FontService)
        ├── FontMCPInfo.swift          # get_font_info (licensing), compare_fonts, convert_font
        ├── FontMCPActions.swift       # collections, set_fonts_active, refresh, suggestions
        ├── FontMCPModels.swift        # Catalog snapshot, CSS weight, specimen render
        └── MCPSettingsView.swift      # "MCP Server" section in Settings

WOFF2Kit/         # C++ static-lib target: extern "C" shim over Google woff2
ThirdParty/       # Vendored woff2 + brotli sources (self-contained)
```

## Icons

UI icons are [Phosphor](https://phosphoricons.com) (Regular weight), vendored as
individual SVGs — only the glyphs actually used — under `Assets.xcassets/ph-*.imageset`
(template-rendered, vector-preserved). Render them via `PhIcon(.name)` / `PhLabel(_,
icon:)` (see `Views/PhIcon.swift`); tint with `.foregroundStyle`. Phosphor glyphs aren't
SF Symbols, so they take an explicit point size and don't auto-scale to font. Menu-item
checkmarks intentionally stay SF Symbols (`checkmark`) since macOS manages their layout.
To add an icon: drop `assets/regular/<name>.svg` from `phosphor-icons/core` into a new
`ph-<name>.imageset` and add a `Ph` case.

## Layout

Landing: filters sidebar + browse grid. Opening a font adds a persistent font list column
(same filters and order as the grid, with a sticky "‹ All Fonts" back link, ⌘[) between the
sidebar and the detail view. The sidebar holds only search, collections and filters; the
Foundry list stretches to fill the remaining height (the sidebar falls back to scrolling as a
whole only when the window is too short). Style/Width chip labels are set in representative
system fonts (Pirata One for Blackletter) and optically centered from font metrics.

## Data and Preview mode

The **App Store build is the maintainer's real-data app** during development (sandbox
container `~/Library/Containers/co.trumancreative.FontManager`). The **open-source Debug
build is "Font Manager (Preview)"** (bundle ID `co.trumancreative.FontManager.preview`): it
wipes its settings, collections, edits, suggestions and tips on every launch
(`AppEnvironment.resetIfPreview`) — for testing first-run flows. Font activation is
system-wide in macOS, so Preview's activations are real. To test MCP in Preview without
persisting anything, pass settings as launch arguments:
`open "Font Manager (Preview).app" --args -mcp.enabled YES -mcp.port 8789 -mcp.allowWrites YES`.

## Two builds

One codebase, two app targets in `project.yml` (sources shared):

- **`FontManager`** — open-source build (GitHub download / Homebrew). Not sandboxed;
  Sparkle auto-updates; `scripts/release.sh`.
- **`FontManagerAppStore`** — Mac App Store build. Sandboxed, no Sparkle (the App Store
  updates it), `APPSTORE` compile flag. Debug builds are named "Font Manager (App Store)"
  so they don't overwrite the other app; Release keeps the real name.

Put anything build-specific behind `#if APPSTORE`; prefer shared code that works in both
(e.g. folder/import access always goes through `BookmarkStore`, which is required in the
sandbox and harmless outside it). Both builds share a bundle ID, so macOS migrates the
open-source build's preferences into the App Store sandbox on first launch.

Rules both builds follow: Apple-supplied fonts (anything under `/System/`) are never
exported or converted (`FontMember.isExportable`, enforced in `FontConversionService`);
only fonts the app registers (source folders, imports) can be activated/deactivated
(`FontItem.canToggleActivation`); no links to the GitHub download inside the app.

## Font conversion

Export ("Download as…") and web-font import share one engine. Container/format
conversions only (WOFF/WOFF2 ⇄ OTF/TTF) — outlines are never redrawn, so OTF ⇄ TTF
is intentionally out of scope. WOFF2 uses bundled `woff2`+`brotli` via `WOFF2Kit`;
WOFF uses the Compression framework; single faces are extracted from any container
via `CTFontCopyTable`. Imported fonts are tracked in UserDefaults and re-activated
on launch (`FontSource.imported`).

## MCP server

An optional embedded [MCP](https://modelcontextprotocol.io) server (Settings → "MCP
Server") lets AI tools — on this Mac or across a Tailnet — browse the font library and
pull specific fonts, converted for use. It exists so agents working on other machines
(e.g. a Raspberry Pi) can reach the library the app already sees; the NAS flows through
automatically when mounted as a watched directory.

**Design principles.** (1) *Acquisition, not runtime* — agents discover fonts and copy
files once; nothing built with it depends on the server staying up. (2) *User-managed* —
it only exposes files the user already has; licensing is the user's responsibility (no
gating). (3) *Agent-facing* — outputs (metadata, `@font-face`, bytes) are for a program,
not copy/paste. (4) *Reuse* — metadata/conversion come from `FontService` /
`FontConversionService`, no parallel font logic.

**Architecture.** Embedded in the app (not a daemon — acquisition is deliberate and
one-time, so "open the app to pull fonts" is fine). Built on the official Swift SDK
(`MCP` package, `modelcontextprotocol/swift-sdk`) using its `StatelessHTTPServerTransport`
for MCP/JSON-RPC correctness; only the socket layer is hand-written (`HTTPListener`, an
`NWListener` ↔ `HTTPRequest` bridge). Binds `127.0.0.1` plus the auto-detected Tailscale
IP (100.64.0.0/10 scan; localhost-only when Tailscale is down) — **never `0.0.0.0`**;
the Tailnet is the auth boundary. `TailnetOriginValidator` allows loopback / Tailscale /
`*.ts.net` hosts and rejects the rest (DNS-rebinding protection). The SDK `Server` is
single-shot, so `FontMCPServer` rebuilds a clean server on each `initialize` (listeners
stay long-lived) — lets any client/reconnect handshake cleanly.

**Read tools** (`FontMCPTools`): `list_attributes` (classifications, widths, sources,
foundries+counts, collections+counts, weight range); `find_fonts` (name/classification/width/
source/collection/weight filters, ranked+typo-tolerant name search, pagination, opt-in PNG specimens); `get_font`
(deliver faces as woff2 default / woff / otf / ttf — base64 bytes by default, or written
to a Mac-reachable `destination` — in the App Store build only inside the MCP Delivery Folder
or a source folder; includes a correct `@font-face`). Apple system fonts are never delivered. The catalog is
snapshotted per request on the main actor (override-aware) via
`FontCatalog.snapshotWhenReady`, which briefly waits if enumeration is still in flight.
CSS numeric weight (100–900) is derived from the style name — `FontMember.weight` is an
internal CoreText scale, not CSS weight.

**Goal: agent parity.** Anything a user can do in the app, an agent can do over MCP, with bulk
metadata cleanup as the headline use. Additional read tools: `get_font_info` (detected vs.
effective values, overrides, collections, files, name-table licensing + decoded OS/2 embedding
permissions), `compare_fonts` (one labeled side-by-side PNG), `convert_font` (stateless, bytes
in/out), and `get_font` by `family` + `weights`/`styles`. Always allowed:
`suggest_font_attributes` / `list_suggestions` (the **preferred** edit path — suggestions queue
in the app's Review Suggestions sheet and change nothing until the user accepts) and
`refresh_library`. Behind **"Allow changes"** (`mcp.allowWrites`): `set_font_attributes`,
`create_collection`, `update_collection`, `set_fonts_active`. Settings → MCP Server →
"Connect an AI Tool…" gives copy-paste setup for Claude Code, Claude Desktop (via
`mcp-remote`), and URL-based clients. Not exposed by design: adding/removing source folders
and changing the app's own settings (both need a person at the Mac).

**Direct edits** (`FontMCPWrite`): `set_font_attributes` lets a client curate the catalogue
— batch-edit foundry / classification / width overrides (or `clear` them) per family,
through the same `FontService` setters the UI uses, so edits persist and update the app
live. **Gated behind the `mcp.allowWrites` setting (default off)** — Settings → MCP Server
→ "Allow changes"; refused with an error when off. Policy: by default only
*fills gaps* (Unknown foundry, Unclassified classification, un-overridden width) and never
overwrites an existing value — `force:true` overwrites. Returns per-family applied/skipped
results plus resulting effective values so the agent can verify. (The gap-fill default
exists because embedded font metadata is often better than a guess — don't clobber it.)

**Cross-machine delivery.** The server is on the Mac; the consuming agent runs on the
target machine. So `get_font` returns bytes *through* the agent (it writes them locally),
rather than the Mac pushing files over the network. Optional `destination` writes to a
path the Mac can already see (NAS/synced/local).

**Out of scope (by design):** OTF ⇄ TTF conversion (project-wide rule); a headless
always-on daemon; auth beyond the network boundary; licensing/embed gating; richer query
criteria (glyph/language coverage, variable axes, "similar to") — deferred until the core
loop proves out.

## Development

```sh
# Regenerate Xcode project (after changing project.yml)
xcodegen generate

# Build
xcodebuild -scheme FontManager -configuration Debug build

# Build and run
xcodebuild -scheme FontManager -configuration Debug build && open ~/Library/Developer/Xcode/DerivedData/FontManager-*/Build/Products/Debug/Font\ Manager.app
```

The `.xcodeproj` is generated from `project.yml` via XcodeGen and is gitignored.
To regenerate it after a fresh clone: `xcodegen generate`.

## Distribution

- Free, open-source (MIT). Distributed as a `.dmg` from GitHub Releases; **unsigned**
  for now (notarization is a documented later upgrade — needs an Apple Developer ID).
- Auto-updates via **Sparkle** (appcast at `…/releases/latest/download/appcast.xml`,
  EdDSA-signed). The signing **private key lives in the maintainer's login Keychain** —
  back it up; without it you can't sign updates existing users will accept.
- `scripts/release.sh` builds a universal `.dmg` + signed appcast; `scripts/generate-keys.sh`
  creates the Sparkle key (one-time). Homebrew cask in `Casks/font-manager.rb`.

Update this file as the project evolves.
