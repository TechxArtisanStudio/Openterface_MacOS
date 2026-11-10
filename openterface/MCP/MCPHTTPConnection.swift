import Foundation
import Network

// MARK: - MCP HTTP Connection Handler

final class MCPHTTPConnection {
    private let connection: NWConnection
    private let authToken: String
    private let messageHandler: (Data, String?) -> Data?
    private let sessionValidator: (String?) -> Bool
    private let sessionCreator: () -> String?
    private let sessionTerminator: (String) -> Void
    private let onClose: (ObjectIdentifier) -> Void

    private var receiveBuffer = Data()
    private var isClosed = false

    init(
        connection: NWConnection,
        authToken: String,
        messageHandler: @escaping (Data, String?) -> Data?,
        sessionValidator: @escaping (String?) -> Bool,
        sessionCreator: @escaping () -> String?,
        sessionTerminator: @escaping (String) -> Void,
        onClose: @escaping (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.authToken = authToken
        self.messageHandler = messageHandler
        self.sessionValidator = sessionValidator
        self.sessionCreator = sessionCreator
        self.sessionTerminator = sessionTerminator
        self.onClose = onClose
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNextRequest()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose(ObjectIdentifier(self))
    }

    // MARK: - Receive Loop

    private func receiveNextRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.isClosed else { return }

            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.tryParseRequest()
            }

            if isComplete || error != nil {
                self.close()
                return
            }

            if !self.isClosed {
                self.receiveNextRequest()
            }
        }
    }

    private func tryParseRequest() {
        guard let headerEnd = receiveBuffer.range(of: Data("\r\n\r\n".utf8)) else { return }

        let headerData = receiveBuffer[receiveBuffer.startIndex..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            sendErrorResponse(status: 400, message: "Bad Request")
            return
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(status: 400, message: "Bad Request")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(status: 400, message: "Bad Request")
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let availableBody = receiveBuffer.count - receiveBuffer.distance(from: receiveBuffer.startIndex, to: bodyStart)

        guard availableBody >= contentLength else { return }

        let bodyData = receiveBuffer[bodyStart..<receiveBuffer.index(bodyStart, offsetBy: contentLength)]
        let body = Data(bodyData)
        receiveBuffer = Data(receiveBuffer[receiveBuffer.index(bodyStart, offsetBy: contentLength)...])

        handleHTTPRequest(method: method, path: path, headers: headers, body: body)

        if !receiveBuffer.isEmpty && !isClosed {
            tryParseRequest()
        }
    }

    // MARK: - Request Routing

    private func handleHTTPRequest(method: String, path: String, headers: [String: String], body: Data) {
        guard path == "/mcp" || path == "/mcp/" else {
            sendErrorResponse(status: 404, message: "Not Found")
            return
        }

        if !authenticate(headers: headers) {
            sendErrorResponse(status: 401, message: "Unauthorized")
            return
        }

        let sessionId = headers["mcp-session-id"]

        switch method {
        case "POST":
            handlePost(headers: headers, body: body, sessionId: sessionId)
        case "GET":
            handleGetSSE(headers: headers, sessionId: sessionId)
        case "DELETE":
            handleDelete(sessionId: sessionId)
        case "OPTIONS":
            sendCORSResponse()
        default:
            sendErrorResponse(status: 405, message: "Method Not Allowed")
        }
    }

    private func authenticate(headers: [String: String]) -> Bool {
        guard !authToken.isEmpty else { return true }
        guard let auth = headers["authorization"] else { return false }
        return auth == "Bearer \(authToken)"
    }

    // MARK: - POST /mcp

    private func handlePost(headers: [String: String], body: Data, sessionId: String?) {
        guard !body.isEmpty else {
            sendErrorResponse(status: 400, message: "Empty body")
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String else {
            sendErrorResponse(status: 400, message: "Invalid JSON-RPC")
            return
        }

        let isNotification = json["id"] == nil

        if isNotification {
            _ = messageHandler(body, sessionId)
            sendResponse(status: 202, headers: corsHeaders(), body: nil)
            return
        }

        if method == "initialize" {
            guard var responseData = messageHandler(body, nil) else {
                sendErrorResponse(status: 500, message: "Internal error")
                return
            }

            var newSessionId: String?
            if var responseDict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let sid = responseDict["_sessionId"] as? String {
                newSessionId = sid
                responseDict.removeValue(forKey: "_sessionId")
                responseData = (try? JSONSerialization.data(withJSONObject: responseDict)) ?? responseData
            }

            var responseHeaders = corsHeaders()
            responseHeaders["Content-Type"] = "application/json"
            if let sid = newSessionId {
                responseHeaders["Mcp-Session-Id"] = sid
            }
            sendResponse(status: 200, headers: responseHeaders, body: responseData)
            return
        }

        guard sessionValidator(sessionId) else {
            sendErrorResponse(status: 404, message: "Invalid or missing session")
            return
        }

        guard let responseData = messageHandler(body, sessionId) else {
            sendErrorResponse(status: 500, message: "Internal error")
            return
        }

        var responseHeaders = corsHeaders()
        responseHeaders["Content-Type"] = "application/json"
        sendResponse(status: 200, headers: responseHeaders, body: responseData)
    }

    // MARK: - GET /mcp (SSE stream)

    private func handleGetSSE(headers: [String: String], sessionId: String?) {
        guard let accept = headers["accept"], accept.contains("text/event-stream") else {
            sendErrorResponse(status: 405, message: "GET requires Accept: text/event-stream")
            return
        }

        guard sessionValidator(sessionId) else {
            sendErrorResponse(status: 404, message: "Invalid or missing session")
            return
        }

        var responseHeaders = corsHeaders()
        responseHeaders["Content-Type"] = "text/event-stream"
        responseHeaders["Cache-Control"] = "no-cache"
        responseHeaders["Connection"] = "keep-alive"

        let headerString = buildHTTPHeaderString(status: 200, headers: responseHeaders)
        guard let headerData = headerString.data(using: .utf8) else { return }

        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })

        let keepAlive = ": keepalive\n\n"
        if let keepAliveData = keepAlive.data(using: .utf8) {
            connection.send(content: keepAliveData, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() }
            })
        }
    }

    // MARK: - DELETE /mcp

    private func handleDelete(sessionId: String?) {
        guard let sessionId = sessionId, sessionValidator(sessionId) else {
            sendErrorResponse(status: 404, message: "Invalid or missing session")
            return
        }
        sessionTerminator(sessionId)
        sendResponse(status: 200, headers: corsHeaders(), body: nil)
    }

    // MARK: - Response Helpers

    private func sendResponse(status: Int, headers: [String: String], body: Data?) {
        var allHeaders = headers
        if let body = body {
            allHeaders["Content-Length"] = "\(body.count)"
        } else {
            allHeaders["Content-Length"] = "0"
        }

        let headerString = buildHTTPHeaderString(status: status, headers: allHeaders)
        guard let headerData = headerString.data(using: .utf8) else { return }

        var responseData = headerData
        if let body = body {
            responseData.append(body)
        }

        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private func sendErrorResponse(status: Int, message: String) {
        let body = "{\"error\":\"\(message)\"}"
        var headers = corsHeaders()
        headers["Content-Type"] = "application/json"
        sendResponse(status: status, headers: headers, body: body.data(using: .utf8))
    }

    private func sendCORSResponse() {
        var headers = corsHeaders()
        headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS"
        headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, Mcp-Session-Id, Accept"
        sendResponse(status: 204, headers: headers, body: nil)
    }

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Expose-Headers": "Mcp-Session-Id"
        ]
    }

    private func buildHTTPHeaderString(status: Int, headers: [String: String]) -> String {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var result = "HTTP/1.1 \(status) \(statusText)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            result += "\(key): \(value)\r\n"
        }
        result += "\r\n"
        return result
    }
}