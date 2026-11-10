import Foundation
import Network

// MARK: - MCP HTTP Server (Streamable HTTP transport)

final class MCPHTTPServer {
    private let port: Int
    private let authToken: String
    private let bindLocalhostOnly: Bool
    private let messageHandler: (Data, String?) -> Data?
    private let sessionValidator: (String?) -> Bool
    private let sessionCreator: () -> String?
    private let sessionTerminator: (String) -> Void

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: MCPHTTPConnection] = [:]
    private let connectionLock = NSLock()
    private let queue = DispatchQueue(label: "com.openterface.mcp.http", qos: .userInitiated)

    init(
        port: Int,
        authToken: String,
        bindLocalhostOnly: Bool,
        messageHandler: @escaping (Data, String?) -> Data?,
        sessionValidator: @escaping (String?) -> Bool,
        sessionCreator: @escaping () -> String?,
        sessionTerminator: @escaping (String) -> Void
    ) {
        self.port = port
        self.authToken = authToken
        self.bindLocalhostOnly = bindLocalhostOnly
        self.messageHandler = messageHandler
        self.sessionValidator = sessionValidator
        self.sessionCreator = sessionCreator
        self.sessionTerminator = sessionTerminator
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        if bindLocalhostOnly {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: UInt16(port))!
            )
        } else {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.any),
                port: NWEndpoint.Port(rawValue: UInt16(port))!
            )
        }

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Logger.shared.log(content: "MCP HTTP listener ready on port \(self?.port ?? 0)")
            case .failed(let error):
                Logger.shared.log(content: "MCP HTTP listener failed: \(error)")
                self?.stop()
            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil

        connectionLock.lock()
        let allConnections = connections.values
        connections.removeAll()
        connectionLock.unlock()

        for conn in allConnections {
            conn.close()
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let conn = MCPHTTPConnection(
            connection: nwConnection,
            authToken: authToken,
            messageHandler: messageHandler,
            sessionValidator: sessionValidator,
            sessionCreator: sessionCreator,
            sessionTerminator: sessionTerminator,
            onClose: { [weak self] identifier in
                self?.connectionLock.lock()
                self?.connections.removeValue(forKey: identifier)
                self?.connectionLock.unlock()
            }
        )

        let identifier = ObjectIdentifier(conn)
        connectionLock.lock()
        connections[identifier] = conn
        connectionLock.unlock()

        conn.start(queue: queue)
    }
}