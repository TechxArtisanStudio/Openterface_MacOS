import Foundation
import Combine

// MARK: - ChatSkill

/// A single AI skill that can be triggered as a quick action from the chat panel.
///
/// Skills are stored as JSON files in the user-accessible Skills folder so that
/// anyone can add, edit, or remove them without recompiling the app.
///
/// Minimal JSON example:
/// ```json
/// {
///   "id": "my-skill",
///   "name": "My Skill",
///   "icon": "sparkles",
///   "prompt": "Describe what you see on the screen.",
///   "captureScreen": true
/// }
/// ```
struct ChatSkill: Identifiable, Codable, Equatable {
    /// Unique identifier used to deduplicate and track the skill.
    let id: String
    /// Display name shown on the quick-action button.
    let name: String
    /// SF Symbol name used as the button icon.
    let icon: String
    /// The full prompt text sent to the AI (also shown in the user chat bubble).
    let prompt: String
    /// When `true` the app captures a screenshot of the target machine before sending.
    let captureScreen: Bool
    /// Optional shorter label shown in the chat bubble instead of the full prompt.
    var userLabel: String?

    /// Text displayed in the chat bubble when the skill is triggered.
    var displayLabel: String { userLabel?.isEmpty == false ? userLabel! : name }
}

// MARK: - SkillManager

/// Loads and vends ``ChatSkill`` definitions from the user-accessible Skills folder.
///
/// On first launch the manager creates `~/Documents/Openterface/Skills/` and seeds
/// the bundled default skills as JSON files there so users have a working example
/// they can copy to create their own.
@MainActor
final class SkillManager: ObservableObject {
    static let shared = SkillManager()

    /// All currently loaded skills in display order.
    @Published private(set) var skills: [ChatSkill] = []

    /// The folder where user-editable skill JSON files live.
    static var skillsFolder: URL {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("Openterface/Skills", isDirectory: true)
    }

    // MARK: Built-in skills

    private let builtInSkills: [ChatSkill] = [
        ChatSkill(
            id: "check-messages",
            name: "Check Messages",
            icon: "envelope.badge",
            prompt: """
Look at this screenshot of the target machine and identify any unread or pending messages. \
For every messaging app, notification badge, or chat window visible, report:

• App / Service name
• Sender name (exactly as shown)
• Number of unread messages (as shown by a badge or counter)
• Brief preview of the message text if readable

List each sender on its own line. \
If no messaging apps or unread messages are visible, say so clearly.
""",
            captureScreen: true,
            userLabel: "Check messages on target screen"
        )
    ]

    // MARK: Init

    private init() {
        seedAndLoad()
    }

    // MARK: Public API

    /// Re-reads the Skills folder from disk (e.g. after the user adds a file).
    func reload() {
        seedAndLoad()
    }

    // MARK: Private helpers

    private func seedAndLoad() {
        let folder = SkillManager.skillsFolder
        let fm = FileManager.default

        // Create the folder if it doesn't exist yet.
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        // Write each built-in skill as a JSON file if it isn't there already.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for skill in builtInSkills {
            let url = folder.appendingPathComponent("\(skill.id).json")
            if !fm.fileExists(atPath: url.path),
               let data = try? encoder.encode(skill) {
                try? data.write(to: url, options: .atomic)
            }
        }

        // Load all JSON files from the folder.
        let loaded = loadFromFolder(folder)

        // Merge: built-in order first, then extra user skills alphabetically.
        var merged: [ChatSkill] = []
        var seenIDs = Set<String>()
        for builtin in builtInSkills {
            // Prefer the on-disk version so users can edit built-ins.
            let live = loaded.first { $0.id == builtin.id } ?? builtin
            merged.append(live)
            seenIDs.insert(builtin.id)
        }
        for skill in loaded where !seenIDs.contains(skill.id) {
            merged.append(skill)
            seenIDs.insert(skill.id)
        }
        skills = merged
    }

    private func loadFromFolder(_ folder: URL) -> [ChatSkill] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        return items
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> ChatSkill? in
                guard let data = try? Data(contentsOf: url),
                      let skill = try? decoder.decode(ChatSkill.self, from: data)
                else { return nil }
                return skill
            }
    }
}
