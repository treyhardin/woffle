import SwiftUI

/// First-launch welcome: what the app does, then one clear next step — pointing it at a
/// font folder (which, in the sandboxed App Store build, is also how access is granted).
/// Reopen any time from Help → Welcome to Font Manager.
struct WelcomeView: View {
    @EnvironmentObject var fontService: FontService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                Text("Welcome to Font Manager")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Your entire font library — on this Mac or a network drive — organized your way.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 36)
            .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 18) {
                WelcomeFeatureRow(icon: .folder,
                                  title: "Your whole library, wherever it lives",
                                  detail: "Add folders from this Mac, an external drive, or a NAS. Fonts stay where they are, and new ones show up automatically.")
                WelcomeFeatureRow(icon: .pencilSimple,
                                  title: "Organized your way",
                                  detail: "Label fonts by style, width, and foundry, find anything in a click, and turn fonts on only when you need them.")
                WelcomeFeatureRow(icon: .magnifyingGlass,
                                  title: "Your fonts, inside your AI tools",
                                  detail: "Connect Claude or other AI assistants to search your library and pull the exact fonts a project needs.")
                WelcomeFeatureRow(icon: .arrowsClockwise,
                                  title: "Ready for the web",
                                  detail: "Download any of your fonts as WOFF or WOFF2, or drop web fonts in to install them.")
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)

            VStack(spacing: 10) {
                Button {
                    dismiss()
                    // After the sheet closes, so the folder picker isn't stacked on it.
                    DispatchQueue.main.async { fontService.addDirectory() }
                } label: {
                    PhLabel("Add Your Font Folder…", icon: .folderPlus)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button("Start Browsing") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)

                Text("Font Manager only reads the folders you choose and never changes your font files. Nothing leaves your Mac unless you connect an AI tool.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 28)
        }
        .frame(width: 480)
    }

    // MARK: - First-launch state

    static let hasSeenKey = "welcome.hasSeen"

    /// People updating from a version without onboarding, who already have folders set up,
    /// skip the welcome. Call once at launch, before any view reads the flag.
    static func skipForExistingUsers() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: hasSeenKey) == nil else { return }
        let hasLibrary = !(defaults.stringArray(forKey: "customFontDirectories") ?? []).isEmpty
            || !(defaults.stringArray(forKey: "importedFontFiles") ?? []).isEmpty
        if hasLibrary { defaults.set(true, forKey: hasSeenKey) }
    }
}

private struct WelcomeFeatureRow: View {
    let icon: Ph
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PhIcon(icon, size: 24)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shown above the browse grid until the library has fonts of the user's own — the app is
/// never truly empty (macOS's fonts are always there), so this is the real empty state.
struct GetStartedBanner: View {
    @EnvironmentObject var fontService: FontService
    @AppStorage("getStarted.dismissed") private var dismissed = false

    private var hasOwnFonts: Bool {
        !fontService.customDirectories.isEmpty || fontService.fonts.contains { $0.source != .system }
    }

    var body: some View {
        if !dismissed && !hasOwnFonts && !fontService.isLoading {
            HStack(spacing: 14) {
                PhIcon(.folderPlus, size: 26)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bring in your own fonts").fontWeight(.semibold)
                    Text("Add a folder of fonts from this Mac, an external drive, or a NAS — or drop font files anywhere in this window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Not Now") { dismissed = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Button("Add Folder…") { fontService.addDirectory() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }
}
