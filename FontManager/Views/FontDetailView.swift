import SwiftUI
import TipKit
import CoreText
import AppKit

struct FontDetailView: View {
    @EnvironmentObject var fontService: FontService
    @EnvironmentObject var conversion: ConversionManager
    let font: FontItem
    // AppStorage (not @State tied to the font's identity) so the sample text and size
    // persist as you move between fonts and across launches.
    // Blank shows each style's family name as its specimen (like the grid); typing overrides.
    @AppStorage("preview.text") private var previewText: String = ""
    @AppStorage("preview.size") private var previewSize: Double = 32
    // Format / glyph count / file size for the selected family, computed off the main
    // thread when the font changes (not on every slider drag).
    @State private var metadata: String?
    // Details are view-only until Edit is tapped, which swaps in Style/Width/Foundry controls.
    @State private var isEditing = false
    private let editTip = EditDetailsTip()
    // Draft foundry text bound to the combo box while editing; committed as an override.
    @State private var foundryDraft = ""


    private var classificationBinding: Binding<FontClassification> {
        Binding(
            get: { fontService.effectiveClassification(font) },
            set: { fontService.setClassificationOverride($0, for: font) }
        )
    }

    private var widthBinding: Binding<FontWidth> {
        Binding(
            get: { fontService.effectiveWidth(font) },
            set: { fontService.setWidthOverride($0, for: font) }
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                VStack(alignment: .leading, spacing: 24) {
                    BackToGridButton()
                    header
                    heroSpecimen
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 4)

                // Preview controls pin to the top so size/text stay reachable while
                // scrolling a family with many styles.
                Section {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(font.members) { member in
                            styleRow(member)
                        }
                        characterSet
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                } header: {
                    previewControls
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(.regularMaterial)
                        .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
        .task(id: font.id) {
            let summary = await Task.detached { FontDetailView.metadata(for: font) }.value
            metadata = summary
        }
        .task(id: font.id) {
            await AppTips.fontOpened.donate()
        }
        .onChange(of: font.id) { _, _ in
            isEditing = false   // don't carry edit mode across fonts
        }
        .onChange(of: isEditing) { _, editing in
            if editing { foundryDraft = fontService.effectiveFoundry(font) ?? "" }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(font.familyName)
                        .font(.title)
                        .fontWeight(.bold)

                    HStack(spacing: 5) {
                        ActivationDot(isActive: font.isActive)
                        Text(font.isActive ? "Active" : "Inactive")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                detailsBlock
            }

            Spacer()

            HStack(spacing: 8) {
                if font.members.count > 1 {
                    Menu {
                        ForEach(ExportFormat.supported) { format in
                            Button(format.displayName) {
                                conversion.downloadAll(font.members, family: font.familyName, as: format)
                            }
                        }
                    } label: {
                        PhIcon(.downloadSimple, size: 16)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .disabled(font.exportableMembers.isEmpty)
                    .help(font.exportableMembers.isEmpty ? Self.systemExportNote : "Download all styles…")
                }

                Menu {
                    CollectionMenuItems(fonts: [font])
                } label: {
                    PhIcon(.folderSimplePlus, size: 16)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Add to Collection")

                Button(isEditing ? "Done" : "Edit") {
                    isEditing.toggle()
                }
                .buttonStyle(.bordered)
                .popoverTip(editTip)

                // Activate is the affirmative action (prominent accent); deactivating is
                // reversible and harmless, so it's a plain button, not a red one.
                if !font.canToggleActivation {
                    Text("Managed by macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Installed in a macOS font folder — use Font Book to disable it.")
                } else if font.isActive {
                    Button("Deactivate") { fontService.toggleFont(font) }
                        .buttonStyle(.bordered)
                } else {
                    Button("Activate") { fontService.toggleFont(font) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// Large specimen of the family name (or the typed preview text) set in its own
    /// typeface — the visual anchor for the pane.
    static let systemExportNote = "Apple system fonts can't be exported — they're licensed for use on this Mac only."

    private var heroSpecimen: some View {
        Text(previewText.isEmpty ? font.familyName : previewText)
            .font(font.members.first.map { FontPreview.font(for: $0, size: 56, isActive: font.isActive) } ?? .system(size: 56))
            .lineLimit(2)
            .minimumScaleFactor(0.4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The editable preview string and the size slider.
    private var previewControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                TextField("Preview text — blank shows the font name", text: $previewText)
                    .textFieldStyle(.plain)
                if !previewText.isEmpty {
                    Button {
                        previewText = ""
                    } label: {
                        PhIcon(.xCircle, size: 15).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear preview text")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            Slider(value: $previewSize, in: 10...120)
                .frame(width: 150)

            Text("\(Int(previewSize))px")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 42)
        }
    }

    /// One style: its name, Reveal-in-Finder + Download actions, and the specimen line.
    private func styleRow(_ member: FontMember) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(member.styleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if let url = member.fileURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        PhIcon(.folder, size: 14)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Reveal in Finder")
                }

                Menu {
                    ForEach(ExportFormat.supported) { format in
                        Button(format.displayName) {
                            conversion.download(member, as: format)
                        }
                    }
                } label: {
                    PhIcon(.downloadSimple, size: 16)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .disabled(!member.isExportable)
                .help(member.isExportable ? "Download this style…" : Self.systemExportNote)
            }

            Text(previewText.isEmpty ? font.familyName : previewText)
                .font(FontPreview.font(for: member, size: previewSize, isActive: font.isActive))
                .lineLimit(nil)
                .textSelection(.enabled)
        }
    }

    /// A quick glyph overview in the family's first style.
    @ViewBuilder
    private var characterSet: some View {
        if let first = font.members.first {
            VStack(alignment: .leading, spacing: 8) {
                Text("CHARACTER SET")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
                    Text("abcdefghijklmnopqrstuvwxyz")
                    Text("0123456789 &.,;:!?‘’“”()[]/@#$%*")
                }
                .font(FontPreview.font(for: first, size: 24, isActive: font.isActive))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .textSelection(.enabled)
            }
            .padding(.top, 4)
        }
    }

    /// Style / Width / Foundry / Format. View-only until Edit is tapped, which swaps the
    /// first three for controls (Format stays read-only — it's intrinsic to the file).
    private var detailsBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isEditing {
                detailRow("Style") {
                    Picker("", selection: classificationBinding) {
                        ForEach(FontClassification.allCases) { classification in
                            Text(classification.rawValue).tag(classification)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if fontService.isClassificationOverridden(font) {
                        RevertButton { fontService.resetClassificationOverride(for: font) }
                    }
                }
                detailRow("Width") {
                    Picker("", selection: widthBinding) {
                        ForEach(FontWidth.allCases) { width in
                            Text(width.rawValue).tag(width)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if fontService.isWidthOverridden(font) {
                        RevertButton { fontService.resetWidthOverride(for: font) }
                    }
                }
                detailRow("Foundry") {
                    ComboBoxField(
                        text: $foundryDraft,
                        options: fontService.allFoundries,
                        placeholder: "Foundry name",
                        onCommit: { fontService.setFoundryOverride($0, for: font) }
                    )
                    .frame(width: 240)
                    if fontService.isFoundryOverridden(font) {
                        RevertButton {
                            fontService.resetFoundryOverride(for: font)
                            foundryDraft = fontService.effectiveFoundry(font) ?? ""
                        }
                    }
                }
            } else {
                detailRow("Style") { Text(fontService.effectiveClassification(font).rawValue) }
                detailRow("Width") { Text(fontService.effectiveWidth(font).rawValue) }
                detailRow("Foundry") { Text(fontService.displayFoundry(font)) }
            }
            detailRow("Format") {
                Text(metadataSummary).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    /// One labeled details row: a fixed-width caption on the left, its value on the right.
    @ViewBuilder
    private func detailRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            value()
        }
    }

    /// Style count, plus format / glyph count / file size when available.
    private var metadataSummary: String {
        let styles = "\(font.members.count) style\(font.members.count == 1 ? "" : "s")"
        if let metadata { return "\(styles) · \(metadata)" }
        return styles
    }

    /// Reads format, glyph count and file size for the family's first face. Runs off the
    /// main actor (it parses the font file) so it doesn't stutter the size slider.
    nonisolated private static func metadata(for font: FontItem) -> String? {
        guard let member = font.members.first else { return nil }
        var parts: [String] = []

        if let ext = member.fileURL?.pathExtension.lowercased() {
            switch ext {
            case "otf": parts.append("OpenType")
            case "ttf": parts.append("TrueType")
            case "ttc": parts.append("TrueType Collection")
            case "dfont": parts.append("dfont")
            case "": break
            default: parts.append(ext.uppercased())
            }
        }

        if let ctFont = FontConversionService.ctFont(for: member) {
            let count = CTFontGetGlyphCount(ctFont)
            if count > 0 { parts.append("\(count.formatted()) glyphs") }
        }

        if let size = try? member.fileURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A small revert affordance shown next to an overridden Style/Width picker.
struct RevertButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PhIcon(.arrowCounterClockwise, size: 13)
        }
        .buttonStyle(.borderless)
        .help("Reset to the value detected on this system")
        .accessibilityLabel("Reset to detected value")
    }
}

/// A free-text field with a dropdown + inline autocomplete of existing values, backed by
/// AppKit's `NSComboBox`. Used to edit a font's foundry: type anything, or pick/complete a
/// name already in your library. `onCommit` fires when editing ends or an item is chosen.
struct ComboBoxField: NSViewRepresentable {
    @Binding var text: String
    var options: [String]
    var placeholder: String = ""
    var onCommit: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.completes = true                 // inline autocomplete as you type
        box.usesDataSource = false
        box.hasVerticalScroller = true
        box.numberOfVisibleItems = 8
        box.placeholderString = placeholder
        box.delegate = context.coordinator
        box.addItems(withObjectValues: options)
        box.stringValue = text
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if box.stringValue != text { box.stringValue = text }
        if (box.objectValues as? [String]) != options {
            box.removeAllItems()
            box.addItems(withObjectValues: options)
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ComboBoxField
        init(_ parent: ComboBoxField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.text = box.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            let index = box.indexOfSelectedItem
            guard index >= 0, let value = box.itemObjectValue(at: index) as? String else { return }
            // Defer: mutating SwiftUI state inside the notification isn't allowed.
            DispatchQueue.main.async {
                self.parent.text = value
                self.parent.onCommit(value)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.onCommit(box.stringValue)
        }
    }
}

/// Detail pane shown when multiple fonts are selected: bulk Style/Width editing
/// (with "Mixed" when they differ), bulk activate/deactivate, and bulk download.
struct MultiFontDetailView: View {
    @EnvironmentObject var fontService: FontService
    @EnvironmentObject var conversion: ConversionManager
    let fonts: [FontItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BackToGridButton()

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(fonts.count) fonts selected")
                            .font(.title)
                            .fontWeight(.bold)

                        HStack(spacing: 10) {
                            Picker("Style", selection: classificationBinding) {
                                if commonClassification == nil {
                                    Text("Mixed").tag(FontClassification?.none)
                                }
                                ForEach(FontClassification.allCases) { classification in
                                    Text(classification.rawValue).tag(FontClassification?.some(classification))
                                }
                            }
                            .fixedSize()

                            Picker("Width", selection: widthBinding) {
                                if commonWidth == nil {
                                    Text("Mixed").tag(FontWidth?.none)
                                }
                                ForEach(FontWidth.allCases) { width in
                                    Text(width.rawValue).tag(FontWidth?.some(width))
                                }
                            }
                            .fixedSize()

                            if fonts.contains(where: { fontService.isOverridden($0) }) {
                                Button {
                                    fontService.resetOverride(for: fonts)
                                } label: {
                                    PhLabel("Reset", icon: .arrowCounterClockwise)
                                }
                                .buttonStyle(.borderless)
                                .help("Reset Style and Width for all selected fonts")
                            }
                        }
                    }

                    Spacer()

                    Menu("Collections") {
                        CollectionMenuItems(fonts: fonts)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Menu("Download All") {
                        ForEach(ExportFormat.supported) { format in
                            Button(format.displayName) {
                                conversion.downloadMany(fonts, as: format)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!fonts.contains { !$0.exportableMembers.isEmpty })

                    // Only fonts this app registers can be toggled; hide the controls when
                    // every selected font is managed by macOS.
                    if fonts.contains(where: \.canToggleActivation) {
                        Button("Activate") { fontService.setActive(true, for: fonts) }
                            .buttonStyle(.borderedProminent)
                        Button("Deactivate") { fontService.setActive(false, for: fonts) }
                            .buttonStyle(.bordered)
                    }
                }

                Divider()

                ForEach(fonts) { font in
                    HStack(spacing: 12) {
                        if let member = font.members.first {
                            Text(font.familyName)
                                .font(FontPreview.font(for: member, size: 20, isActive: font.isActive))
                                .lineLimit(1)
                        } else {
                            Text(font.familyName)
                        }

                        Spacer()

                        Text(fontService.effectiveClassification(font).rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ActivationDot(isActive: font.isActive)
                    }
                    Divider()
                }
            }
            .padding(24)
        }
    }

    private var commonClassification: FontClassification? {
        let values = Set(fonts.map { fontService.effectiveClassification($0) })
        return values.count == 1 ? values.first : nil
    }

    private var classificationBinding: Binding<FontClassification?> {
        Binding(
            get: { commonClassification },
            set: { if let value = $0 { fontService.setClassificationOverride(value, for: fonts) } }
        )
    }

    private var commonWidth: FontWidth? {
        let values = Set(fonts.map { fontService.effectiveWidth($0) })
        return values.count == 1 ? values.first : nil
    }

    private var widthBinding: Binding<FontWidth?> {
        Binding(
            get: { commonWidth },
            set: { if let value = $0 { fontService.setWidthOverride(value, for: fonts) } }
        )
    }
}
