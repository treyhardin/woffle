import SwiftUI

/// Third-party license notices, bundled as `Acknowledgements.txt`
/// (regenerate with `scripts/generate-acknowledgements.sh`).
struct AcknowledgementsView: View {
    private let text: String = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Acknowledgements are unavailable."
        }
        return text
    }()

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 640)
    }
}

/// App-menu item that opens the Acknowledgements window.
struct AcknowledgementsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Acknowledgements") {
            openWindow(id: AcknowledgementsView.windowID)
        }
    }
}

extension AcknowledgementsView {
    static let windowID = "acknowledgements"
}
