import Foundation

// MARK: - MCP Server Orchestrator

final class MCPServer {
    static let shared = MCPServer()

    let toolRegistry = MCPToolRegistry()
    private var sessions: [String: MCPSession] = [:]
    private let sessionLock = NSLock()
    private let requestQueue = DispatchQueue(label: "com.openterface.mcp.requests", qos: .userInitiated)

    private(set) var isRunning = false
    private var httpServer: MCPHTTPServer?
    private var cleanupTimer: DispatchSourceTimer?

    private var toolCallTimestamps: [String: [Date]] = [:]
    private let rateLimitLock = NSLock()
    private let maxCallsPerSecond = 10

    var onStatusChanged: ((Bool) -> Void)?

    private init() {
        registerDefaultTools()
    }

    // MARK: - Lifecycle

    func start(port: Int, authToken: String, bindLocalhostOnly: Bool) {
        guard !isRunning else { return }

        let server = MCPHTTPServer(
            port: port,
            authToken: authToken,
            bindLocalhostOnly: bindLocalhostOnly,
            messageHandler: { [weak self] data, sessionId in
                self?.handleMessage(data: data, sessionId: sessionId)
            },
            sessionValidator: { [weak self] sessionId in
                self?.validateSession(sessionId) ?? false
            },
            sessionCreator: { [weak self] in
                self?.createSession()
            },
            sessionTerminator: { [weak self] sessionId in
                self?.terminateSession(sessionId)
            }
        )

        do {
            try server.start()
            httpServer = server
            isRunning = true
            startCleanupTimer()
            onStatusChanged?(true)
            Logger.shared.log(content: "MCP Server started on port \(port)")
        } catch {
            Logger.shared.log(content: "MCP Server failed to start: \(error.localizedDescription)")
            onStatusChanged?(false)
        }
    }

    func stop() {
        guard isRunning else { return }
        httpServer?.stop()
        httpServer = nil
        isRunning = false
        cleanupTimer?.cancel()
        cleanupTimer = nil

        sessionLock.lock()
        sessions.removeAll()
        sessionLock.unlock()

        onStatusChanged?(false)
        Logger.shared.log(content: "MCP Server stopped")
    }

    // MARK: - Session Management

    private func createSession() -> String? {
        let session = MCPSession()
        sessionLock.lock()
        sessions[session.id] = session
        sessionLock.unlock()
        return session.id
    }

    private func validateSession(_ sessionId: String?) -> Bool {
        guard let sessionId = sessionId else { return false }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let session = sessions[sessionId] else { return false }
        if session.isExpired {
            sessions.removeValue(forKey: sessionId)
            return false
        }
        session.touch()
        return true
    }

    private func terminateSession(_ sessionId: String) {
        sessionLock.lock()
        sessions.removeValue(forKey: sessionId)
        sessionLock.unlock()
    }

    private func session(for id: String) -> MCPSession? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessions[id]
    }

    var activeSessionCount: Int {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessions.count
    }

    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: requestQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.cleanupExpiredSessions()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func cleanupExpiredSessions() {
        sessionLock.lock()
        let expired = sessions.filter { $0.value.isExpired }.map(\.key)
        for key in expired {
            sessions.removeValue(forKey: key)
        }
        sessionLock.unlock()
        if !expired.isEmpty {
            Logger.shared.log(content: "MCP: cleaned up \(expired.count) expired session(s)")
        }
    }

    // MARK: - Message Handling

    private func handleMessage(data: Data, sessionId: String?) -> Data? {
        let message: MCPIncomingMessage
        do {
            message = try MCPIncomingMessage.parse(from: data)
        } catch {
            return encodeError(id: .int(0), error: MCPError.parseError)
        }

        switch message {
        case .notification(let notification):
            handleNotification(notification, sessionId: sessionId)
            return nil

        case .request(let request):
            return handleRequest(request, sessionId: sessionId)
        }
    }

    private func handleNotification(_ notification: MCPNotification, sessionId: String?) {
        switch notification.method {
        case "notifications/initialized":
            if let sid = sessionId, let session = session(for: sid) {
                session.handleInitializedNotification()
            }
        case "notifications/cancelled":
            break
        default:
            break
        }
    }

    private func handleRequest(_ request: MCPRequest, sessionId: String?) -> Data? {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "tools/list":
            return handleToolsList(request, sessionId: sessionId)
        case "tools/call":
            return handleToolsCall(request, sessionId: sessionId)
        case "ping":
            return encodeResult(id: request.id, result: [:] as [String: Any])
        default:
            return encodeError(id: request.id, error: MCPError.methodNotFound)
        }
    }

    // MARK: - Method Handlers

    private func handleInitialize(_ request: MCPRequest) -> Data? {
        guard let paramsDict = request.params else {
            return encodeError(id: request.id, error: MCPError.invalidParams)
        }

        let paramsData: Data
        do {
            paramsData = try JSONEncoder().encode(paramsDict)
        } catch {
            return encodeError(id: request.id, error: MCPError.invalidParams)
        }

        let params: MCPInitializeParams
        do {
            params = try JSONDecoder().decode(MCPInitializeParams.self, from: paramsData)
        } catch {
            return encodeError(id: request.id, error: MCPError.invalidParams)
        }

        guard let sessionId = createSession(), let session = session(for: sessionId) else {
            return encodeError(id: request.id, error: MCPError.internalError)
        }

        let result = session.handleInitialize(params: params)

        guard let resultData = try? JSONEncoder().encode(result),
              let resultDict = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            return encodeError(id: request.id, error: MCPError.internalError)
        }

        var response = encodeResultDict(id: request.id, result: resultDict)
        response["_sessionId"] = sessionId
        return try? JSONSerialization.data(withJSONObject: response)
    }

    private func handleToolsList(_ request: MCPRequest, sessionId: String?) -> Data? {
        guard let sid = sessionId, validateSession(sid) else {
            return encodeError(id: request.id, error: MCPError(code: -32000, message: "Invalid or missing session"))
        }

        let tools = toolRegistry.listTools()
        let result = MCPListToolsResult(tools: tools, nextCursor: nil)

        guard let resultData = try? JSONEncoder().encode(result),
              let resultDict = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            return encodeError(id: request.id, error: MCPError.internalError)
        }

        return encodeResult(id: request.id, result: resultDict)
    }

    private func handleToolsCall(_ request: MCPRequest, sessionId: String?) -> Data? {
        guard let sid = sessionId, validateSession(sid) else {
            return encodeError(id: request.id, error: MCPError(code: -32000, message: "Invalid or missing session"))
        }

        guard checkRateLimit(sessionId: sid) else {
            return encodeError(id: request.id, error: MCPError(code: -32000, message: "Rate limited: max \(maxCallsPerSecond) tool calls per second"))
        }

        guard let paramsDict = request.params else {
            return encodeError(id: request.id, error: MCPError.invalidParams)
        }

        let paramsData: Data
        do {
            paramsData = try JSONEncoder().encode(paramsDict)
        } catch {
            return encodeError(id: request.id, error: MCPError.invalidParams)
        }

        let params: MCPCallToolParams
        do {
            params = try JSONDecoder().decode(MCPCallToolParams.self, from: paramsData)
        } catch {
            return encodeError(id: request.id, error: MCPError.invalidParams)
        }

        let arguments = params.arguments?.mapValues(\.value) ?? [:]

        var result: MCPCallToolResult?
        let semaphore = DispatchSemaphore(value: 0)

        requestQueue.async { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            Task {
                result = await self.toolRegistry.callTool(name: params.name, arguments: arguments)
                semaphore.signal()
            }
        }

        semaphore.wait()

        guard let toolResult = result else {
            return encodeError(id: request.id, error: MCPError.internalError)
        }

        Logger.shared.log(content: "MCP tool call: \(params.name) args=\(arguments.keys.joined(separator: ","))")

        guard let resultData = try? JSONEncoder().encode(toolResult),
              let resultDict = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            return encodeError(id: request.id, error: MCPError.internalError)
        }

        return encodeResult(id: request.id, result: resultDict)
    }

    // MARK: - Rate Limiting

    private func checkRateLimit(sessionId: String) -> Bool {
        rateLimitLock.lock()
        defer { rateLimitLock.unlock() }

        let now = Date()
        var timestamps = toolCallTimestamps[sessionId] ?? []
        timestamps = timestamps.filter { now.timeIntervalSince($0) < 1.0 }

        guard timestamps.count < maxCallsPerSecond else {
            toolCallTimestamps[sessionId] = timestamps
            return false
        }

        timestamps.append(now)
        toolCallTimestamps[sessionId] = timestamps
        return true
    }

    // MARK: - Tool Registration

    private func registerDefaultTools() {
        toolRegistry.register(MCPCaptureScreenTool())
        toolRegistry.register(MCPMoveMouseTool())
        toolRegistry.register(MCPClickTool(button: .left))
        toolRegistry.register(MCPClickTool(button: .right))
        toolRegistry.register(MCPDoubleClickTool())
        toolRegistry.register(MCPTypeTextTool())
        toolRegistry.register(MCPPressKeyTool())
        toolRegistry.register(MCPDragTool())
        toolRegistry.register(MCPScrollTool())
        toolRegistry.register(MCPOCRTool())
        toolRegistry.register(MCPDeviceStatusTool())
        toolRegistry.register(MCPSwitchUSBTool())
        toolRegistry.register(MCPEDIDInfoTool())
        toolRegistry.register(MCPEDIDSetTool())
        toolRegistry.register(MCPFirmwareUpgradeTool())
        toolRegistry.register(MCPFirmwareFlashLocalTool())
        toolRegistry.register(MCPFirmwareVerifyTool())
    }

    // MARK: - Encoding Helpers

    private func encodeResult(id: MCPRequestID, result: [String: Any]) -> Data? {
        let dict = encodeResultDict(id: id, result: result)
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    private func encodeResultDict(id: MCPRequestID, result: [String: Any]) -> [String: Any] {
        var dict: [String: Any] = [
            "jsonrpc": MCPJSONRPC.version,
            "result": result
        ]
        switch id {
        case .string(let s): dict["id"] = s
        case .int(let i): dict["id"] = i
        }
        return dict
    }

    private func encodeError(id: MCPRequestID, error: MCPError) -> Data? {
        var dict: [String: Any] = [
            "jsonrpc": MCPJSONRPC.version,
            "error": ["code": error.code, "message": error.message] as [String: Any]
        ]
        switch id {
        case .string(let s): dict["id"] = s
        case .int(let i): dict["id"] = i
        }
        return try? JSONSerialization.data(withJSONObject: dict)
    }
}