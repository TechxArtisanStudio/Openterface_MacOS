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
