import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatWindowRootView: View {
    private enum ChatRunMode: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case agentic = "Agent"
        case planner = "Planner"
        case guide = "Guide"

        var id: String { rawValue }
    }

    @ObservedObject var chatManager: ChatManager
    @ObservedObject var userSettings = UserSettings.shared
    @ObservedObject private var skillManager = SkillManager.shared
    @State private var draft: String = ""
    @State private var inputEditorHeight: CGFloat = 96
    @State private var inputEditorDragStartHeight: CGFloat?
    @State private var pendingImage: NSImage?
    @State private var pendingImageURL: URL?
    @State private var isShowingAITrace: Bool = false
    @State private var isShowingTaskStepTrace: Bool = false
    @State private var isShowingGuideTrace: Bool = false
    @State private var selectedGuideTraceEntries: [ChatTaskTraceEntry] = []
    @State private var selectedTaskStepTraceTitle: String = ""
    @State private var selectedTaskStepTraceEntries: [ChatTaskTraceEntry] = []

    private let minInputEditorHeight: CGFloat = 64
    private let maxInputEditorHeight: CGFloat = 280

    private var currentMode: ChatRunMode {
        if userSettings.isChatGuideModeEnabled { return .guide }
        if userSettings.isChatPlannerModeEnabled { return .planner }
        if userSettings.isChatAgenticModeEnabled { return .agentic }
        return .chat
    }

    private var placeholderIcon: String {
        switch currentMode {
        case .chat: return "bubble.left.and.bubble.right"
        case .agentic: return "bolt.fill"
        case .planner: return "list.bullet.clipboard"
        case .guide: return "map"
        }
    }

    private var placeholderDescription: String {
        switch currentMode {
        case .chat: return "Start a standard conversation. The AI will respond with text and screenshot."
        case .agentic: return "AI can directly execute actions on the target device using tools."
        case .planner: return "AI will create a multi-step plan for your approval before executing."
        case .guide: return "AI will give you turn-by-turn guidance to accomplish your goal manually."
        }
    }

    private var chatModeBinding: Binding<ChatRunMode> {
        Binding(
            get: {
                if userSettings.isChatGuideModeEnabled {
                    return .guide
                }
                if userSettings.isChatPlannerModeEnabled {
                    return .planner
                }
                if userSettings.isChatAgenticModeEnabled {
                    return .agentic
                }
                return .chat
            },
            set: { mode in
                switch mode {
                case .chat:
                    userSettings.isChatAgenticModeEnabled = false
                    userSettings.isChatPlannerModeEnabled = false
                    userSettings.isChatGuideModeEnabled = false
                case .agentic:
                    userSettings.isChatAgenticModeEnabled = true
                    userSettings.isChatPlannerModeEnabled = false
                    userSettings.isChatGuideModeEnabled = false
                case .planner:
                    userSettings.isChatAgenticModeEnabled = false
                    userSettings.isChatPlannerModeEnabled = true
                    userSettings.isChatGuideModeEnabled = false
                case .guide:
                    userSettings.isChatAgenticModeEnabled = false
                    userSettings.isChatPlannerModeEnabled = false
                    userSettings.isChatGuideModeEnabled = true
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Mode", selection: chatModeBinding) {
                    ForEach(ChatRunMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .help("Select exactly one mode: Chat, Agentic, Planner, or Guide")

                Button {
                    chatManager.clearHistory()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New session")

                Button("Trace") {
                    isShowingAITrace = true
                }
                .help("Open AI request/response trace logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Skills quick-action bar
            if !skillManager.skills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(skillManager.skills) { skill in
                            Button {
                                chatManager.runSkill(skill)
                            } label: {
                                Label(skill.name, systemImage: skill.icon)
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(chatManager.isSending)
                            .help(skill.prompt)
                        }

                        Button {
                            NSWorkspace.shared.open(SkillManager.skillsFolder)
                        } label: {
                            Image(systemName: "folder.badge.plus")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Open Skills folder – add your own .json skill files here")

                        Button {
                            skillManager.reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Reload skills from disk")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                Divider()
            }

            if let plan = chatManager.currentPlan {
                ChatPlanCardView(
                    plan: plan,
                    isBusy: chatManager.isSending,
                    onApprove: { chatManager.approveCurrentPlan() },
                    onClear: { chatManager.clearCurrentPlan() },
                    onRerun: { chatManager.rerunLastPrompt() },
                    onTracePlan: {
                        selectedTaskStepTraceTitle = "Planning"
                        selectedTaskStepTraceEntries = chatManager.plannerTraceEntries
                        isShowingTaskStepTrace = true
                    },
                    onTraceTask: { task in
                        selectedTaskStepTraceTitle = task.title
                        selectedTaskStepTraceEntries = chatManager.taskStepTraceEntries(for: task.id)
                        isShowingTaskStepTrace = true
                    }
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if chatManager.messages.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: placeholderIcon)
                                    .font(.system(size: 32))
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .padding(.bottom, 4)
                                Text("\(currentMode.rawValue) Mode")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                Text(placeholderDescription)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary.opacity(0.8))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        }

                        ForEach(chatManager.messages) { message in
                            ChatBubbleView(message: message, onShowGuideTrace: { messageID in
                                if let guideEntries = chatManager.guideTraceEntries(messageID: messageID), !guideEntries.isEmpty {
                                    selectedGuideTraceEntries = guideEntries
                                } else {
                                    let fallback = chatManager.traceMessage(messageID: messageID) ?? "No trace information found for this message in the current session."
                                    selectedGuideTraceEntries = [ChatTaskTraceEntry(title: "Trace", body: fallback)]
                                }
                                isShowingGuideTrace = true
                            })
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: chatManager.messages.count) { _ in
                    if let lastId = chatManager.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            if let err = chatManager.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()

            if let image = pendingImage {
                HStack(spacing: 8) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 84, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                        )

                    Text("Screenshot attached")
                        .font(.caption)

                    Spacer()

                    Button {
                        pendingImage = nil
                        pendingImageURL = nil
                    }
                    label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove screenshot")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .center, spacing: 4) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 36, height: 4)
                        .padding(.bottom, 2)
                        .help("Drag top edge to resize input area")
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if inputEditorDragStartHeight == nil {
                                        inputEditorDragStartHeight = inputEditorHeight
                                    }
                                    let baseHeight = inputEditorDragStartHeight ?? inputEditorHeight
                                    // Dragging up (negative) increases height
                                    let proposedHeight = baseHeight - value.translation.height
                                    inputEditorHeight = min(max(proposedHeight, minInputEditorHeight), maxInputEditorHeight)
                                }
                                .onEnded { _ in
                                    inputEditorDragStartHeight = nil
                                }
                        )

                    ZStack(alignment: .topLeading) {
                        ChatInputTextView(text: $draft) {
                            sendDraft()
                        }
                            .frame(minHeight: inputEditorHeight, maxHeight: inputEditorHeight)
                            .padding(.horizontal, 2)

                        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Type your message...")
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity)

                if chatManager.isSending {
                    Button("Stop") {
                        chatManager.cancelSending()
                    }
                } else {
                    Button("Send") {
                        sendDraft()
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImageURL == nil)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 320, minHeight: 420)
        .onReceive(NotificationCenter.default.publisher(for: .cameraPictureCaptured)) { notification in
            if chatManager.consumePendingCapturePreviewSuppression() {
                pendingImage = nil
                pendingImageURL = nil
                return
            }

            if let image = notification.userInfo?["image"] as? NSImage {
                pendingImage = image
            }
            if let fileURL = notification.userInfo?["fileURL"] as? URL {
                pendingImageURL = fileURL
            }
        }
        .sheet(isPresented: $isShowingAITrace) {
            AITraceViewerDialog()
        }
        .sheet(isPresented: $isShowingTaskStepTrace) {
            TaskStepTraceDialog(title: selectedTaskStepTraceTitle, entries: selectedTaskStepTraceEntries)
        }
        .sheet(isPresented: $isShowingGuideTrace) {
            GuideTraceDialog(entries: selectedGuideTraceEntries, isPresented: $isShowingGuideTrace)
        }
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        let imageURL = pendingImageURL
        pendingImage = nil
        pendingImageURL = nil
        chatManager.sendMessage(text, attachmentFileURL: imageURL)
    }
}
