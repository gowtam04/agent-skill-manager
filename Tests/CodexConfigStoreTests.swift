import Testing
import Foundation
@testable import AgentSkillManager

@Suite("CodexConfigStore Tests")
struct CodexConfigStoreTests {

    private func makeConfigURL() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexConfigStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir.appendingPathComponent("config.toml")
    }

    private func cleanUp(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    @Test("disableSkill appends a skills override and preserves unrelated config")
    func disableSkillPreservesUnrelatedConfig() throws {
        let configURL = try makeConfigURL()
        defer { cleanUp(configURL) }

        let initialConfig = """
        model = "gpt-5.4"

        [plugins."computer-use@openai-bundled"]
        enabled = true
        """
        try initialConfig.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CodexConfigStore(fileURL: configURL)
        let skillMDURL = URL(fileURLWithPath: "/Users/test/.agents/skills/my-skill/SKILL.md")
        try store.disableSkill(at: skillMDURL)

        let updatedConfig = try String(contentsOf: configURL, encoding: .utf8)
        #expect(updatedConfig.contains("model = \"gpt-5.4\""))
        #expect(updatedConfig.contains("[plugins.\"computer-use@openai-bundled\"]"))
        #expect(updatedConfig.contains("[[skills.config]]"))
        #expect(updatedConfig.contains("path = \"/Users/test/.agents/skills/my-skill/SKILL.md\""))
        #expect(updatedConfig.contains("enabled = false"))
    }

    @Test("disabledSkillMDPaths returns only disabled overrides")
    func disabledSkillMDPathsReturnsDisabledOverrides() throws {
        let configURL = try makeConfigURL()
        defer { cleanUp(configURL) }

        let config = """
        [[skills.config]]
        path = "/Users/test/.agents/skills/disabled/SKILL.md"
        enabled = false

        [[skills.config]]
        path = "/Users/test/.agents/skills/enabled/SKILL.md"
        enabled = true
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CodexConfigStore(fileURL: configURL)
        let disabledPaths = try store.disabledSkillMDPaths()

        #expect(disabledPaths.contains("/Users/test/.agents/skills/disabled/SKILL.md"))
        #expect(!disabledPaths.contains("/Users/test/.agents/skills/enabled/SKILL.md"))
    }

    @Test("enableSkill removes an existing matching override")
    func enableSkillRemovesMatchingOverride() throws {
        let configURL = try makeConfigURL()
        defer { cleanUp(configURL) }

        let config = """
        [[skills.config]]
        path = "/Users/test/.agents/skills/my-skill/SKILL.md"
        enabled = false

        notify = ["turn-ended"]
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CodexConfigStore(fileURL: configURL)
        let skillMDURL = URL(fileURLWithPath: "/Users/test/.agents/skills/my-skill/SKILL.md")
        try store.enableSkill(at: skillMDURL)

        let updatedConfig = try String(contentsOf: configURL, encoding: .utf8)
        #expect(!updatedConfig.contains("/Users/test/.agents/skills/my-skill/SKILL.md"))
        #expect(updatedConfig.contains("notify = [\"turn-ended\"]"))
    }

    @Test("removeOverrides removes matching symlink and source paths")
    func removeOverridesRemovesAllMatchingPaths() throws {
        let configURL = try makeConfigURL()
        defer { cleanUp(configURL) }

        let config = """
        [[skills.config]]
        path = "/Users/test/.agents/skills/my-skill/SKILL.md"
        enabled = false

        [[skills.config]]
        path = "/Users/test/repos/my-skill/SKILL.md"
        enabled = false
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CodexConfigStore(fileURL: configURL)
        try store.removeOverrides(for: [
            URL(fileURLWithPath: "/Users/test/.agents/skills/my-skill/SKILL.md"),
            URL(fileURLWithPath: "/Users/test/repos/my-skill/SKILL.md"),
        ])

        let updatedConfig = try String(contentsOf: configURL, encoding: .utf8)
        #expect(!updatedConfig.contains("/Users/test/.agents/skills/my-skill/SKILL.md"))
        #expect(!updatedConfig.contains("/Users/test/repos/my-skill/SKILL.md"))
    }
}
