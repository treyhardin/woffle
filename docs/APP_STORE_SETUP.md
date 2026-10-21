# Apple Developer setup for Woffle

A step-by-step path from "I have an Apple Developer account" to "Woffle is on TestFlight, and the
GitHub build is notarized". Apple's portals change their wording often — if a label doesn't match,
look for the closest equivalent.

There are two distribution paths, and they need different certificates:

| | Mac App Store build (`FontManagerAppStore`) | GitHub build (`FontManager`) |
|---|---|---|
| Certificate | **Apple Distribution** + **Mac Installer Distribution** | **Developer ID Application** |
| Delivered via | App Store Connect → TestFlight → App Store | `.dmg` on GitHub Releases + Sparkle |
| Apple review | Yes (App Review) | No — **notarization** (automated malware scan) |
| Sandbox | Required (already on) | Off |

Both builds share the bundle ID `co.trumancreative.Woffle`.

---

## Part 1 — One-time account setup (developer.apple.com + App Store Connect)

1. **Find your Team ID.** developer.apple.com → Account → Membership details. It's a 10-character
   code (e.g. `AB12CD34EF`). You'll paste it into the project in Part 3.
2. **Sign the agreements** (App Store Connect → Business, formerly "Agreements, Tax, and Banking"):
   - Accept the **Paid Apps agreement** — required to charge for Woffle. The Free Apps agreement is
     accepted by default but isn't enough for a paid app.
   - Add **banking** details and complete the **tax** forms (W-9 for a US individual/LLC).
   - Paid apps can't go live until this shows *Active*. It can take a day or two.
3. **Register the bundle ID** (developer.apple.com → Certificates, Identifiers & Profiles →
   Identifiers → +):
   - Type: App IDs → App. Platform: macOS.
   - Description: `Woffle`. Bundle ID: **Explicit** → `co.trumancreative.Woffle`.
   - Capabilities: leave defaults (the sandbox entitlements in the app don't need portal capabilities).
   - (Optional) register `co.trumancreative.Woffle.preview` too — only needed if you ever want to
     sign the Preview build; Debug builds run fine unsigned locally.

## Part 2 — Certificates

The easiest route is to let Xcode create them:

1. Xcode → Settings → **Accounts** → + → add your Apple ID → select your team.
2. Click **Manage Certificates…** → + and create:
   - **Apple Distribution** (for App Store builds)
   - **Mac Installer Distribution** (Mac App Store uploads are signed `.pkg`s)
   - **Developer ID Application** (for the GitHub build). Only the Account Holder can create this one.
3. They land in your login Keychain. **Back them up**: Keychain Access → My Certificates → select
   each → File → Export Items… → `.p12` with a strong password. Store the `.p12`s with your Sparkle
   private key backup (which also still needs doing — see HANDOFF.md).

## Part 3 — Tell the project about your team (I can do this once you have the Team ID)

In `project.yml`, under the shared app settings:

```yaml
DEVELOPMENT_TEAM: AB12CD34EF        # your Team ID
CODE_SIGN_STYLE: Automatic
ENABLE_HARDENED_RUNTIME: YES       # required for notarization (GitHub build)
```

Then `xcodegen generate`. With automatic signing, Xcode creates the provisioning profiles for you
when you archive. (Send me the Team ID and I'll make this change and update `scripts/release.sh`
to sign with Developer ID + notarize.)

## Part 4 — Create the App Store Connect record

App Store Connect → Apps → + → **New App**:

- Platform: **macOS**
- Name: **Woffle** — this is where you find out if the name is free. If it's taken you'll get an
  error; alternatives like "Woffle — Font Manager" work since the App Store name can include a subtitle-like suffix (the separate *Subtitle* field is better for that).
- Primary language: English (U.S.)
- Bundle ID: pick `co.trumancreative.Woffle` from the list (it appears after Part 1, step 3)
- SKU: anything unique to you, e.g. `woffle-mac-1`
- User access: Full Access

Creating the record **reserves the name**, so do this early.

Then fill in, over time (none of it blocks TestFlight):

- **Pricing and Availability** — pick a price (e.g. a low one-time tier).
- **App Privacy** — answer "Data Not Collected". (The MCP server only talks to tools the user
  connects on their own network; the app sends no data to you.)
- **Category** — Graphics & Design (primary), Developer Tools or Productivity (secondary).
- **Age rating** questionnaire — all "None".
- **URLs** — Support URL and Privacy Policy URL (from woffle.io — see the `woffle-site` project).
- **Description, keywords, subtitle, screenshots** (Mac screenshots: 16:10, e.g. 2880×1800 or
  1440×900).
- **App Review notes** — explain the optional MCP server ("localhost + the user's Tailscale
  network only, off by default"), and how to test with a folder of fonts.

## Part 5 — First upload and TestFlight

1. In Xcode, select the **FontManagerAppStore** scheme, destination **Any Mac**.
2. Product → **Archive** (uses the Release configuration → product name "Woffle").
3. In the Organizer: **Distribute App** → **App Store Connect** → Upload. Xcode signs with Apple
   Distribution / Mac Installer Distribution automatically.
4. In App Store Connect → your app → **TestFlight**: the build appears after processing (10–30 min).
   Answer the export-compliance question if asked (the app already declares
   `ITSAppUsesNonExemptEncryption = NO`).
5. Add yourself as an **internal tester** and install via the TestFlight app on your Mac.

**What to verify on TestFlight** (the one thing we can't fully test with local Debug builds):
- Add a source folder → quit → relaunch → its fonts are still there (security-scoped bookmarks).
- Activate/deactivate a font from that folder.
- Folders on the NAS / external drive.
- MCP server starts and is reachable (localhost and Tailscale).

## Part 6 — Notarize the GitHub build (Developer ID)

Once the Developer ID certificate exists and Part 3 is done:

1. Create an app-specific password at account.apple.com → Sign-In and Security, then store it:
   ```sh
   xcrun notarytool store-credentials woffle-notary --apple-id <you@example.com> --team-id <TEAMID>
   ```
2. `scripts/release.sh` then: archives with Developer ID signing + hardened runtime → builds the
   `.dmg` → `xcrun notarytool submit … --keychain-profile woffle-notary --wait` →
   `xcrun stapler staple` → generates the Sparkle appcast. (I'll wire this up once you've done
   steps 1–2 of this part.)
3. After that, users no longer need the right-click → Open workaround, and the README's
   `--no-quarantine` note can go.

## Order of operations (suggested)

1. Part 1 (agreements take time to activate — start now).
2. Part 4 — create the "Woffle" record to **reserve the name**.
3. Part 2 — certificates via Xcode; back them up.
4. Send me the Team ID → Part 3.
5. Part 5 — TestFlight build; run the verification list.
6. Part 6 — notarized GitHub release (1.5.0).
7. Fill in the listing and submit for review.
