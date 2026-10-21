import SwiftUI
import AppKit

/// Settings section for the MCP server: enable toggle, port, live status, and the
/// reachable URLs (localhost + Tailscale) for pasting into an MCP client config.
struct MCPSettingsView: View {
    @EnvironmentObject private var mcp: MCPServerController
    @AppStorage("mcp.allowWrites") private var allowWrites = false
    @State private var showingConnect = false

    var body: some View {
        Section("MCP Server") {
            Toggle("Enable MCP server", isOn: Binding(
                get: { mcp.isEnabled },
                set: { mcp.isEnabled = $0 }
            ))
            Text("Lets AI tools on this machine or your Tailnet browse and pull fonts. Runs only while Woffle is open.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Allow changes", isOn: $allowWrites)
            Text("Lets connected tools edit font details, manage collections, and activate or deactivate fonts directly. Off by default — tools can still search, pull fonts, and suggest edits for you to review.")
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

                Button {
                    showingConnect = true
                } label: {
                    PhLabel("Connect an AI Tool…", icon: .sparkle)
                }
                .sheet(isPresented: $showingConnect) {
                    ConnectAIToolView(urls: mcp.reachableURLs)
                }
            }
        }
    }
}

/// Copy-paste setup for common MCP clients, so connecting doesn't mean hand-editing config.
struct ConnectAIToolView: View {
    let urls: [String]
    @Environment(\.dismiss) private var dismiss

    enum Client: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case claudeDesktop = "Claude Desktop"
        case other = "Cursor / Other"
        var id: String { rawValue }
    }

    @State private var client: Client = .claudeCode
    @State private var url: String = ""
    @State private var copied = false

    private var snippet: String {
        switch client {
        case .claudeCode:
            return "claude mcp add --transport http woffle \(url)"
        case .claudeDesktop:
            // Claude Desktop launches local servers as commands; mcp-remote bridges to HTTP.
            return """
            {
              "mcpServers": {
                "woffle": {
                  "command": "npx",
                  "args": ["-y", "mcp-remote", "\(url)", "--allow-http"]
                }
              }
            }
            """
        case .other:
            return """
            {
              "mcpServers": {
                "woffle": {
                  "url": "\(url)"
                }
              }
            }
            """
        }
    }

    private var instructions: String {
        switch client {
        case .claudeCode: return "Run this in Terminal (on the machine where you use Claude Code)."
        case .claudeDesktop: return "In Claude Desktop, open Settings → Developer → Edit Config, and add this to claude_desktop_config.json. Requires Node.js. Restart Claude afterwards."
        case .other: return "Add this to your tool's MCP configuration (e.g. Cursor: ~/.cursor/mcp.json)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an AI Tool")
                .font(.title2)
                .fontWeight(.semibold)

            Picker("Tool", selection: $client) {
                ForEach(Client.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if urls.count > 1 {
                Picker("Connect from", selection: $url) {
                    ForEach(urls, id: \.self) { address in
                        Text(address.contains("127.0.0.1") ? "This Mac" : "Another device on your Tailnet").tag(address)
                    }
                }
            }

            Text(instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(snippet)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { url = urls.first ?? "" }
        .onChange(of: client) { _, _ in copied = false }
        .onChange(of: url) { _, _ in copied = false }
    }
}
