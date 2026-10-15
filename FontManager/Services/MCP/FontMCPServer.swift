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
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
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

            // Stateless conversion of client-supplied bytes — needs no catalog.
            if params.name == "convert_font" { return FontMCPInfo.convertFont(args) }

            // Everything else reads or edits the catalog. Wait briefly if it's still
            // enumerating (client connected during app startup) rather than acting on nothing.
            guard !(await FontCatalog.snapshotWhenReady(fontService)).isEmpty || params.name == "refresh_library" else {
                return CallTool.Result(content: [.text("Font library is still loading — the app is enumerating installed fonts. Retry this call in a moment.")], isError: true)
            }

            // Changes — gated behind the opt-in "Allow changes" setting.
            if Self.changeTools.contains(params.name) {
                guard UserDefaults.standard.bool(forKey: "mcp.allowWrites") else {
                    return CallTool.Result(
                        content: [.text("Changes from AI tools are turned off. Use suggest_font_attributes to propose edits for the user to review, or ask them to enable Font Manager → Settings → MCP Server → \"Allow changes\".")],
                        isError: true
                    )
                }
                switch params.name {
                case "set_font_attributes":
                    guard let updates = args["updates"]?.arrayValue, !updates.isEmpty else {
                        return CallTool.Result(content: [.text("`updates` is required: an array of { family, foundry?, classification?, width?, clear? }.")], isError: true)
                    }
                    return await FontMCPWrite.apply(updates, force: args["force"]?.boolValue ?? false, fontService: fontService)
                case "create_collection": return await FontMCPActions.createCollection(args, service: fontService)
                case "update_collection": return await FontMCPActions.updateCollection(args, service: fontService)
                case "set_fonts_active": return await FontMCPActions.setActive(args, service: fontService)
                default: break
                }
            }

            // Always allowed: suggestions change nothing until the user accepts them.
            switch params.name {
            case "suggest_font_attributes": return await FontMCPActions.suggest(args, service: fontService)
            case "list_suggestions": return await FontMCPActions.listSuggestions(args, service: fontService)
            case "refresh_library": return await FontMCPActions.refresh(service: fontService)
            default: break
            }

            guard ["list_attributes", "find_fonts", "get_font", "get_font_info", "compare_fonts"].contains(params.name) else {
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
            case "get_font_info": return FontMCPInfo.getFontInfo(records, args)
            case "compare_fonts": return FontMCPInfo.compareFonts(records, args)
            default: return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        }
    }

    /// Tools that change the library; require "Allow changes".
    private static let changeTools: Set<String> = ["set_font_attributes", "create_collection", "update_collection", "set_fonts_active"]

    private static let toolManifest: [Tool] = [
        Tool(
            name: "list_attributes",
            description: "Enumerates the filterable attributes in the font library — classifications, widths, sources, foundries and the user's collections (with counts), and the weight range — so you can build valid find_fonts queries.",
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
                    "collection": ["type": "array", "items": ["type": "string"], "description": "Collection names the user made in the app (e.g. a project or client), case-insensitive; see list_attributes. Matches families in any of them."],
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
            description: "Delivers faces, converted for use — by PostScript names (`faces`) or by `family` (+ optional `weights`/`styles`). Default format is woff2. By default returns the font bytes (base64 in structuredContent) so the calling agent can write them into its own project; pass `destination` to instead write files to a path reachable from this Mac. Includes a ready-to-use @font-face rule per face. Apple system fonts (faces with exportable=false) are licensed for this Mac only and are refused.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "faces": ["type": "array", "items": ["type": "string"], "description": "PostScript names of the faces to deliver (from find_fonts). Or use `family`."],
                    "family": ["type": "string", "description": "Deliver faces of this family by name (case-insensitive) instead of listing `faces`."],
                    "weights": ["type": "array", "items": ["type": "integer"], "description": "With `family`: only these CSS weights (e.g. [400, 700])."],
                    "styles": ["type": "array", "items": ["type": "string"], "description": "With `family`: only faces whose style contains one of these words, e.g. [\"Regular\", \"Bold\"]. Italics are included only if a word says Italic (e.g. [\"Bold Italic\"] or [\"Italic\"])."],
                    "format": ["type": "string", "enum": ["woff2", "woff", "otf", "ttf"], "description": "Output format. Default woff2. otf/ttf deliver the native outlines as-is (no OTF↔TTF outline conversion)."],
                    "destination": ["type": "string", "description": "Optional path reachable from this Mac (a directory, or a full file path for a single face). If set, files are written there and the path is returned instead of bytes. (App Store version: must be inside the Delivery Folder set in the app's MCP settings, or a source folder.)"],
                    "includeCSS": ["type": "boolean", "description": "Include an @font-face rule per face. Default true."],
                    "cssPathPrefix": ["type": "string", "description": "URL prefix for the @font-face src (default './')."],
                    "cssFontDisplay": ["type": "string", "description": "font-display value for the @font-face rule (default 'swap')."],
                ],
                "required": [],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "set_font_attributes",
            description: "Directly edit font attribute overrides — fill in Unknown foundries, fix classifications, correct widths. Prefer suggest_font_attributes so the user can review; use this when they've asked you to apply changes directly. Requires \"Allow changes\" to be enabled in the app's MCP settings (returns an error otherwise). By default only fills gaps (Unknown foundry, Unclassified classification, un-overridden width) and never overwrites an existing value — pass force:true to overwrite. Changes persist and update the app live. Returns per-family applied/skipped results plus the resulting effective values so you can verify.",
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
        Tool(
            name: "get_font_info",
            description: "Full details for specific families: effective foundry/classification/width, what the app DETECTED from the font file vs. which fields were overridden, collections, activation state, per-face files, and licensing from the font's name table (copyright, license text + URL, designer, manufacturer, version) plus decoded embedding permissions. Use it to double-check labels before suggesting edits, and to surface license terms to the user.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "families": ["type": "array", "items": ["type": "string"], "description": "Family names (from find_fonts), up to 50."],
                ],
                "required": ["families"],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "compare_fonts",
            description: "Renders several fonts side by side in one PNG — the same text in each, labeled — for choosing or pairing. Pass `families` (uses each family's Regular-ish face) and/or specific `faces`. Up to 12.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "families": ["type": "array", "items": ["type": "string"], "description": "Family names."],
                    "faces": ["type": "array", "items": ["type": "string"], "description": "PostScript names of specific faces."],
                    "text": ["type": "string", "description": "Sample text (default a pangram)."],
                    "pointSize": ["type": "integer", "description": "12–96, default 36."],
                ],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "convert_font",
            description: "Converts font bytes you supply (WOFF, WOFF2, OTF or TTF) to another format and returns the result as base64. Nothing is added to the library. Container conversion only — no OTF↔TTF outline conversion.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "dataBase64": ["type": "string", "description": "The font file, base64-encoded."],
                    "format": ["type": "string", "enum": ["woff2", "woff", "otf", "ttf"], "description": "Target format. Default woff2."],
                    "filename": ["type": "string", "description": "Original file name (used to name the output)."],
                ],
                "required": ["dataBase64"],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "suggest_font_attributes",
            description: "PREFERRED way to clean up font metadata. Proposes foundry / classification / width changes for the user to review in the app (Review Suggestions) — nothing changes until they accept. Include a short `reason` per family (what you saw: specimen shape, name-table manufacturer, etc.). Doesn't require \"Allow changes\". Re-suggesting the same family+field replaces the pending one; values matching the current one are skipped. Check outcomes with list_suggestions.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "suggestions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "family": ["type": "string", "description": "Exact family name."],
                                "foundry": ["type": "string"],
                                "classification": ["type": "string", "enum": ["Serif", "Sans Serif", "Slab Serif", "Script", "Blackletter", "Monospaced", "Symbol"]],
                                "width": ["type": "string", "enum": ["Condensed", "Regular", "Expanded"]],
                                "reason": ["type": "string", "description": "One short sentence the user sees."],
                            ],
                            "required": ["family"],
                            "additionalProperties": false,
                        ],
                    ],
                    "source": ["type": "string", "description": "Your name as shown to the user (e.g. \"Claude\")."],
                ],
                "required": ["suggestions"],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "list_suggestions",
            description: "Lists suggestions and whether the user accepted or rejected them (most recent 200).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "status": ["type": "string", "enum": ["pending", "accepted", "rejected"], "description": "Filter by status."],
                ],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "create_collection",
            description: "Creates a collection shown in the app's sidebar: a manual one (pass `families`) or a smart one (pass `rules`, e.g. all Serif + Slab Serif that are Condensed). Requires \"Allow changes\".",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "families": ["type": "array", "items": ["type": "string"], "description": "Family names to include (manual collection)."],
                    "rules": ["type": "object", "description": "Makes it a SMART collection: every font matching these rules is included automatically and stays current. Within a list any value matches; lists combine with AND; omit a list for 'any'.", "properties": ["classifications": ["type": "array", "items": ["type": "string"]], "widths": ["type": "array", "items": ["type": "string"]], "foundries": ["type": "array", "items": ["type": "string"]]], "additionalProperties": false],
                ],
                "required": ["name"],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "update_collection",
            description: "Adds/removes families (manual collections), replaces `rules` (smart collections), renames, or deletes a collection (deleting never removes fonts from the library). Requires \"Allow changes\".",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Existing collection name (case-insensitive)."],
                    "add": ["type": "array", "items": ["type": "string"]],
                    "remove": ["type": "array", "items": ["type": "string"]],
                    "renameTo": ["type": "string"],
                    "delete": ["type": "boolean"],
                    "rules": ["type": "object", "description": "Smart collections only: replaces the rules. Within a list any value matches; lists combine with AND; omit a list for 'any'.", "properties": ["classifications": ["type": "array", "items": ["type": "string"]], "widths": ["type": "array", "items": ["type": "string"]], "foundries": ["type": "array", "items": ["type": "string"]]], "additionalProperties": false],
                ],
                "required": ["name"],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "set_fonts_active",
            description: "Activates or deactivates fonts on this Mac (so design apps can use them), by `families` and/or a whole `collection`. Only fonts from the user's source folders or imports can be toggled; fonts in macOS font folders are managed by macOS. Requires \"Allow changes\".",
            inputSchema: [
                "type": "object",
                "properties": [
                    "active": ["type": "boolean"],
                    "families": ["type": "array", "items": ["type": "string"]],
                    "collection": ["type": "string"],
                ],
                "required": ["active"],
                "additionalProperties": false,
            ]
        ),
        Tool(
            name: "refresh_library",
            description: "Rescans the user's source folders and installed fonts — e.g. after new fonts were added to a network drive from another machine.",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false]
        ),
    ]
}
