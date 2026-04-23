import Foundation
import AppKit

// MARK: - ChatTracingService
// Owns all trace-logging, status-lifecycle, error-presentation, and readable-
// formatting logic that previously lived in ChatManager+Tracing.swift.
// Accessed through ChatManager's `tracing` property.

@MainActor
final class ChatTracingService {

    private let context: any ChatContext

    init(context: any ChatContext) {
        self.context = context
    }

    // MARK: - Trace helpers

    func appendTaskStepTrace(taskID: UUID, title: String, body: String = "", imageFilePath: String? = nil) {
        context.taskStepTraces[taskID, default: []].append(
            ChatTaskTraceEntry(title: title, body: body, imageFilePath: imageFilePath)
        )
        context.persistHistory()
    }

    func appendPlannerTrace(title: String, body: String = "", imageFilePath: String? = nil) {
        context.plannerTraceEntries.append(
            ChatTaskTraceEntry(title: title, body: body, imageFilePath: imageFilePath)
        )
        context.persistHistory()
    }

    func appendAITrace(title: String, headerPrefix: String? = nil, body: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: context.aiTraceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fm.fileExists(atPath: context.aiTraceURL.path) {
                fm.createFile(atPath: context.aiTraceURL.path, contents: nil, attributes: nil)
            }

            let stamp            = Self.traceDateFormatter.string(from: Date())
            let headerPrefixText = headerPrefix.map { "\($0) " } ?? ""
            let entry            = "\n===== \(stamp) \(headerPrefixText)\(title) =====\n\(body)\n"
            let data             = Data(entry.utf8)

            if let handle = try? FileHandle(forWritingTo: context.aiTraceURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: context.aiTraceURL, options: .atomic)
            }
        } catch {
            context.logger.log(content: "AI trace write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Readable trace formatting

    func readableTraceParts(from messages: [ChatCompletionsRequest.Message]) -> String {
        var sections: [String] = []
        for (index, message) in messages.enumerated() {
            let role = message.role.rawValue.uppercased()
            switch message.content {
            case .text(let value):
                sections.append("--- [\(index)] \(role) ---\n\(value)")
            case .parts(let parts):
                var partLines: [String] = []
                for part in parts {
                    if part.type == "text", let text = part.text {
                        partLines.append(text)
                    } else if part.type == "image_url", let imageURL = part.image_url?.url {
                        partLines.append("<image: \(imageTraceDescriptor(from: imageURL))>")
                    }
                }
                sections.append("--- [\(index)] \(role) ---\n\(partLines.joined(separator: "\n"))")
            }
        }
        return sections.joined(separator: "\n\n")
    }

    func imageTraceDescriptor(from url: String) -> String {
        guard url.hasPrefix("data:") else { return url }
        let mimeEnd  = url.firstIndex(of: ";") ?? url.endIndex
        let mimeType = String(url[url.index(url.startIndex, offsetBy: 5)..<mimeEnd])
        return "data-url mime=\(mimeType) chars=\(url.count)"
    }

    func escapedTraceValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    func traceBodyForLogging(data: Data, contentType: String?) -> String {
        guard !data.isEmpty else { return "<empty body>" }
        let ct = (contentType ?? "").lowercased()
        if ct.contains("image/") || ct.contains("octet-stream") {
            return "<binary payload omitted contentType=\(ct.isEmpty ? "unknown" : ct) bytes=\(data.count)>"
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            let maxLength = 20_000
            return utf8.count > maxLength
                ? String(utf8.prefix(maxLength)) + "\n...<payload truncated, too large to display (length=\(utf8.count))>"
                : utf8
        }
        return "<non-utf8 payload omitted contentType=\(ct.isEmpty ? "unknown" : ct) bytes=\(data.count)>"
    }

    static func makeTraceURL(fileName: String) -> URL {
        let fm   = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent(fileName)
    }

    static let traceDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func traceDurationHeader(from duration: TimeInterval) -> String {
        String(format: "[responseTime: %.3fs]", duration)
    }

    // MARK: - Guide trace helpers

    func guideActionDescription(for message: ChatMessage) -> String {
        var details: [String] = []
        if let shortcut = guideShortcutText(for: message) { details.append("shortcut=\(shortcut)") }
        if let box      = guideTargetBoxText(for: message) { details.append("target_box=\(box)") }
        return details.isEmpty ? "none" : details.joined(separator: ", ")
    }

    func guideShortcutText(for message: ChatMessage) -> String? {
        let s = message.guideShortcut?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    func guideTargetBoxText(for message: ChatMessage) -> String? {
        guard let rect = message.guideActionRect else { return nil }
        return "(x=\(String(format: "%.3f", rect.origin.x)), y=\(String(format: "%.3f", rect.origin.y)), w=\(String(format: "%.3f", rect.size.width)), h=\(String(format: "%.3f", rect.size.height)))"
    }

    func guideTimestampText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    // MARK: - Error presentation

    func presentAIErrorToUser(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        context.lastError = trimmed
        let displayText = "AI request error: \(trimmed)"
        if context.messages.last?.role == .assistant,
           context.messages.last?.content == displayText { return }
        context.messages.append(ChatMessage(role: .assistant, content: displayText))
        context.persistHistory()
    }

    func userFacingErrorMessage(from error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "AI model request timed out. Please retry."
            case .notConnectedToInternet:
                return "No internet connection. Please check your network and retry."
            case .cannotFindHost, .cannotConnectToHost:
                return "Cannot reach AI server host. Please check API base URL and network."
            default:
                return urlError.localizedDescription
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return "AI model request timed out. Please retry."
        }
        return error.localizedDescription
    }

    // MARK: - Agent request status lifecycle

    func startAgentRequestStatus(for messageID: UUID) {
        context.pendingAgentRequestStarts[messageID] = Date()
        context.agentRequestStatuses[messageID] = GuideAutoNextStatus(phase: .thinking, text: "Thinking...")
    }

    func completeAgentRequestStatus(for messageID: UUID) {
        let startedAt = context.pendingAgentRequestStarts.removeValue(forKey: messageID) ?? Date()
        let elapsed   = Date().timeIntervalSince(startedAt)
        context.agentRequestStatuses[messageID] = GuideAutoNextStatus(
            phase: .completed,
            text: "Used time: \(String(format: "%.2fs", elapsed))"
        )
    }

    func failAgentRequestStatus(for messageID: UUID, errorDescription: String) {
        context.pendingAgentRequestStarts.removeValue(forKey: messageID)
        context.agentRequestStatuses[messageID] = GuideAutoNextStatus(
            phase: .failed,
            text: "Failed: \(errorDescription)"
        )
    }

    func cancelAgentRequestStatus(for messageID: UUID) {
        context.pendingAgentRequestStarts.removeValue(forKey: messageID)
        context.agentRequestStatuses[messageID] = GuideAutoNextStatus(phase: .cancelled, text: "Canceled")
    }

    // MARK: - Guide auto-next status lifecycle

    func startGuideAutoNextStatus(for messageID: UUID) {
        context.pendingGuideAutoNextStarts[messageID] = Date()
        context.guideAutoNextStatuses[messageID] = GuideAutoNextStatus(phase: .thinking, text: "Thinking...")
    }

    func completeGuideAutoNextStatus(for messageID: UUID) {
        let startedAt = context.pendingGuideAutoNextStarts.removeValue(forKey: messageID) ?? Date()
        let elapsed   = Date().timeIntervalSince(startedAt)
        context.guideAutoNextStatuses[messageID] = GuideAutoNextStatus(
            phase: .completed,
            text: "Used time: \(String(format: "%.2fs", elapsed))"
        )
    }

    func failGuideAutoNextStatus(for messageID: UUID, errorDescription: String) {
        context.pendingGuideAutoNextStarts.removeValue(forKey: messageID)
        context.guideAutoNextStatuses[messageID] = GuideAutoNextStatus(
            phase: .failed,
            text: "Failed: \(errorDescription)"
        )
    }

    func cancelGuideAutoNextStatus(for messageID: UUID) {
        context.pendingGuideAutoNextStarts.removeValue(forKey: messageID)
        context.guideAutoNextStatuses[messageID] = GuideAutoNextStatus(phase: .cancelled, text: "Canceled")
    }
}
