import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct GuideTraceDialog: View {
    let traceContent: String
    @Binding var isPresented: Bool
    
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(traceContent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
        }
        .frame(minWidth: 400, minHeight: 300, maxHeight: 500)
    }
}
