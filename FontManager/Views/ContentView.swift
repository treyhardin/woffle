import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var fontService: FontService
    @EnvironmentObject var conversion: ConversionManager
    @EnvironmentObject var toastCenter: ToastCenter
    #if !APPSTORE
    @EnvironmentObject var updaterModel: UpdaterViewModel
    #endif
    @State private var isDropTargeted = false
    @State private var showingDirectories = false
    @AppStorage(WelcomeView.hasSeenKey) private var hasSeenWelcome = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Opening a font: the detail rises in from slightly smaller while the grid recedes
    /// slightly larger, like stepping in; going back reverses it. Fades only with Reduce Motion.
    private var detailTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }

    private var browseTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.02))
    }

    /// Resolve the selected ids back to current FontItems (ids are stable across reloads).
    private var selectedFonts: [FontItem] {
        fontService.fonts
            .filter { fontService.selection.contains($0.id) }
            .sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            FontListView()
                // The sidebar's content (chips, scrolling lists) has no natural width, so pin
                // the minimum on the content too — the column width alone isn't enforced.
                .frame(minWidth: 280)
                .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 380)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ZStack {
                if selectedFonts.isEmpty {
                    FontGridView()
                        .transition(browseTransition)
                } else {
                    // Opening a font adds the font list column between filters and detail.
                    HStack(spacing: 0) {
                        FontListColumn()
                            .frame(width: 280)
                        Divider()
                        Group {
                            if selectedFonts.count == 1 {
                                FontDetailView(font: selectedFonts[0])
                            } else {
                                MultiFontDetailView(fonts: selectedFonts)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .transition(detailTransition)
                }
            }
            // Animate only moving between All Fonts and a detail view — switching fonts
            // within the detail view (e.g. from the sidebar) stays instant.
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.28),
                       value: selectedFonts.isEmpty)
        }
        .frame(minWidth: 980, minHeight: 460)
        .toolbar {
            // The badge keeps its own prominent fill — hide the shared glass container
            // macOS Tahoe would otherwise draw around the toolbar item.
            #if !APPSTORE
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    UpdateAvailableButton(model: updaterModel)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: updaterModel.updateAvailable)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    UpdateAvailableButton(model: updaterModel)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: updaterModel.updateAvailable)
                }
            }
            #endif
            // Status shows as bare text on the toolbar — no glass container (macOS Tahoe
            // draws one by default), and a spacer keeps it out of the buttons' container.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    SyncStatusView()
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    SyncStatusView()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ReviewSuggestionsButton()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    conversion.showConvert = true
                } label: {
                    PhLabel("Convert", icon: .arrowsClockwise)
                        .padding(.horizontal, 6)
                }
                .labelStyle(.titleAndIcon)
                .help("Upload a font and download it in another format")

                Button {
                    showingDirectories = true
                } label: {
                    PhLabel("Sources", icon: .folderPlus)
                        .padding(.horizontal, 6)
                }
                .labelStyle(.titleAndIcon)
                .help("Add or remove custom font folders")
            }
        }
        .toolbarRole(.editor)
        .navigationTitle(fontService.activeCollection?.name ?? "Woffle")
        .modifier(CollectionNameAlert())
        .sheet(item: $fontService.smartCollectionEditor) { request in
            SmartCollectionEditor(existing: request.collection)
                .environmentObject(fontService)
        }
        .sheet(isPresented: $showingDirectories) {
            DirectoriesView()
        }
        .sheet(isPresented: Binding(get: { !hasSeenWelcome }, set: { if !$0 { hasSeenWelcome = true } })) {
            WelcomeView()
                .environmentObject(fontService)
        }
        .sheet(isPresented: $conversion.showConvert) {
            ConvertView()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(
                        PhLabel("Drop fonts to add — WOFF / WOFF2 are converted", icon: .fileArrowDown, size: 20)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    )
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if fontService.isLoading && fontService.fonts.isEmpty {
                ProgressView("Loading fonts…")
                    .controlSize(.large)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay(alignment: .bottom) {
            ConversionToast(center: toastCenter)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastCenter.toast?.id)
        }
        .alert("A note on font licensing", isPresented: $conversion.pendingLicenseConfirmation) {
            Button("Cancel", role: .cancel) { conversion.cancelLicensing() }
            Button("Continue") { conversion.confirmLicensing() }
        } message: {
            Text("Converting or exporting a font is your responsibility with respect to that font's license — some commercial and system fonts restrict conversion or redistribution. Use this only for fonts you're permitted to.")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fontExtensions: Set<String> = ["woff", "woff2", "otf", "ttf"]
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      fontExtensions.contains(url.pathExtension.lowercased()) else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                conversion.convert(urls, to: .native, into: fontService)
            }
        }
        return true
    }
}

/// Toolbar sync indicator: a spinning arrow + "Syncing…" while a re-scan runs, otherwise a
/// green dot + "Last synced …" that keeps its relative time current.
struct SyncStatusView: View {
    @EnvironmentObject var fontService: FontService

    @State private var hovering = false

    var body: some View {
        // Click to rescan now — folder watching can miss changes made from other machines
        // (e.g. fonts added to a NAS elsewhere).
        Button {
            fontService.loadAllFonts()
        } label: {
            HStack(spacing: 5) {
                if fontService.isSyncing {
                    SpinningArrow()
                    Text("Syncing…")
                } else if hovering {
                    PhIcon(.arrowsClockwise, size: 13)
                    Text("Sync Now")
                } else {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.syncedText(fontService.lastSyncedAt, now: context.date))
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(fontService.isSyncing)
        .onHover { inside in
            hovering = inside
            // Pointing hand so it reads as clickable.
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("Rescan your font folders now (⌘R)")
        .accessibilityLabel(fontService.isSyncing ? "Syncing" : "Sync now")
    }

    private static func syncedText(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not synced yet" }
        if now.timeIntervalSince(date) < 10 { return "Last synced just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last synced " + formatter.localizedString(for: date, relativeTo: now)
    }
}

/// A continuously rotating refresh glyph, used while syncing.
struct SpinningArrow: View {
    @State private var spinning = false

    var body: some View {
        PhIcon(.arrowsClockwise, size: 13)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
