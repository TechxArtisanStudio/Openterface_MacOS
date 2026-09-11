import Foundation

// MARK: - ChatManager + Persistence (thin delegation stub)
// Logic lives in ChatPersistenceService (AI/Services/ChatPersistenceService.swift).
// ChatManager retains these entry points for backward-compatible call sites and
// to satisfy the ChatContext protocol requirements.

extension ChatManager {

    static func makeHistoryURL() -> URL { ChatPersistenceService.makeHistoryURL() }

    func loadHistory()    { persistence.loadHistory() }
    func persistHistory() { persistence.persistHistory() }
}
