import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatAttachmentViewer: View {
    let image: NSImage?
    let fileURL: URL?

    var body: some View {
        VStack(spacing: 12) {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                }
                .frame(minWidth: 640, minHeight: 420)
            } else {
                Text("Image unavailable")
                    .foregroundColor(.secondary)
                    .frame(minWidth: 480, minHeight: 320)
            }

            if let fileURL {
                HStack {
                    Spacer()
                    Button("Open in Preview") {
                        NSWorkspace.shared.open(fileURL)
                    }
                }
            }
        }
        .padding(12)
    }
}
