import Foundation

// MARK: - ChatPersistenceService
// Owns all chat-history load/save logic that previously lived in
// ChatManager+Persistence.swift. Accessed through ChatManager's `persistence`
// property; ChatManager thin-delegates its protocol requirements here.

@MainActor
final class ChatPersistenceService {

    private let context: any ChatContext

    init(context: any ChatContext) {
        self.context = context
    }

    // MARK: - File URL

    static func makeHistoryURL() -> URL {
        let fm   = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("Openterface", isDirectory: true)
            .appendingPathComponent("chat_history.json")
    }

    // MARK: - Load

    func loadHistory() {
        do {
            let data = try Data(contentsOf: context.historyURL)
            if let state = try? context.decoder.decode(ChatManager.PersistedChatState.self, from: data) {
                context.messages            = state.messages
                context.currentPlan         = state.currentPlan
                context.plannerTraceEntries = state.plannerTraceEntries
                context.taskStepTraces      = Dictionary(
                    uniqueKeysWithValues: state.taskTraces.map { ($0.taskID, $0.entries) }
                )
            } else {
                context.messages            = try context.decoder.decode([ChatMessage].self, from: data)
                context.currentPlan         = nil
                context.plannerTraceEntries = []
                context.taskStepTraces      = [:]
            }
        } catch {
            context.messages            = []
            context.currentPlan         = nil
            context.plannerTraceEntries = []
            context.taskStepTraces      = [:]
        }
    }

    // MARK: - Save

    func persistHistory() {
        do {
            try FileManager.default.createDirectory(
                at: context.historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let state = ChatManager.PersistedChatState(
                messages:            context.messages,
                currentPlan:         context.currentPlan,
                plannerTraceEntries: context.plannerTraceEntries,
                taskTraces:          context.taskStepTraces.map {
                    ChatManager.PersistedTaskTrace(taskID: $0.key, entries: $0.value)
                }
            )
            let data = try context.encoder.encode(state)
            try data.write(to: context.historyURL, options: .atomic)
        } catch {
            // Intentionally silent: persistence errors must not break the chat UI.
        }
    }
}
