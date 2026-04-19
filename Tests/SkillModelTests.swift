import Testing
import Foundation
@testable import AgentSkillManager

@Suite("Skill Model Tests")
struct SkillModelTests {

    @Test("Initializes a Claude skill with all required fields")
    func initClaudeSkill() {
        let directoryURL = URL(fileURLWithPath: "/Users/test/.claude/skills/my-skill")
        let skill = Skill(
            id: UUID(),
            provider: .claudeCode,
            name: "my-skill",
            description: "A test skill",
            directoryURL: directoryURL,
            isSymlink: false,
            symlinkTarget: nil,
            isEnabled: true,
            sourceRepoURL: nil,
            rawContent: "---\nname: my-skill\ndescription: A test skill\n---\nBody",
            fileTree: []
        )

        #expect(skill.provider == .claudeCode)
        #expect(skill.name == "my-skill")
        #expect(skill.directoryURL == directoryURL)
        #expect(skill.isEnabled == true)
        #expect(skill.sourceRepoURL == nil)
        #expect(skill.skillMDURL.path.hasSuffix("/my-skill/SKILL.md"))
    }

    @Test("Initializes a Codex skill with provider metadata")
    func initCodexSkill() {
        let directoryURL = URL(fileURLWithPath: "/Users/test/.agents/skills/frontend-design")
        let targetURL = URL(fileURLWithPath: "/Users/test/repos/frontend-design")
        let skill = Skill(
            id: UUID(),
            provider: .codex,
            name: "frontend-design",
            description: "A Codex skill",
            directoryURL: directoryURL,
            isSymlink: true,
            symlinkTarget: targetURL,
            isEnabled: false,
            sourceRepoURL: "https://github.com/user/repo",
            rawContent: "",
            fileTree: []
        )

        #expect(skill.provider == .codex)
        #expect(skill.isSymlink == true)
        #expect(skill.symlinkTarget == targetURL)
        #expect(skill.isEnabled == false)
        #expect(skill.sourceRepoURL == "https://github.com/user/repo")
    }

    @Test("Each skill gets a unique UUID")
    func uniqueIDs() {
        let url = URL(fileURLWithPath: "/Users/test/.claude/skills/skill")
        let skill1 = Skill(
            id: UUID(),
            provider: .claudeCode,
            name: "skill-1",
            description: "First",
            directoryURL: url,
            isSymlink: false,
            symlinkTarget: nil,
            isEnabled: true,
            sourceRepoURL: nil,
            rawContent: "",
            fileTree: []
        )
        let skill2 = Skill(
            id: UUID(),
            provider: .claudeCode,
            name: "skill-2",
            description: "Second",
            directoryURL: url,
            isSymlink: false,
            symlinkTarget: nil,
            isEnabled: true,
            sourceRepoURL: nil,
            rawContent: "",
            fileTree: []
        )

        #expect(skill1.id != skill2.id)
    }

    @Test("sourceRepoURL is nil for locally imported skills")
    func sourceRepoURLNilForLocalSkills() {
        let skill = Skill(
            id: UUID(),
            provider: .claudeCode,
            name: "local-skill",
            description: "Imported from file",
            directoryURL: URL(fileURLWithPath: "/Users/test/.claude/skills/local-skill"),
            isSymlink: false,
            symlinkTarget: nil,
            isEnabled: true,
            sourceRepoURL: nil,
            rawContent: "",
            fileTree: []
        )

        #expect(skill.sourceRepoURL == nil)
    }

    @Test("symlinkTarget is nil for non-symlinked skills")
    func symlinkTargetNilForNonSymlinks() {
        let skill = Skill(
            id: UUID(),
            provider: .claudeCode,
            name: "regular-skill",
            description: "A regular copied skill",
            directoryURL: URL(fileURLWithPath: "/Users/test/.claude/skills/regular-skill"),
            isSymlink: false,
            symlinkTarget: nil,
            isEnabled: true,
            sourceRepoURL: nil,
            rawContent: "",
            fileTree: []
        )

        #expect(skill.symlinkTarget == nil)
        #expect(skill.isSymlink == false)
    }
}
