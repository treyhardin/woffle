import SwiftUI

/// Settings section for the MCP server: enable toggle, port, live status, and the
/// reachable URLs (localhost + Tailscale) for pasting into an MCP client config.
struct MCPSettingsView: View {
    @EnvironmentObject private var mcp: MCPServerController
    @AppStorage("mcp.allowWrites") private var allowWrites = false

    var body: some View {
        Section("MCP Server") {
            Toggle("Enable MCP server", isOn: Binding(
                get: { mcp.isEnabled },
                set: { mcp.isEnabled = $0 }
            ))
            Text("Lets AI tools on this machine or your Tailnet browse and pull fonts. Runs only while Font Manager is open.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Allow attribute editing", isOn: $allowWrites)
            Text("Lets connected tools edit font metadata — foundry, style, and width — in your library. Off by default; reading and pulling fonts don't require this.")
                .font(.caption)
                .foregroundStyle(.secondary)

            #if APPSTORE
            LabeledContent("Delivery Folder") {
                HStack {
                    Text(mcp.deliveryFolder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                        .foregroundStyle(.secondary)
                        .help(mcp.deliveryFolder ?? "")
                    Button("Choose…") { mcp.chooseDeliveryFolder() }
                }
            }
            Text("Where connected tools can save fonts directly on this Mac. Tools can always receive fonts without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif

            LabeledContent("Port") {
                TextField("Port", value: Binding(
                    get: { mcp.port },
                    set: { mcp.port = $0 }
                ), format: .number.grouping(.never))
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            }

            LabeledContent("Status") {
                switch mcp.status {
                case .stopped:
                    Text("Stopped").foregroundStyle(.secondary)
                case .running:
                    Label("Running", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if mcp.status == .running, !mcp.reachableURLs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reachable at")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(mcp.reachableURLs, id: \.self) { url in
                        Text(url)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
