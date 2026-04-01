import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatBubbleView: View {
    let message: ChatMessage
    var onShowGuideTrace: ((String) -> Void)? = nil
    
    @State private var isShowingAttachmentPreview: Bool = false
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

                if message.role == .assistant {
                    Button(action: {
                        if let trace = ChatManager.shared.traceMessage(messageID: message.id) {
                            onShowGuideTrace?(trace)
                        } else {
                            onShowGuideTrace?("No trace information found for this message in the current session.")
                        }
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

            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)

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
                
            if hasActionableGuideAction {
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
                            ChatManager.shared.executeGuideAction(targetBox: message.guideActionRect, shortcut: message.guideShortcut, messageContent: message.content, autoNext: guideAutoNextEnabled)
                        }
                        .fixedSize()
                        .controlSize(.small)
                    } else {
                        Button(action: {
                            ChatManager.shared.executeGuideAction(targetBox: message.guideActionRect, shortcut: message.guideShortcut, messageContent: message.content, autoNext: guideAutoNextEnabled)
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

    private func copyMessageContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
    }
}
