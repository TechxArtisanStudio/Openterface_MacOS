import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

struct ChatBubbleView: View {
    let message: ChatMessage
    var onShowGuideTrace: ((UUID) -> Void)? = nil
    @ObservedObject private var chatManager = ChatManager.shared
    
    @State private var isShowingAttachmentPreview: Bool = false
    @State private var selectedOSForConfirmation: ChatTargetSystem? = nil
    @AppStorage("guideAutoNextEnabled") private var guideAutoNextEnabled: Bool = true

    var body: some View {
        HStack {
            if bubbleAlignment == .leading {
                bubble(alignment: .leading, background: bubbleBackground)
                Spacer(minLength: 24)
            } else {
                Spacer(minLength: 24)
                bubble(alignment: .trailing, background: bubbleBackground)
            }
        }
    }

    private func bubble(alignment: Alignment, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(roleTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)

                if showsCompletionIndicator {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .help("Task Complete")
                }

                Button(action: {
                    copyMessageContent()
                }) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy Message")

                if message.role == .assistant {
                    Button(action: {
                        onShowGuideTrace?(message.id)
                    }) {
                        Image(systemName: "ladybug")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Trace Step")
                }
            }

            if let attachmentImage {
                Button {
                    isShowingAttachmentPreview = true
                } label: {
                    Image(nsImage: attachmentImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Click to view full picture")
            }

            renderedMessageContent

            if isGuideTraceMessage {
                HStack {
                    Button(action: {
                        copyMessageContent()
                    }) {
                        Text("Copy Trace")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
                
            if let bubbleStatus {
                HStack(spacing: 8) {
                    GuideStatusIcon(phase: bubbleStatus.phase)

                    Text(bubbleStatus.text)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            } else if hasActionableGuideAction {
                HStack {
                    if #available(macOS 12.0, *) {
                        Menu {
                            Picker("", selection: $guideAutoNextEnabled) {
                                Text("Execute Action").tag(false)
                                Text("Execute & Next").tag(true)
                            }
                            .labelsHidden()
                            .pickerStyle(.inline)
                        } label: {
                            Text(guideAutoNextEnabled ? "Execute & Next" : "Execute Action")
                        } primaryAction: {
                            ChatManager.shared.executeGuideAction(messageID: message.id, targetBox: message.guideActionRect, shortcut: message.guideShortcut, tool: message.guideTool, messageContent: message.content, autoNext: guideAutoNextEnabled)
                        }
                        .fixedSize()
                        .controlSize(.small)
                    } else {
                        Button(action: {
                            ChatManager.shared.executeGuideAction(messageID: message.id, targetBox: message.guideActionRect, shortcut: message.guideShortcut, tool: message.guideTool, messageContent: message.content, autoNext: guideAutoNextEnabled)
                        }) {
                            Text(guideAutoNextEnabled ? "Execute & Next" : "Execute Action")
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }

            if shouldShowOSConfirmationActions {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select target system:")
                        .font(.caption)
                        .fontWeight(.semibold)
                    
                    Picker("", selection: Binding(
                        get: { selectedOSForConfirmation ?? detectedOSForConfirmation ?? .macOS },
                        set: { selectedOSForConfirmation = $0 }
                    )) {
                        ForEach(ChatTargetSystem.allCases) { system in
                            VStack(alignment: .leading) {
                                Text(system.displayName)
                                    .font(.body)
                            }
                            .tag(system)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .controlSize(.small)
                    
                    if let detectedOS = detectedOSForConfirmation {
                        Text("(Detected: \(detectedOS.displayName))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 6) {
                        Button {
                            let targetSystem = selectedOSForConfirmation ?? detectedOSForConfirmation ?? .macOS
                            ChatManager.shared.respondToOSConfirmation(confirmed: true, suggestedSystem: targetSystem)
                            selectedOSForConfirmation = nil
                        } label: {
                            Text("Apply & Continue")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        
                        Button("Re-examine") {
                            ChatManager.shared.respondToOSConfirmation(confirmed: false, suggestedSystem: detectedOSForConfirmation)
                            selectedOSForConfirmation = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 8)
                .padding(.all, 8)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(background)
        )
        .sheet(isPresented: $isShowingAttachmentPreview) {
            ChatAttachmentViewer(image: attachmentImage, fileURL: attachmentFileURL)
        }
    }

    private var roleTitle: String {
        switch message.role {
        case .system:
            return "System"
        case .user:
            return "You"
        case .assistant:
            return "Assistant"
        }
    }

    private var attachmentImage: NSImage? {
        guard let path = message.attachmentFilePath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private var attachmentFileURL: URL? {
        guard let path = message.attachmentFilePath else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var bubbleAlignment: Alignment {
        switch message.role {
        case .user:
            return .trailing
        case .assistant, .system:
            return .leading
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return Color.blue.opacity(0.16)
        case .assistant:
            return Color(NSColor.windowBackgroundColor)
        case .system:
            return Color(NSColor.controlBackgroundColor)
        }
    }

    private var isGuideTraceMessage: Bool {
        message.role == .system && message.content.hasPrefix("Guide Step Trace")
    }

    private var hasActionableGuideAction: Bool {
        let hasShortcut = !(message.guideShortcut?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasTarget = (message.guideActionRect?.width ?? 0) > 0.001 && (message.guideActionRect?.height ?? 0) > 0.001
        return hasShortcut || hasTarget
    }

    private var bubbleStatus: GuideAutoNextStatus? {
        chatManager.bubbleStatus(for: message.id)
    }

    private var showsCompletionIndicator: Bool {
        isCompletionMessage || (message.role == .assistant && bubbleStatus?.phase == .completed)
    }

    private var isCompletionMessage: Bool {
        guard message.role == .assistant else { return false }

        let normalized = message.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("result:") {
            return true
        }

        let completionPhrases = [
            "goal achieved",
            "task complete",
            "task completed",
            "already open and loaded",
            "already completed",
            "is already open",
            "is already loaded"
        ]

        return completionPhrases.contains { normalized.contains($0) }
    }

    @ViewBuilder
    private var renderedMessageContent: some View {
        if let tableModel = MessageTableModel.from(message.content) {
            StructuredDataTableView(table: tableModel)
        } else if looksLikeMarkdown(message.content) {
            MarkdownBubbleContentView(content: message.content)
        } else {
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
        }
    }

    private var markdownContent: AttributedString? {
        guard looksLikeMarkdown(message.content) else { return nil }
        return try? AttributedString(
            markdown: message.content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
    }

    private var shouldShowOSConfirmationActions: Bool {
        guard message.role == .assistant else { return false }
        guard detectedOSForConfirmation != nil else { return false }
        guard !hasActionableGuideAction else { return false }

        let normalized = message.content.lowercased()
        let asksForConfirmation = normalized.contains("please confirm")
            || normalized.contains("confirm")
            || normalized.contains("does this match")
            || normalized.contains("shall i proceed")
        let referencesTargetProfile = normalized.contains("target system")
            || normalized.contains("configured target system")
            || normalized.contains("prompt profile")
            || normalized.contains("specific guidance")
            || normalized.contains("matches your configured target system")
        let hasExplicitDetection = normalized.contains("the target os appears to be:")
        return hasExplicitDetection && (asksForConfirmation || referencesTargetProfile)
    }

    private var detectedOSForConfirmation: ChatTargetSystem? {
        let normalized = message.content.lowercased()
        
        // First, try to extract the explicit format: "The target OS appears to be: [SYSTEM]"
        if let range = normalized.range(of: "the target os appears to be:") {
            let afterPhraseStart = normalized.index(range.upperBound, offsetBy: 0)
            let afterPhrase = String(normalized[afterPhraseStart...]).trimmingCharacters(in: .whitespaces)
            
            if afterPhrase.contains("macos") || afterPhrase.contains("mac os") {
                return .macOS
            }
            if afterPhrase.contains("windows") {
                return .windows
            }
            if afterPhrase.contains("linux") {
                return .linux
            }
            if afterPhrase.contains("iphone") {
                return .iPhone
            }
            if afterPhrase.contains("ipad") {
                return .iPad
            }
            if afterPhrase.contains("android") {
                return .android
            }
        }
        
        // Fallback: fuzzy detection from any mention (with preference order)
        // Check for more specific patterns first
        if normalized.contains("iphone") && !normalized.contains("ipad") {
            return .iPhone
        }
        if normalized.contains("ipad") {
            return .iPad
        }
        if normalized.contains("android") {
            return .android
        }
        if normalized.contains("windows") {
            return .windows
        }
        if normalized.contains("linux") {
            return .linux
        }
        if normalized.contains("macos") || normalized.contains("mac os") {
            return .macOS
        }
        
        return nil
    }

    private func copyMessageContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard let attributedClipboardContent else {
            pasteboard.setString(message.content, forType: .string)
            return
        }

        let fullRange = NSRange(location: 0, length: attributedClipboardContent.length)
        pasteboard.setString(attributedClipboardContent.string, forType: .string)

        if let rtfData = try? attributedClipboardContent.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pasteboard.setData(rtfData, forType: .rtf)
        }

        if let htmlData = try? attributedClipboardContent.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ) {
            pasteboard.setData(htmlData, forType: .html)
        }
    }

    private var attributedClipboardContent: NSAttributedString? {
        guard let markdownContent else { return nil }
        return NSAttributedString(markdownContent)
    }

    private func looksLikeMarkdown(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let markdownMarkers = [
            "# ", "## ", "### ",
            "- ", "* ", "1. ",
            "```", "`",
            "**", "__",
            "> ",
            "[", "](",
            "|"
        ]

        return markdownMarkers.contains { trimmed.contains($0) }
    }
}

private struct MarkdownBubbleContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(content).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    inlineMarkdownText(text)
                        .multilineTextAlignment(.leading)
                case .unorderedList(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                inlineMarkdownText(item)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                case .orderedList(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).")
                                inlineMarkdownText(item)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineMarkdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attributed)
        }

        return Text(text)
    }
}

private enum MarkdownBlock {
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])

    static func parse(_ content: String) -> [MarkdownBlock] {
        enum Accumulator {
            case paragraph([String])
            case unorderedList([String])
            case orderedList([String])
        }

        var blocks: [MarkdownBlock] = []
        var accumulator: Accumulator?

        func flush() {
            guard let accumulator else { return }
            switch accumulator {
            case .paragraph(let lines):
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(.paragraph(text))
                }
            case .unorderedList(let items):
                if !items.isEmpty {
                    blocks.append(.unorderedList(items))
                }
            case .orderedList(let items):
                if !items.isEmpty {
                    blocks.append(.orderedList(items))
                }
            }
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                accumulator = nil
                continue
            }

            if let unorderedItem = unorderedListItem(from: rawLine) {
                switch accumulator {
                case .unorderedList(var items):
                    items.append(unorderedItem)
                    accumulator = .unorderedList(items)
                default:
                    flush()
                    accumulator = .unorderedList([unorderedItem])
                }
                continue
            }

            if let orderedItem = orderedListItem(from: rawLine) {
                switch accumulator {
                case .orderedList(var items):
                    items.append(orderedItem)
                    accumulator = .orderedList(items)
                default:
                    flush()
                    accumulator = .orderedList([orderedItem])
                }
                continue
            }

            switch accumulator {
            case .paragraph(var lines):
                lines.append(rawLine)
                accumulator = .paragraph(lines)
            default:
                flush()
                accumulator = .paragraph([rawLine])
            }
        }

        flush()
        return blocks
    }

    private static func unorderedListItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedListItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIndex = trimmed.firstIndex(of: "."),
              dotIndex > trimmed.startIndex,
              trimmed[..<dotIndex].allSatisfy({ $0.isNumber }) else {
            return nil
        }

        let itemStart = trimmed.index(after: dotIndex)
        guard itemStart < trimmed.endIndex, trimmed[itemStart] == " " else {
            return nil
        }

        return String(trimmed[trimmed.index(after: itemStart)...])
    }
}

private struct MessageTableModel {
    let headers: [String]
    let rows: [[String]]

    static func from(_ content: String) -> MessageTableModel? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let rows = json as? [[String: Any]], !rows.isEmpty {
            var headers: [String] = []
            for row in rows {
                for key in row.keys where !headers.contains(key) {
                    headers.append(key)
                }
            }

            let values = rows.map { row in
                headers.map { stringify(row[$0]) }
            }
            return MessageTableModel(headers: headers, rows: values)
        }

        if let dictionary = json as? [String: Any], !dictionary.isEmpty {
            let headers = ["Key", "Value"]
            let rows = dictionary.keys.sorted().map { key in
                [key, stringify(dictionary[key])]
            }
            return MessageTableModel(headers: headers, rows: rows)
        }

        if let values = json as? [Any], !values.isEmpty {
            let rows = values.map { [stringify($0)] }
            return MessageTableModel(headers: ["Value"], rows: rows)
        }

        return nil
    }

    private static func stringify(_ value: Any?) -> String {
        guard let value else { return "" }

        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return String(describing: value)
    }
}

private struct StructuredDataTableView: View {
    let table: MessageTableModel

    private let cellWidth: CGFloat = 160

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                rowView(values: table.headers, isHeader: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    rowView(values: row, isHeader: false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowView(values: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(isHeader ? .caption.weight(.semibold) : .caption)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(width: cellWidth, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(isHeader ? Color.secondary.opacity(0.10) : Color.clear)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: 1)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 1)
        }
    }
}

private struct GuideStatusIcon: View {
    let phase: GuideAutoNextStatus.Phase

    var body: some View {
        Group {
            switch phase {
            case .thinking:
                ProgressView()
                    .controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            case .cancelled:
                Image(systemName: "minus.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
