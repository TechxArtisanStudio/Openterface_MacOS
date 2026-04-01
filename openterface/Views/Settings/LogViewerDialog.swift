import SwiftUI
import AppKit

// Log viewer dialog extracted from `SettingsScreen.swift`
struct LogViewerDialog: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var logText: String = ""
    @State private var loadingError: String? = nil

    var body: some View {
        VStack {
            HStack {
                Text("Application Logs")
                    .font(.headline)
                Spacer()
                Button(action: { loadLog() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh log contents")
            }

            // Use a TextEditor so the text is selectable/copiable
                    // Use an AppKit-backed selectable, non-editable text view for reliable copy/select behavior
                    SelectableTextView(text: logText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(4)

            HStack {
                Button(action: { copyLog() }) {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Close") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .padding()
        .frame(width: 700, height: 500)
        .onAppear {
            loadLog()
        }
    }

    private func loadLog() {
        loadingError = nil
        logText = ""

        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            loadingError = "Documents directory not found."
            return
        }

        let logURL = documentsDirectory.appendingPathComponent(AppStatus.logFileName)
        guard fileManager.fileExists(atPath: logURL.path) else {
            loadingError = "Log file not found at \(logURL.path)"
            return
        }

        do {
            let contents = try String(contentsOf: logURL, encoding: .utf8)
            logText = contents
        } catch {
            loadingError = "Unable to read log file: \(error.localizedDescription)"
        }
    }

    private func copyLog() {
        // Copy the current log text to the system pasteboard
        NSPasteboard.general.clearContents()
        if !logText.isEmpty {
            NSPasteboard.general.setString(logText, forType: .string)
        }
    }
}

struct AITraceViewerDialog: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var traceText: String = ""
    @State private var loadingError: String? = nil
    @State private var entries: [AITraceEntry] = []

    var body: some View {
        VStack {
            HStack {
                Text("AI Trace Logs")
                    .font(.headline)
                Spacer()
                Button(action: { loadTrace() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh AI trace contents")
            }

            if let loadingError {
                Text(loadingError)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if entries.isEmpty {
                            Text("No AI trace records yet.")
                                .foregroundColor(.secondary)
                        }

                        ForEach(entries) { entry in
                            AITraceEntryCard(entry: entry)
                        }
                    }
                    .padding(8)
                }
            }

            HStack {
                Button(action: { copyTrace() }) {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                }
                .buttonStyle(.bordered)

                Button(action: { clearTrace() }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear Trace")
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Close") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .padding()
        .frame(width: 860, height: 620)
        .onAppear {
            loadTrace()
        }
    }

    private func loadTrace() {
        loadingError = nil
        traceText = ""

        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            loadingError = "Documents directory not found."
            return
        }

        let logURL = documentsDirectory.appendingPathComponent(AppStatus.aiTraceLogFileName)
        guard fileManager.fileExists(atPath: logURL.path) else {
            loadingError = "AI trace file not found at \(logURL.path)"
            return
        }

        do {
            traceText = try String(contentsOf: logURL, encoding: .utf8)
            entries = parseTraceEntries(traceText)
        } catch {
            loadingError = "Unable to read AI trace file: \(error.localizedDescription)"
            entries = []
        }
    }

    private func copyTrace() {
        NSPasteboard.general.clearContents()
        let text = loadingError ?? traceText
        if !text.isEmpty {
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func clearTrace() {
        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            loadingError = "Documents directory not found."
            return
        }

        let logURL = documentsDirectory.appendingPathComponent(AppStatus.aiTraceLogFileName)

        do {
            if fileManager.fileExists(atPath: logURL.path) {
                try fileManager.removeItem(at: logURL)
            }
            traceText = ""
            loadingError = nil
            entries = []
        } catch {
            loadingError = "Unable to clear AI trace file: \(error.localizedDescription)"
        }
    }

    private func parseTraceEntries(_ content: String) -> [AITraceEntry] {
        let blocks = splitTraceBlocks(content)
        return blocks.map { (header, body) in
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

            var textParts: [String] = []
            var imageParts: [String] = []
            var rawLines: [String] = []

            for line in trimmedBody.components(separatedBy: .newlines) {
                if line.hasPrefix("TRACE_TEXT|") {
                    if let parsed = parseTraceMarker(line, valueKey: "text") {
                        textParts.append(parsed)
                    }
                } else if line.hasPrefix("TRACE_IMAGE|") {
                    if let parsed = parseTraceMarker(line, valueKey: "image") {
                        imageParts.append(parsed)
                    }
                } else {
                    rawLines.append(line)
                }
            }

            return AITraceEntry(
                header: header,
                textParts: textParts,
                imageParts: imageParts,
                rawBody: rawLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func parseTraceMarker(_ line: String, valueKey: String) -> String? {
        let fields = splitEscapedFields(line)
        var indexValue = "?"
        var roleValue = "unknown"
        var contentValue = ""

        for field in fields {
            if field.hasPrefix("index=") {
                indexValue = String(field.dropFirst("index=".count))
            } else if field.hasPrefix("role=") {
                roleValue = String(field.dropFirst("role=".count))
            } else if field.hasPrefix("\(valueKey)=") {
                contentValue = String(field.dropFirst(valueKey.count + 1))
            }
        }

        guard !contentValue.isEmpty else { return nil }
        let unescaped = contentValue
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\|", with: "|")
            .replacingOccurrences(of: "\\\\", with: "\\")

        return "[\(indexValue)] \(roleValue): \(unescaped)"
    }

    private func splitEscapedFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isEscaped = false

        for ch in line {
            if isEscaped {
                current.append(ch)
                isEscaped = false
                continue
            }

            if ch == "\\" {
                isEscaped = true
                current.append(ch)
                continue
            }

            if ch == "|" {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }

        fields.append(current)
        return fields
    }

    private func splitTraceBlocks(_ content: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var currentHeader: String?
        var currentBodyLines: [String] = []

        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("===== "), line.hasSuffix(" =====") {
                if let currentHeader {
                    result.append((currentHeader, currentBodyLines.joined(separator: "\n")))
                }
                let header = String(line.dropFirst("===== ".count).dropLast(" =====".count))
                currentHeader = header
                currentBodyLines = []
            } else if currentHeader != nil {
                currentBodyLines.append(line)
            }
        }

        if let currentHeader {
            result.append((currentHeader, currentBodyLines.joined(separator: "\n")))
        }

        return result
    }
}

private struct AITraceEntry: Identifiable {
    let id = UUID()
    let header: String
    let textParts: [String]
    let imageParts: [String]
    let rawBody: String
}

private struct AITraceEntryCard: View {
    let entry: AITraceEntry
    @State private var showRaw: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.header)
                .font(.headline)

            if !entry.textParts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text")
                        .font(.subheadline.weight(.semibold))
                    ForEach(entry.textParts, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if !entry.imageParts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Images")
                        .font(.subheadline.weight(.semibold))
                    ForEach(entry.imageParts, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if !entry.rawBody.isEmpty {
                HStack {
                    Text("Raw payload")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(showRaw ? "Hide Raw" : "Show Raw") {
                        showRaw.toggle()
                    }
                    .buttonStyle(.bordered)
                }

                if entry.textParts.isEmpty && entry.imageParts.isEmpty {
                    Text("No parsed text/image markers for this entry. Use Show Raw to inspect full payload.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if showRaw {
                    Text(entry.rawBody)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - SelectableTextView (AppKit wrapper)
struct SelectableTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.black
        textView.textColor = NSColor.green
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            if textView.string != text {
                textView.string = text
                // move to top
                textView.scroll(NSPoint(x: 0, y: 0))
            }
        }
    }
}
