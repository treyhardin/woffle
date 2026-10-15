import Foundation
import SwiftUI
import AppKit

/// SwiftUI-facing controller for the MCP server: owns the enabled/port settings,
/// starts/stops the underlying `FontMCPServer`, and publishes status + reachable URLs
/// for the Settings UI.
@MainActor
final class MCPServerController: ObservableObject {
    enum Status: Equatable {
        case stopped
        case running
        case failed(String)
    }

    @AppStorage("mcp.enabled") private var persistedEnabled = false
    @AppStorage("mcp.port") private var persistedPort = 8787

    @Published private(set) var status: Status = .stopped
    /// The addresses the server is currently reachable at (host only, e.g. "127.0.0.1",
    /// "100.x.y.z"). Empty when stopped.
    @Published private(set) var boundHosts: [String] = []

    /// User-facing enable toggle. Setting it starts/stops the server.
    var isEnabled: Bool {
        get { persistedEnabled }
        set {
            persistedEnabled = newValue
            if newValue { start() } else { stop() }
        }
    }

    var port: Int {
        get { persistedPort }
        set {
            guard newValue != persistedPort else { return }
            persistedPort = newValue
            if persistedEnabled { restart() }
        }
    }

    private var server: FontMCPServer?

    #if APPSTORE
    /// Folder `get_font` may write into via `destination`. The sandbox only allows writing
    /// where the user has granted access, so they choose it here (source folders work too).
    @Published private(set) var deliveryFolder: String? = UserDefaults.standard.string(forKey: FontMCPTools.deliveryFolderKey)
    private let deliveryAccess = BookmarkStore(defaultsKey: "mcp.deliveryFolderBookmark")

    init() {
        if let deliveryFolder { deliveryAccess.startAccessing([deliveryFolder]) }
    }

    func chooseDeliveryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder where AI tools can save fonts on this Mac"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let old = deliveryFolder { deliveryAccess.remove(old) }
        deliveryAccess.add(url)
        deliveryFolder = url.path
        UserDefaults.standard.set(url.path, forKey: FontMCPTools.deliveryFolderKey)
    }
    #endif

    /// The catalog the server exposes. Set by the app before `startIfEnabled()`.
    var fontService: FontService?

    /// Call once on launch (after `fontService` is set) to honor a persisted setting.
    func startIfEnabled() {
        if persistedEnabled { start() }
    }

    var reachableURLs: [String] {
        boundHosts.map { "http://\($0):\(persistedPort)/mcp" }
    }

    // MARK: - Lifecycle

    private func start() {
        stop()
        guard let fontService else {
            status = .failed("Font library not ready")
            return
        }
        let hosts = Self.bindableHosts()
        guard let portValue = UInt16(exactly: persistedPort) else {
            status = .failed("Invalid port")
            return
        }
        let server = FontMCPServer(hosts: hosts, port: portValue, fontService: fontService)
        self.server = server

        Task { [weak self] in
            do {
                try await server.start()
                await MainActor.run {
                    self?.boundHosts = hosts
                    self?.status = .running
                }
            } catch {
                await MainActor.run {
                    self?.boundHosts = []
                    self?.status = .failed(error.localizedDescription)
                    self?.server = nil
                }
            }
        }
    }

    private func stop() {
        boundHosts = []
        status = .stopped
        guard let server else { return }
        self.server = nil
        Task { await server.stop() }
    }

    private func restart() {
        start()
    }

    // MARK: - Host discovery

    /// Localhost is always bound. The Tailscale address (if the Tailnet is up) is added
    /// so remote machines can reach the server. We never bind `0.0.0.0`.
    private static func bindableHosts() -> [String] {
        var hosts = ["127.0.0.1"]
        if let tailscale = tailscaleIPv4() {
            hosts.append(tailscale)
        }
        return hosts
    }

    /// Finds the machine's Tailscale IPv4 by scanning interfaces for an address in the
    /// CGNAT range Tailscale uses (100.64.0.0/10). Returns `nil` when Tailscale is down.
    private static func tailscaleIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var storage = sockaddr_in()
            memcpy(&storage, addr, Int(MemoryLayout<sockaddr_in>.size))
            let ip = UInt32(bigEndian: storage.sin_addr.s_addr)
            // 100.64.0.0/10 → first 10 bits are 0110_0100_01
            if (ip >> 22) == (0b0110010001) {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = storage.sin_addr
                if inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: buffer)
                }
            }
        }
        return nil
    }
}
