import Foundation

// MARK: - JSON-RPC 2.0 Base Types

enum MCPJSONRPC {
    static let version = "2.0"
}

struct MCPRequest: Codable {
    let jsonrpc: String
    let id: MCPRequestID
    let method: String
    let params: [String: AnyCodable]?

    init(id: MCPRequestID, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = MCPJSONRPC.version
        self.id = id
        self.method = method
        self.params = params
    }
}

struct MCPResponse: Codable {
    let jsonrpc: String
    let id: MCPRequestID
    let result: AnyCodable?
    let error: MCPError?

    init(id: MCPRequestID, result: AnyCodable) {
        self.jsonrpc = MCPJSONRPC.version
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: MCPRequestID, error: MCPError) {
        self.jsonrpc = MCPJSONRPC.version
        self.id = id
        self.result = nil
        self.error = error
    }
}

struct MCPNotification: Codable {
    let jsonrpc: String
    let method: String
    let params: [String: AnyCodable]?

    init(method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = MCPJSONRPC.version
        self.method = method
        self.params = params
    }
}

struct MCPError: Codable, Error {
    let code: Int
    let message: String
    let data: AnyCodable?

    init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    static let parseError = MCPError(code: -32700, message: "Parse error")
    static let invalidRequest = MCPError(code: -32600, message: "Invalid Request")
    static let methodNotFound = MCPError(code: -32601, message: "Method not found")
    static let invalidParams = MCPError(code: -32602, message: "Invalid params")
    static let internalError = MCPError(code: -32603, message: "Internal error")
}

// MARK: - Request ID (string or integer)

enum MCPRequestID: Codable, Equatable, Hashable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.typeMismatch(MCPRequestID.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let val): try container.encode(val)
        case .int(let val): try container.encode(val)
        }
    }
}

// MARK: - AnyCodable (type-erased JSON value)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyCodable.init))
        case let dict as [String: Any]:
            try container.encode(dict.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}

// MARK: - MCP Protocol Types

struct MCPInitializeParams: Codable {
    let protocolVersion: String
    let capabilities: MCPClientCapabilities
    let clientInfo: MCPImplementation
}

struct MCPClientCapabilities: Codable {
    let roots: MCPRootsCapability?
    let sampling: [String: AnyCodable]?
    let experimental: [String: AnyCodable]?
}

struct MCPRootsCapability: Codable {
    let listChanged: Bool?
}

struct MCPImplementation: Codable {
    let name: String
    let version: String
}

struct MCPInitializeResult: Codable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPImplementation
    let instructions: String?
}

struct MCPServerCapabilities: Codable {
    let tools: MCPToolsCapability?
    let resources: MCPResourcesCapability?
    let prompts: MCPPromptsCapability?
    let logging: [String: AnyCodable]?
}

struct MCPToolsCapability: Codable {
    let listChanged: Bool?
}

struct MCPResourcesCapability: Codable {
    let subscribe: Bool?
    let listChanged: Bool?
}

struct MCPPromptsCapability: Codable {
    let listChanged: Bool?
}

// MARK: - Tool Types

struct MCPToolDefinition: Codable {
    let name: String
    let description: String?
    let inputSchema: MCPInputSchema
}

struct MCPInputSchema: Codable {
    let type: String
    let properties: [String: AnyCodable]?
    let required: [String]?

    init(properties: [String: AnyCodable]? = nil, required: [String]? = nil) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

struct MCPCallToolParams: Codable {
    let name: String
    let arguments: [String: AnyCodable]?
}

struct MCPCallToolResult: Codable {
    let content: [MCPContent]
    let isError: Bool?
}

enum MCPContent: Codable {
    case text(String)
    case image(data: String, mimeType: String)

    enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }
}

struct MCPListToolsResult: Codable {
    let tools: [MCPToolDefinition]
    let nextCursor: String?
}

// MARK: - Incoming Message Envelope

enum MCPIncomingMessage {
    case request(MCPRequest)
    case notification(MCPNotification)

    static func parse(from data: Data) throws -> MCPIncomingMessage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.parseError
        }
        guard json["jsonrpc"] as? String == MCPJSONRPC.version else {
            throw MCPError.invalidRequest
        }
        guard let method = json["method"] as? String else {
            throw MCPError.invalidRequest
        }

        let decoder = JSONDecoder()
        if json["id"] != nil {
            let request = try decoder.decode(MCPRequest.self, from: data)
            return .request(request)
        } else {
            let notification = try decoder.decode(MCPNotification.self, from: data)
            return .notification(notification)
        }
    }
}