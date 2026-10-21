import Foundation
import Network
import OSLog
import MCP

private let mcpLog = Logger(subsystem: "co.trumancreative.Woffle", category: "mcp")

/// A minimal HTTP/1.1 listener built on Network.framework.
///
/// This is the *only* hand-written transport code: it bridges raw TCP sockets to the
/// MCP SDK's framework-agnostic `HTTPRequest` / `HTTPResponse` types. All MCP/JSON-RPC
/// semantics live in the SDK's `StatelessHTTPServerTransport`; this class just parses
/// request bytes, hands them to a handler, and serializes the response back.
///
/// Connections are one-shot (`Connection: close`) — fine for MCP's request/response
/// pattern in stateless mode, and keeps parsing simple (no keep-alive framing).
final class HTTPListener: @unchecked Sendable {
    /// Handles a parsed request and produces a response. Runs off the listener queue.
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let host: String
    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "co.trumancreative.Woffle.mcp.http")
    private var listener: NWListener?

    /// Max request body we'll accept, guards against unbounded buffering.
    private let maxBodyBytes = 8 * 1024 * 1024

    init(host: String, port: UInt16, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.handler = handler
    }

    /// Starts listening and waits until the listener is actually bound. Throws if the
    /// address/port can't be bound — bind failures surface via `stateUpdateHandler`
    /// (asynchronously), not from `NWListener.start`, so we bridge that to an async throw.
    func start() async throws {
        let params = NWParameters.tcp
        // Bind to a specific local address (e.g. 127.0.0.1 or the Tailscale IP) so we
        // never accidentally expose on every interface.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                let shouldResume = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if shouldResume { continuation.resume(with: result) }
            }

            listener.stateUpdateHandler = { [host, port] state in
                switch state {
                case .ready:
                    mcpLog.info("MCP listener ready on \(host, privacy: .public):\(port, privacy: .public)")
                    resumeOnce(.success(()))
                case .failed(let error), .waiting(let error):
                    mcpLog.error("MCP listener failed on \(host, privacy: .public):\(port, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if let error {
                connection.cancel()
                _ = error
                return
            }

            switch self.parse(buffer) {
            case .incomplete:
                if isComplete || buffer.count > self.maxBodyBytes {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            case .invalid:
                self.respond(connection, raw: Self.rawResponse(status: 400, reason: "Bad Request"))
            case .complete(let request):
                Task {
                    let response = await self.handler(request)
                    self.respond(connection, response: response)
                }
            }
        }
    }

    // MARK: - Parsing

    private enum ParseResult {
        case incomplete
        case invalid
        case complete(HTTPRequest)
    }

    /// Parses an HTTP/1.1 request from the buffer. Returns `.incomplete` until both the
    /// header block and the full Content-Length body have arrived.
    private func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return .incomplete }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .invalid }

        var lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return .invalid }
        let method = String(requestParts[0])
        let target = String(requestParts[1])
        let path = target.split(separator: "?").first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        let expected = headers.first { $0.key.lowercased() == "content-length" }
            .flatMap { Int($0.value) } ?? 0

        if expected > maxBodyBytes { return .invalid }
        if available < expected { return .incomplete }

        let body = expected > 0
            ? buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: expected))
            : nil

        return .complete(HTTPRequest(method: method, headers: headers, body: body, path: path))
    }

    // MARK: - Response serialization

    private func respond(_ connection: NWConnection, response: HTTPResponse) {
        // Stateless mode never yields `.stream`; if it somehow did, we'd need SSE framing.
        let body = response.bodyData ?? Data()
        var headers = response.headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"

        var head = "HTTP/1.1 \(response.statusCode) \(Self.reason(for: response.statusCode))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(body)
        respond(connection, raw: out)
    }

    private func respond(_ connection: NWConnection, raw: Data) {
        connection.send(content: raw, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func rawResponse(status: Int, reason: String) -> Data {
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        return Data(head.utf8)
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 406: return "Not Acceptable"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
