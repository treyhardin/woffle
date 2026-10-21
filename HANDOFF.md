# HANDOFF.md

_Last updated: 2026-10-13_

## Project Summary
Woffle — a native macOS (SwiftUI) app for browsing, previewing, activating/deactivating, and converting fonts. Free, open-source, distributed as an unsigned `.dmg` via GitHub Releases with Sparkle auto-updates.

## Current Status
v1.4.0 is the latest release (MCP server, Update Available badge, Blackletter, Phosphor icons). v1.3.0 added, on top of the earlier feature set (browse/search/filter, Style/Width overrides, multi-select, bidirectional WOFF/WOFF2 ⇄ OTF/TTF conversion, Sparkle updates): foundry filter + editable foundry override, a card-grid browse view with live preview text, auto-sync of source folders (FSEvents) with a toolbar status indicator, and a redesigned detail view (view-only + Edit toggle, hero specimen, pinned preview controls).

Since v1.3.0 (unreleased, in working tree): an in-app **"Update Available"** toolbar badge, shown only when a background Sparkle check finds an update (gentle reminders — no surprise modal); clicking it opens Sparkle's install prompt.

**MCP server (new, in working tree):** an embedded MCP server (Settings → "MCP Server") that lets AI tools on this Mac or across the Tailnet browse, pull, and curate fonts. Architecture, principles, tools, and out-of-scope decisions are documented in [`CLAUDE.md`](CLAUDE.md#mcp-server); code in `FontManager/Services/MCP/`. Status: three read tools (`list_attributes`, `find_fonts`, `get_font`) plus one write tool (`set_font_attributes` — edits foundry/classification/width overrides, opt-in behind the "Allow attribute editing" setting) built and verified end-to-end over localhost — valid `wOFF`/`wOF2` output, real rendered specimens, ranked/typo-tolerant name search, write gate + gap-fill/anti-clobber policy confirmed. Remote path verified from an actual Tailnet node (2026-10-13: `initialize` from rpi-4b → Mac's Tailscale IP succeeded). Note: the Mac can't reach its *own* Tailscale IP (times out) — that's a self-connection quirk, not a server issue; test from another node. Not yet released.

`set_font_attributes` was exercised at scale as a real test: a full specimen-verified categorization pass over the library classified all **444 previously-Unclassified families** (rendered contact sheets via the MCP specimens + Pillow in a scratch venv), plus width fixes. Overrides live in `~/Library/Application Support/Woffle/overrides.json` (backup from the earlier foundry pass in scratch). Added a **Blackletter** classification (`FontClassification.blackletter`) — enum case, style-button glyph, name-based auto-detection (fraktur/textura/old-english/etc., deliberately not "gothic" = sans), and MCP schema; assigned Emeritus-Trial, Digestive Demo, Salted Monthoers. "Display" was considered and rejected (says nothing about style). Art-nouveau faces (Eckmannpsych) left as Serif.

## Todo
- [x] ~~Add an in-app **"Update Available" notification**~~ — done 2026-07-15. Toolbar badge (`UpdateAvailableButton`) driven by Sparkle gentle reminders; see `UpdaterViews.swift` / `UpdaterViewModel`.
- [ ] **MCP follow-ups (nice-to-haves)**: menu-bar/toolbar "server running" indicator; consider returning font bytes as MCP resource blocks (not just base64 in structuredContent) for broader client compatibility.
- [x] ~~Settle the app license~~ — MIT (2026-10-13); README/MEMORIES aligned with `LICENSE`.
- [ ] Publish the Homebrew tap (`treyhardin/tap`)
- [ ] Notarization with an Apple Developer ID (documented later upgrade)
- [ ] Back up the Sparkle private key from the maintainer's login Keychain

## Notes for Next Session
- Regenerate the Xcode project after cloning or editing `project.yml`: `xcodegen generate` (`.xcodeproj` is gitignored).
- Build/run commands and release process are in CLAUDE.md and README; `scripts/release.sh` cuts a release.
- Never add OTF ⇄ TTF conversion — intentionally out of scope (no outline redrawing).
- General rules live in `../tc-agent/.claude/rules/`; this project is managed from the tc-agent workspace.
