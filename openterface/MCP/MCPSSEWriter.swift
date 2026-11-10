import Foundation

// MARK: - SSE Event Writer

enum MCPSSEWriter {
    static func formatEvent(data: String, event: String? = nil, id: String? = nil) -> String {
        var result = ""
        if let id = id {
            result += "id: \(id)\n"
        }
        if let event = event {
            result += "event: \(event)\n"
        }
        for line in data.components(separatedBy: "\n") {
            result += "data: \(line)\n"
        }
        result += "\n"
        return result
    }

    static func formatMessage(jsonData: Data) -> String? {
        guard let jsonString = String(data: jsonData, encoding: .utf8) else { return nil }
        return formatEvent(data: jsonString, event: "message")
    }

    static func keepAlive() -> String {
        ": keepalive\n\n"
    }
}