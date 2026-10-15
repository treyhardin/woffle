import Foundation
import MCP
import Logging

/// Owns the MCP `Server`, its stateless HTTP transport, and the socket listeners that
/// feed it. Listeners are long-lived (bound to the ports); the server + transport are
/// rebuilt on each `initialize` request.
///
/// Why rebuild on initialize: the SDK's `Server` is single-shot — it rejects a second
/// `initialize` on the same instance ("Server is already initialized"). With one shared
/// server behind a stateless transport, that means any client (or reconnect) after the
/// first would fail its handshake. Rebuilding a clean server per initialize makes every
/// client's handshake succeed regardless of prior state, while the tool set stays
/// identical each time.
actor FontMCPServer {
    private let hosts: [String]
    private let port: UInt16
    private let fontService: FontService

    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
    private var listeners: [HTTPListener] = []

    /// - Parameters:
    ///   - hosts: local addresses to bind (e.g. `127.0.0.1` and the Tailscale IP). One
    ///     listener per host, all sharing a single server + transport.
    ///   - fontService: the app's catalog, snapshotted per request on the main actor.
    init(hosts: [String], port: UInt16, fontService: FontService) {
        self.hosts = hosts
        self.port = port
        self.fontService = fontService
    }

    /// Builds the initial server + transport and starts a listener per host.
    /// Throws if any port can't be bound (and rolls back anything already started).
    func start() async throws {
        try await rebuildServer()

        var started: [HTTPListener] = []
        do {
            for host in hosts {
                let listener = HTTPListener(host: host, port: port) { [weak self] request in
                    guard let self else {
                        return .error(statusCode: 503, .internalError("Server stopped"))
                    }
                    return await self.route(request)
                }
                try await listener.start()
                started.append(listener)
            }
        } catch {
            started.forEach { $0.stop() }
            await teardownServer()
            throw error
        }

        self.listeners = started
    }

    func stop() async {
        listeners.forEach { $0.stop() }
        listeners = []
        await teardownServer()
    }

    // MARK: - Request routing

    /// Routes a request to the current transport, rebuilding a clean server first when the
    /// request is an `initialize` (see the type doc for why).
    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        if Self.isInitializeRequest(request) {
            do {
                try await rebuildServer()
            } catch {
                return .error(statusCode: 500, .internalError("Failed to initialize: \(error.localizedDescription)"))
            }
        }
        guard let transport else {
            return .error(statusCode: 503, .internalError("Server not ready"))
        }
        return await transport.handleRequest(request)
    }

    private static func isInitializeRequest(_ request: HTTPRequest) -> Bool {
        guard request.method.uppercased() == "POST", let body = request.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return (object["method"] as? String) == "initialize"
    }

    // MARK: - Server lifecycle

    /// Tears down any existing server/transport and stands up a fresh one with the same
    /// tools and validation pipeline. Listeners are untouched.
    private func rebuildServer() async throws {
        await teardownServer()

        let server = Server(
            name: "Font Manager",
            version: "1.3.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await registerTools(on: server)

        // Default pipeline allows only loopback hosts; swap in a Tailnet-aware origin
        // validator so requests from the Tailscale interface aren't rejected. The other
        // defaults (Accept: JSON, Content-Type, protocol version) are preserved.
        let pipeline = StandardValidationPipeline(validators: [
            TailnetOriginValidator(),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
        let transport = StatelessHTTPServerTransport(validationPipeline: pipeline)
        try await server.start(transport: transport)

        self.server = server
        self.transport = transport
    }

    private func teardownServer() async {
        if let server { await server.stop() }
        server = nil
        transport = nil
    }

    // MARK: - Tools

    private func registerTools(on server: Server) async {
        _ = await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.toolManifest)
        }

        let fontService = self.fontService
        _ = await server.withMethodHandler(CallTool.self) { params in
            let args = params.arguments ?? [:]

            // Write tool — gated behind the opt-in setting, separate from the read tools.
            if params.name == "set_font_attributes" {
                guard UserDefaults.standard.bool(forKey: "mcp.allowWrites") else {
                    return CallTool.Result(
                        content: [.text("Font-attribute editing is disabled. Enable it in Font Manager → Settings → MCP Server → \"Allow attribute editing\".")],
                        isError: true
                    )
                }
                guard !(await FontCatalog.snapshotWhenReady(fontService)).isEmpty else {
                    return CallTool.Result(content: [.text("Font library is still loading — retry this call in a moment.")], isError: true)
                }
                guard let updates = args["updates"]?.arrayValue, !updates.isEmpty else {
                    return CallTool.Result(content: [.text("`updates` is required: an array of { family, foundry?, classification?, width?, clear? }.")], isError: true)
                }
                let force = args["force"]?.boolValue ?? false
                return await FontMCPWrite.apply(updates, force: force, fontService: fontService)
            }

            guard ["list_attributes", "find_fonts", "get_font"].contains(params.name) else {
                return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }

            // The read tools need the catalog. Wait briefly if it's still enumerating
            // (client connected during app startup) rather than returning empty results.
            let records = await FontCatalog.snapshotWhenReady(fontService)
            guard !records.isEmpty else {
                return CallTool.Result(
                    content: [.text("Font library is still loading — the app is enumerating installed fonts. Retry this call in a moment.")],
                    isError: true
                )
            }

            switch params.name {
            case "list_attributes": return FontMCPTools.listAttributes(records)
            case "find_fonts": return FontMCPTools.findFonts(records, args)
            case "get_font": return FontMCPTools.getFont(records, args)
            default: return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        }
    }

    private static let toolManifest: [Tool] = [
        Tool(
            name: "list_attributes",
            description: "Enumerates the filterable attributes in the font library — classifications, widths, sources, foundries (with counts), and the weight range — so you can build valid find_fonts queries.",
            inputSchema: [
                "type": "object",
                "properties": [:],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "find_fonts",
            description: "Search the font library. THIS is how you find a specific font — to locate a font by name, call find_fonts with `name` (e.g. name:\"Nichrome\" finds \"MD Nichrome Trial\"); you do NOT need to list every font and scan. Matching is case-insensitive, partial, multi-word, and typo-tolerant, and results are ranked best-first. All filters are optional and combine with AND; omit them all only when you truly want to browse. Returns matching families with per-face metadata (PostScript name, style, CSS weight) — use those PostScript names with get_font. Discovery only; returns no font bytes.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Free-text name search. Matches (case-insensitive, partial, multi-word, typo-tolerant, ranked) against family name, style, PostScript name, and foundry. E.g. \"Nichrome\", \"aeonik bold\", \"grilli\"."],
                    "classification": ["type": "array", "items": ["type": "string"], "description": "e.g. Serif, Sans Serif, Slab Serif, Script, Blackletter, Monospaced, Symbol. See list_attributes."],
                    "width": ["type": "array", "items": ["type": "string"], "description": "Condensed, Regular, or Expanded."],
                    "source": ["type": "array", "items": ["type": "string"], "description": "system, custom, or imported."],
                    "weightMin": ["type": "integer", "description": "Match families with any face at or above this numeric weight."],
                    "weightMax": ["type": "integer", "description": "Match families with any face at or below this numeric weight."],
                    "includeSpecimen": ["type": "boolean", "description": "When true, include a rendered PNG specimen per returned family (also as image content for vision-capable clients). Default false."],
                    "specimenText": ["type": "string", "description": "Sample text for specimens. Defaults to a pangram."],
                    "limit": ["type": "integer", "description": "Max families to return (1–200, default 50)."],
                    "offset": ["type": "integer", "description": "Pagination offset (default 0)."],
                ],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "get_font",
            description: "Delivers one or more specific faces, converted for use. Default format is woff2. By default returns the font bytes (base64 in structuredContent) so the calling agent can write them into its own project; pass `destination` to instead write files to a path reachable from this Mac. Includes a ready-to-use @font-face rule per face. Apple system fonts (faces with exportable=false) are licensed for this Mac only and are refused.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "faces": ["type": "array", "items": ["type": "string"], "description": "PostScript names of the faces to deliver (from find_fonts)."],
                    "format": ["type": "string", "enum": ["woff2", "woff", "otf", "ttf"], "description": "Output format. Default woff2. otf/ttf deliver the native outlines as-is (no OTF↔TTF outline conversion)."],
                    "destination": ["type": "string", "description": "Optional path reachable from this Mac (a directory, or a full file path for a single face). If set, files are written there and the path is returned instead of bytes. (App Store version: must be inside the Delivery Folder set in the app's MCP settings, or a source folder.)"],
                    "includeCSS": ["type": "boolean", "description": "Include an @font-face rule per face. Default true."],
                    "cssPathPrefix": ["type": "string", "description": "URL prefix for the @font-face src (default './')."],
                    "cssFontDisplay": ["type": "string", "description": "font-display value for the @font-face rule (default 'swap')."],
                ],
                "required": ["faces"],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "set_font_attributes",
            description: "Edit font attribute overrides — fill in Unknown foundries, fix classifications, correct widths. Requires \"Allow attribute editing\" to be enabled in the app's MCP settings (returns an error otherwise). By default only fills gaps (Unknown foundry, Unclassified classification, un-overridden width) and never overwrites an existing value — pass force:true to overwrite. Changes persist and update the app live. Returns per-family applied/skipped results plus the resulting effective values so you can verify.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "updates": [
                        "type": "array",
                        "description": "One entry per family to edit.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "family": ["type": "string", "description": "Exact family name (from find_fonts)."],
                                "foundry": ["type": "string", "description": "Foundry/manufacturer to set. Empty string clears the override."],
                                "classification": ["type": "string", "enum": ["Serif", "Sans Serif", "Slab Serif", "Script", "Blackletter", "Monospaced", "Symbol", "Unclassified"]],
                                "width": ["type": "string", "enum": ["Condensed", "Regular", "Expanded"]],
                                "clear": ["type": "array", "items": ["type": "string"], "description": "Attributes to reset to their detected values: foundry, classification, width."],
                            ],
                            "required": ["family"],
                            "additionalProperties": false,
                        ],
                    ],
                    "force": ["type": "boolean", "description": "Overwrite already-populated values instead of only filling gaps. Default false."],
                ],
                "required": ["updates"],
                "additionalProperties": false,
            ]
        ),
    ]
}
