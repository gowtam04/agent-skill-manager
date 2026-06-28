import Foundation

enum SkillProvider: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case grok
    case shared

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode:
            return "Claude"
        case .codex:
            return "Codex"
        case .grok:
            return "Grok"
        case .shared:
            return "Shared"
        }
    }

    var searchPrompt: String {
        switch self {
        case .claudeCode:
            return "Search Claude Code skills"
        case .codex:
            return "Search Codex skills"
        case .grok:
            return "Search Grok skills"
        case .shared:
            return "Search shared skills"
        }
    }

    var addSkillTitle: String {
        "Add \(displayName) Skill"
    }

    var addSkillHelp: String {
        addSkillTitle
    }
}
