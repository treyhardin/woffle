# HANDOFF.md

_Last updated: 2026-10-20_

## Project Summary
**Woffle** (formerly "Font Manager") — a native macOS (SwiftUI) font manager by Truman Creative
(woffle.io). Organize a whole font library (local or NAS), label and collect it, activate fonts on
demand, convert web fonts, and serve the library to AI tools through an embedded MCP server.
Two builds from one codebase: a free open-source build (GitHub `.dmg` + Sparkle) and a paid,
sandboxed Mac App Store build (in preparation). Repo: `treyhardin/woffle`.

## Current Status
Last release: **v1.4.0** (as "Font Manager"). Everything below is on `main`, unreleased:

- **Rename to Woffle** — app names, bundle IDs `co.trumancreative.Woffle` / `.Woffle.preview`,
  MCP server name `woffle`, repo, Sparkle feed, cask. Internal Xcode targets/folders stay
  `FontManager` on purpose. Old `co.trumancreative.FontManager` data moved to Trash (the old
  sandbox container must be deleted by hand in Finder); overrides were copied into the new
  Woffle App Store container.
- **Layout** — filters-only sidebar (search → collections → Style/Width chips → Foundry list that
  fills the height); landing = sidebar + grid; opening a font adds a persistent filtered font list
  column with a sticky "‹ All Fonts" back link.
- **Collections** — fixed (All/Active/Inactive/Missing Info, empty ones hidden), smart (rule-based,
  live) with an editor sheet, and manual (drag to add). Activate/Deactivate All per collection.
- **MCP agent parity** — 13 tools incl. `get_font_info` (licensing), `compare_fonts`,
  `convert_font`, collection tools (smart rules too), `set_fonts_active`, `refresh_library`, and
  `suggest_font_attributes` → in-app **Review Suggestions** sheet. "Allow changes" gates direct edits.
  Connect an AI Tool sheet in Settings.
- **App Store prep** — `FontManagerAppStore` target (sandboxed, no Sparkle, `APPSTORE` flag),
  security-scoped bookmarks, Grant Access banner, privacy manifest, Acknowledgements, no
  system-font export, welcome sheet + TipKit tips. Debug open-source build = ephemeral
  **"Woffle (Preview)"**; Debug App Store build = maintainer's real-data app.

## Todo
- [ ] **App icon + wordmark** — Trey is designing; specs given 2026-10-20 (Icon Composer `.icon`
      or 1024px master, see chat/README when added).
- [ ] **woffle.io site** — new sibling project `../woffle-site` (Astro): landing, privacy, support
      (privacy + support URLs are required by App Store Connect).
- [ ] **Apple Developer setup** — follow `docs/APP_STORE_SETUP.md` (agreements, certificates,
      bundle ID, App Store Connect record named "Woffle", TestFlight).
- [ ] TestFlight: verify folder access + bookmarks in a properly signed sandbox build.
- [ ] Developer ID signing + notarization for the GitHub build; test Sparkle update 1.4.0 →
      Woffle (name + bundle ID change) before publishing; bump to 1.5.0.
- [ ] Brand checks: USPTO/EUIPO search for "Woffle"; optional courtesy note to Source Foundry
      (their dormant 2017 "Woffle" WOFF utility).
- [ ] A–Z bar visual redesign (Trey to share a reference); short-window sidebar tuning.
- [ ] MCP nice-to-haves: "server running" indicator; return bytes as MCP resource blocks.
- [ ] Publish the Homebrew tap (`treyhardin/tap`, cask in `Casks/woffle.rb`).
- [ ] **Back up the Sparkle private key** from the maintainer's login Keychain.

## Notes for Next Session
- Regenerate the Xcode project after cloning or editing `project.yml`: `xcodegen generate`.
- Schemes: `FontManager` (open-source; Debug = Woffle (Preview)) and `FontManagerAppStore`.
- Before launching any sandboxed build with a shared bundle ID, back up prefs — macOS *moves*
  them into the container on first launch.
- Never add OTF ⇄ TTF conversion — intentionally out of scope.
- General rules live in `../tc-agent/.claude/rules/`; this project is managed from the tc-agent
  workspace.
