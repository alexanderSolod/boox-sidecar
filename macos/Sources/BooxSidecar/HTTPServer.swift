import Foundation
import Network
import Security

struct HTTPRequest {
    let secure: Bool
    var loopback: Bool = false
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    var status: Int = 200
    var type = "application/json"
    var headers: [String: String] = [:]
    var body: Data = Data()
    var authority: SharingAuthority.Ticket?

    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(["error": message], status: status)
    }
}

final class HTTPServer {
    private var listener: NWListener?
    private var timeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "boox.http")
    private var connections: [UUID: NWConnection] = [:]
    private var sensitiveConnections = Set<ObjectIdentifier>()
    var handler: ((HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void)?
    var onError: ((String) -> Void)?
    var onReady: (() -> Void)?

    func start(port: UInt16, lan: Bool, tlsIdentity: SecIdentity? = nil) throws {
        let secure = tlsIdentity != nil
        let loopback = !lan
        let parameters: NWParameters
        // Frame polling uses small requests followed by large image responses.
        // Avoid Nagle/delayed-ACK stalls on the small control messages.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        if let tlsIdentity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            guard let identity = sec_identity_create(tlsIdentity) else {
                throw NSError(domain: "BOOXSidecar.TLS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid TLS identity"])
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else { parameters = NWParameters(tls: nil, tcp: tcp) }
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: lan ? "0.0.0.0" : "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        let ready = onReady, failed = onError
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            if case .ready = state { ready?() }
            if case .failed(let error) = state { failed?(error.localizedDescription) }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener, self.listener === listener else { connection.cancel(); return }
            guard self.connections.count < 32 else { connection.cancel(); return }
            let id = UUID()
            let connectionID = ObjectIdentifier(connection)
            self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.connections.removeValue(forKey: id)
                    self?.sensitiveConnections.remove(connectionID)
                    self?.timeouts.removeValue(forKey: connectionID)?.cancel()
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data(), secure: secure, loopback: loopback)
        }
        queue.sync {
            stopOnQueue()
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        sensitiveConnections.removeAll()
        for timeout in timeouts.values { timeout.cancel() }
        timeouts.removeAll()
    }

    func cancelSensitiveConnections() {
        queue.sync {
            for connection in connections.values where sensitiveConnections.contains(ObjectIdentifier(connection)) {
                connection.cancel()
            }
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data, secure: Bool, loopback: Bool) {
        guard connections.values.contains(where: { $0 === connection }) else { connection.cancel(); return }
        if buffer.isEmpty {
            let key = ObjectIdentifier(connection)
            timeouts.removeValue(forKey: key)?.cancel()
            let timeout = DispatchWorkItem { connection.cancel() }
            timeouts[key] = timeout
            queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self, self.connections.values.contains(where: { $0 === connection }) else { connection.cancel(); return }
            var data = buffer
            if let chunk { data.append(chunk) }
            guard data.count <= 65536 else { self.send(.error("Request too large", status: 413), on: connection); return }
            guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: data, secure: secure, loopback: loopback) }
                return
            }
            guard let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
                self.send(.error("Invalid headers", status: 400), on: connection); return
            }
            let lines = header.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0",
                  first[1].hasPrefix("/"), !first[1].hasPrefix("//"),
                  let url = URLComponents(string: String(first[1])) else {
                self.send(.error("Invalid request", status: 400), on: connection); return
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { self.send(.error("Invalid header", status: 400), on: connection); return }
                let key = line[..<colon].lowercased()
                guard headers[key] == nil else { self.send(.error("Duplicate header", status: 400), on: connection); return }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil,
                  let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 65536 - range.upperBound else {
                self.send(.error("Invalid body length", status: 400), on: connection); return
            }
            let expected = range.upperBound + length
            if data.count < expected {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: data, secure: secure, loopback: loopback) }
                return
            }
            guard data.count == expected else { self.send(.error("Pipelining is not supported", status: 400), on: connection); return }
            var query: [String: String] = [:]
            for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let request = HTTPRequest(secure: secure, loopback: loopback, method: String(first[0]), path: url.path, query: query, headers: headers, body: Data(data[range.upperBound..<expected]))
            let identifier = ObjectIdentifier(connection)
            if request.path.hasPrefix("/api/") && request.path != "/api/settings" {
                self.sensitiveConnections.insert(identifier)
            } else { self.sensitiveConnections.remove(identifier) }
            guard let handler = self.handler else { self.send(.error("Starting", status: 503), on: connection); return }
            let keepAlive = first[2] == "HTTP/1.1" && headers["connection"]?.lowercased() != "close"
            handler(request) { response in self.queue.async { self.send(response, on: connection, keepAlive: keepAlive, secure: secure, loopback: loopback) } }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, keepAlive: Bool = false, secure: Bool = false, loopback: Bool = true) {
        guard connections.values.contains(where: { $0 === connection }) else { connection.cancel(); return }
        let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]
        var header = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n"
        for (key, value) in response.headers { header += "\(key): \(value)\r\n" }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(response.body)
        let transmit = { [weak self] in connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if keepAlive && error == nil { self?.receive(connection, buffer: Data(), secure: secure, loopback: loopback) }
            else { connection.cancel() }
        }) }
        if let authority = response.authority {
            if !authority.perform(transmit) { connection.cancel() }
        } else { transmit() }
    }
}
