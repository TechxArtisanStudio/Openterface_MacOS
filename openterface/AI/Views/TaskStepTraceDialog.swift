import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TaskStepTraceDialog: View {
    let title: String
    let entries: [ChatTaskTraceEntry]
    @Environment(\.presentationMode) var presentationMode
    @State private var previewImage: NSImage?
    @State private var previewFileURL: URL?
    @State private var isShowingImagePreview: Bool = false

    private var traceContent: String {
        if entries.isEmpty {
            return "No trace entries available yet."
        }

        var lines: [String] = []
        lines.append("Trace: \(title)")
        lines.append("Tracing \(entries.count) item\(entries.count == 1 ? "" : "s")")
        lines.append("")

        for entry in entries {
            lines.append(entry.title)
            lines.append(timestampText(for: entry.timestamp))
            if !entry.body.isEmpty {
                lines.append(entry.body)
            }
            if let imageFilePath = entry.imageFilePath {
                lines.append("Image: \(imageFilePath)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trace: \(title)")
                    .font(.headline)

                Spacer()

                Button {
                    copyTrace()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy all trace")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty {
                        Text("No trace entries available yet.")
                            .foregroundColor(.secondary)
                    }

                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.title)
                                    .font(.subheadline)
                                    .bold()

                                Spacer()

                                Button {
                                    copyEntry(entry)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy this log item")
                            }

                            Text(timestampText(for: entry.timestamp))
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            if !entry.body.isEmpty {
                                Text(entry.body)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if let imageFilePath = entry.imageFilePath,
                               let image = NSImage(contentsOfFile: imageFilePath) {
                                Button {
                                    previewImage = image
                                    previewFileURL = URL(fileURLWithPath: imageFilePath)
                                    isShowingImagePreview = true
                                } label: {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: 360, maxHeight: 220)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)

                                Text(imageFilePath.components(separatedBy: "/").last ?? imageFilePath)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                    }
                }
                .padding(8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )

            HStack {
                Spacer()
                Button("Close") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .padding(12)
        .frame(minWidth: 620, minHeight: 360)
        .sheet(isPresented: $isShowingImagePreview) {
            ChatAttachmentViewer(image: previewImage, fileURL: previewFileURL)
        }
    }

    private func timestampText(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private func copyEntry(_ entry: ChatTaskTraceEntry) {
        var lines: [String] = []
        lines.append(entry.title)
        lines.append(timestampText(for: entry.timestamp))
        if !entry.body.isEmpty {
            lines.append(entry.body)
        }
        if let imageFilePath = entry.imageFilePath {
            lines.append("Image: \(imageFilePath)")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func copyTrace() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(traceContent, forType: .string)
    }
}
