import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct GuideTraceDialog: View {
    let entries: [ChatTaskTraceEntry]
    @Binding var isPresented: Bool
    @State private var previewImage: NSImage?
    @State private var previewFileURL: URL?
    @State private var isShowingImagePreview: Bool = false

    private var traceContent: String {
        if entries.isEmpty {
            return "No trace information found for this guide step."
        }

        var lines: [String] = []
        lines.append("Guide Step Trace")
        lines.append("Tracing \(entries.count) step\(entries.count == 1 ? "" : "s")")
        lines.append("")

        for entry in entries {
            lines.append(entry.title)
            lines.append(entry.body)
            if let imageFilePath = entry.imageFilePath {
                lines.append("Screen Capture: \(imageFilePath)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Guide Step Trace")
                    .font(.headline)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(traceContent, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy Trace")
                .padding(.trailing, 8)
                
                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty {
                        Text("No trace information found for this guide step.")
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

                            Text(entry.body)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

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
                .padding()
            }
        }
        .frame(minWidth: 560, minHeight: 360, maxHeight: 700)
        .sheet(isPresented: $isShowingImagePreview) {
            ChatAttachmentViewer(image: previewImage, fileURL: previewFileURL)
        }
    }

    private func copyEntry(_ entry: ChatTaskTraceEntry) {
        var lines: [String] = []
        lines.append(entry.title)
        if !entry.body.isEmpty {
            lines.append(entry.body)
        }
        if let imageFilePath = entry.imageFilePath {
            lines.append("Image: \(imageFilePath)")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
