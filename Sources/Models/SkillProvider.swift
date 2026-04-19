import Foundation

enum SkillProvider: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex"
        }
    }

    var searchPrompt: String {
        switch self {
        case .claudeCode:
            return "Search Claude Code skills"
        case .codex:
            return "Search Codex skills"
        }
    }

    var addSkillTitle: String {
        "Add \(displayName) Skill"
    }

    var addSkillHelp: String {
        addSkillTitle
    }
}
