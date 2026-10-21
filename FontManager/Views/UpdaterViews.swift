// Sparkle auto-updates — open-source (direct download) build only. The App Store build
// updates through the App Store and compiles this file out (APPSTORE flag).
#if !APPSTORE

import SwiftUI
import Combine
// Sparkle 2.6 predates Swift 6 concurrency annotations; @preconcurrency lets us pass
// `self` as a delegate and treat its (main-thread) callbacks without spurious data-race errors.
@preconcurrency import Sparkle

/// Owns the Sparkle updater and drives the in-app "Update Available" indicator.
///
/// By declaring support for *gentle scheduled update reminders*, we tell Sparkle's
/// standard user driver not to interrupt with its own alert when a background check
/// finds an update. Instead we publish `updateAvailable` and surface a badge in the
/// toolbar; clicking it hands control back to Sparkle to show the install prompt.
///
/// User-initiated checks (the "Check for Updates…" menu item / Settings button) still
/// use Sparkle's standard dialog — those are expected to be modal and in focus.
///
/// Sparkle delivers user-driver delegate callbacks on the main thread, matching this
/// class's main-actor isolation.
@MainActor
final class UpdaterViewModel: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate {
    /// True while a scheduled check has found an update the user hasn't acted on yet.
    @Published var updateAvailable = false
    /// The version string of the pending update, for display in the badge tooltip.
    @Published var pendingVersion: String?

    private(set) var controller: SPUStandardUpdaterController!

    var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        // `self` is the user-driver delegate, so the controller must be built after
        // super.init(); an implicitly-unwrapped `var` is Sparkle's documented pattern.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Hand control back to Sparkle to present the pending update (download/install prompt).
    func showPendingUpdate() {
        updater.checkForUpdates()
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Opt into gentle reminders so background checks don't pop Sparkle's modal alert.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Only take over for background (non-user-initiated) checks; let Sparkle's
        // standard dialog handle checks the user explicitly triggered.
        guard !state.userInitiated else { return }
        updateAvailable = true
        pendingVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updateAvailable = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateAvailable = false
        pendingVersion = nil
    }
}

/// Toolbar badge shown only while a background check has an update waiting.
/// Clicking it opens Sparkle's install prompt.
struct UpdateAvailableButton: View {
    @ObservedObject var model: UpdaterViewModel

    var body: some View {
        if model.updateAvailable {
            Button {
                model.showPendingUpdate()
            } label: {
                // Explicit HStack (not a Label) so the icon↔text gap matches the 5pt
                // spacing SyncStatusView uses between its dot and text.
                HStack(spacing: 5) {
                    PhIcon(.arrowCircleDown, size: 14)
                    Text("Update Available")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
                .padding(.trailing, 8) // breathing room before the sync status
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            .help(model.pendingVersion.map { "Woffle \($0) is available — click to install" }
                ?? "A new version is available — click to install")
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

/// The "Check for Updates…" menu command. Polls Sparkle's main-actor `canCheckForUpdates`
/// via an in-view timer (Swift 6 won't form a KVO key path to that property).
struct CheckForUpdatesView: View {
    let updater: SPUUpdater
    @State private var canCheckForUpdates = true

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!canCheckForUpdates)
        .onReceive(pollTimer) { _ in
            canCheckForUpdates = updater.canCheckForUpdates
        }
    }
}

/// The "Updates" section of Settings.
struct UpdateSettingsSection: View {
    let updater: SPUUpdater
    @State private var automaticallyChecks: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _automaticallyChecks = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: $automaticallyChecks)
                .onChange(of: automaticallyChecks) { _, newValue in
                    updater.automaticallyChecksForUpdates = newValue
                }
            HStack {
                Button("Check Now…") { updater.checkForUpdates() }
                Spacer()
                if let date = updater.lastUpdateCheckDate {
                    Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#endif
