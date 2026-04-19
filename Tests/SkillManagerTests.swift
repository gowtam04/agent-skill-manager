import Testing
import Foundation
@testable import AgentSkillManager

@Suite("SkillManager Tests")
@MainActor
struct SkillManagerTests {

    // MARK: - Helpers

    /// Creates a full temporary directory structure simulating the app environment.
    /// Returns (tempRoot, skillsDir, disabledDir, appSupportDir).
    private func makeTempEnvironment() throws -> (URL, URL, URL, URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillManagerTests-\(UUID().uuidString)", isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        let disabledDir = tempRoot.appendingPathComponent("skills-disabled", isDirectory: true)
        let appSupportDir = tempRoot.appendingPathComponent("app-support", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabledDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        return (tempRoot, skillsDir, disabledDir, appSupportDir)
    }

    /// Removes the given directory and all its contents.
    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates a skill directory with a valid SKILL.md file.
    @discardableResult
    private func createSkillDirectory(
        named name: String,
        in parentDir: URL,
        content: String? = nil
    ) throws -> URL {
        let skillDir = parentDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillMD = content ?? """
        ---
        name: \(name)
        description: A test skill called \(name)
        ---
        # Instructions
        Do something useful for \(name).
        """
        try skillMD.write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return skillDir
    }

    /// Creates a skill directory WITHOUT a SKILL.md file (for testing error handling).
    @discardableResult
    private func createDirectoryWithoutSkillMD(
        named name: String,
        in parentDir: URL
    ) throws -> URL {
        let dir = parentDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "Just a readme".write(
            to: dir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        return dir
    }

    /// Creates a skill directory with malformed SKILL.md (unparseable frontmatter).
    @discardableResult
    private func createSkillWithBadFrontmatter(
        named name: String,
        in parentDir: URL
    ) throws -> URL {
        let skillDir = parentDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let badContent = """
        This file has no YAML frontmatter at all.
        Just plain text with no --- delimiters.
        """
        try badContent.write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return skillDir
    }

    /// Creates a SkillManager configured to use the given temp directories.
    private func makeSkillManager(
        skillsDir: URL,
        disabledDir: URL,
        appSupportDir: URL,
        provider: SkillProvider = .claudeCode,
        codexConfigURL: URL? = nil
    ) -> SkillManager {
        let fileSystemManager = FileSystemManager(
            skillsDirectoryURL: skillsDir,
            disabledDirectoryURL: provider == .claudeCode ? disabledDir : nil
        )
        let metadataStore = MetadataStore(
            fileURL: appSupportDir.appendingPathComponent(
                provider == .claudeCode ? "metadata.json" : "codex-metadata.json"
            )
        )
        return SkillManager(
            provider: provider,
            fileSystemManager: fileSystemManager,
            gitManager: GitManager(),
            skillParser: SkillParser.self,
            metadataStore: metadataStore,
            codexConfigStore: codexConfigURL.map(CodexConfigStore.init(fileURL:))
        )
    }

    // MARK: - Load Skills

    @Test("Load skills from disk populates skills array")
    func loadSkillsPopulatesArray() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "skill-one", in: skillsDir)
        try createSkillDirectory(named: "skill-two", in: skillsDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        #expect(manager.skills.count == 2)
        let names = manager.skills.map(\.name).sorted()
        #expect(names == ["skill-one", "skill-two"])
    }

    @Test("Load skills handles empty directories")
    func loadSkillsEmptyDirectories() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        #expect(manager.skills.isEmpty)
    }

    @Test("Load skills handles skills with unparseable SKILL.md — uses directory name per NFR-2")
    func loadSkillsWithUnparseableFrontmatter() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillWithBadFrontmatter(named: "broken-skill", in: skillsDir)
        try createSkillDirectory(named: "good-skill", in: skillsDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        // Both should appear (NFR-2: unparseable skills still show up)
        #expect(manager.skills.count == 2)

        // The broken skill should use the directory name as its display name
        let brokenSkill = manager.skills.first { $0.name == "broken-skill" }
        #expect(brokenSkill != nil)
    }

    @Test("Load skills marks enabled and disabled skills correctly")
    func loadSkillsEnabledDisabledStatus() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "active-skill", in: skillsDir)
        try createSkillDirectory(named: "inactive-skill", in: disabledDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let activeSkill = manager.skills.first { $0.name == "active-skill" }
        let inactiveSkill = manager.skills.first { $0.name == "inactive-skill" }

        #expect(activeSkill?.isEnabled == true)
        #expect(inactiveSkill?.isEnabled == false)
    }

    // MARK: - Add Skill from File

    @Test("Add skill from file copies to skills directory")
    func addSkillFromFile() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create source skill outside of managed dirs
        let externalDir = tempRoot.appendingPathComponent("external", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "imported-skill", in: externalDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.addSkillFromFile(sourceURL: sourceSkill)

        // Verify the skill was copied into skills/
        let copiedPath = skillsDir.appendingPathComponent("imported-skill")
            .appendingPathComponent("SKILL.md")
        #expect(FileManager.default.fileExists(atPath: copiedPath.path))
    }

    @Test("Add skill from file validates SKILL.md exists")
    func addSkillFromFileValidatesSkillMD() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create a directory with SKILL.md
        let externalDir = tempRoot.appendingPathComponent("external", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "valid-skill", in: externalDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )

        // This should succeed since SKILL.md exists
        try await manager.addSkillFromFile(sourceURL: sourceSkill)

        let copiedSkillMD = skillsDir
            .appendingPathComponent("valid-skill")
            .appendingPathComponent("SKILL.md")
        #expect(FileManager.default.fileExists(atPath: copiedSkillMD.path))
    }

    @Test("Add skill from file rejects directory without SKILL.md")
    func addSkillFromFileRejectsNoSkillMD() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let externalDir = tempRoot.appendingPathComponent("external", isDirectory: true)
        let noSkillDir = try createDirectoryWithoutSkillMD(named: "no-skill-md", in: externalDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )

        await #expect(throws: (any Error).self) {
            try await manager.addSkillFromFile(sourceURL: noSkillDir)
        }
    }

    // MARK: - Enable / Disable Skill

    @Test("Enable skill moves from disabled to enabled directory")
    func enableSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "to-enable", in: disabledDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "to-enable" })
        #expect(!skill.isEnabled)

        try await manager.enableSkill(skill)

        // Should now be in skills/ directory
        let enabledPath = skillsDir.appendingPathComponent("to-enable")
        let disabledPath = disabledDir.appendingPathComponent("to-enable")
        #expect(FileManager.default.fileExists(atPath: enabledPath.path))
        #expect(!FileManager.default.fileExists(atPath: disabledPath.path))
    }

    @Test("Disable skill moves from enabled to disabled directory")
    func disableSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "to-disable", in: skillsDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "to-disable" })
        #expect(skill.isEnabled)

        try await manager.disableSkill(skill)

        // Should now be in skills-disabled/ directory
        let enabledPath = skillsDir.appendingPathComponent("to-disable")
        let disabledPath = disabledDir.appendingPathComponent("to-disable")
        #expect(!FileManager.default.fileExists(atPath: enabledPath.path))
        #expect(FileManager.default.fileExists(atPath: disabledPath.path))
    }

    @Test("Enable/disable handles name conflict by throwing")
    func enableDisableNameConflict() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create a disabled skill and an enabled skill with the same name
        try createSkillDirectory(named: "conflict-skill", in: disabledDir)
        try createSkillDirectory(named: "conflict-skill", in: skillsDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let disabledSkill = try #require(
            manager.skills.first { $0.name == "conflict-skill" && !$0.isEnabled }
        )

        // Trying to enable should fail because one with the same name already exists in skills/
        await #expect(throws: (any Error).self) {
            try await manager.enableSkill(disabledSkill)
        }
    }

    @Test("Codex disable writes config override and marks skill disabled")
    func codexDisableWritesConfigOverride() async throws {
        let (tempRoot, _, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let codexSkillsDir = tempRoot.appendingPathComponent("codex-skills", isDirectory: true)
        let codexConfigURL = tempRoot.appendingPathComponent("codex-config.toml")
        try FileManager.default.createDirectory(at: codexSkillsDir, withIntermediateDirectories: true)
        try createSkillDirectory(named: "codex-skill", in: codexSkillsDir)

        let manager = makeSkillManager(
            skillsDir: codexSkillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir,
            provider: .codex,
            codexConfigURL: codexConfigURL
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "codex-skill" })
        try await manager.disableSkill(skill)

        let config = try String(contentsOf: codexConfigURL, encoding: .utf8)
        #expect(config.contains("[[skills.config]]"))
        #expect(config.contains("enabled = false"))
        #expect(config.contains("codex-skill/SKILL.md"))
        #expect(manager.skills.first { $0.name == "codex-skill" }?.isEnabled == false)
    }

    @Test("Codex enable removes config override and marks skill enabled")
    func codexEnableRemovesConfigOverride() async throws {
        let (tempRoot, _, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let codexSkillsDir = tempRoot.appendingPathComponent("codex-skills", isDirectory: true)
        let codexConfigURL = tempRoot.appendingPathComponent("codex-config.toml")
        try FileManager.default.createDirectory(at: codexSkillsDir, withIntermediateDirectories: true)
        let skillDir = try createSkillDirectory(named: "codex-skill", in: codexSkillsDir)
        let disabledConfig = """
        [[skills.config]]
        path = "\(skillDir.appendingPathComponent("SKILL.md").path)"
        enabled = false
        """
        try disabledConfig.write(to: codexConfigURL, atomically: true, encoding: .utf8)

        let manager = makeSkillManager(
            skillsDir: codexSkillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir,
            provider: .codex,
            codexConfigURL: codexConfigURL
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "codex-skill" })
        #expect(skill.isEnabled == false)

        try await manager.enableSkill(skill)

        let config = try String(contentsOf: codexConfigURL, encoding: .utf8)
        #expect(!config.contains("codex-skill/SKILL.md"))
        #expect(manager.skills.first { $0.name == "codex-skill" }?.isEnabled == true)
    }

    // MARK: - Delete Skill

    @Test("Delete non-symlinked skill removes directory")
    func deleteNonSymlinkedSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "delete-me", in: skillsDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "delete-me" })
        #expect(!skill.isSymlink)

        try await manager.deleteSkill(skill, removeSource: false)

        #expect(!FileManager.default.fileExists(atPath: skillDir.path))
    }

    @Test("Delete symlinked skill with removeSource=false removes only symlink")
    func deleteSymlinkSkillKeepSource() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create source skill outside managed dirs
        let sourceDir = tempRoot.appendingPathComponent("repos", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "linked-skill", in: sourceDir)

        // Create symlink in skills/
        let symlinkPath = skillsDir.appendingPathComponent("linked-skill")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: sourceSkill)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "linked-skill" })
        #expect(skill.isSymlink)

        try await manager.deleteSkill(skill, removeSource: false)

        // Symlink should be removed
        #expect(!FileManager.default.fileExists(atPath: symlinkPath.path))
        // Source should still exist
        #expect(FileManager.default.fileExists(atPath: sourceSkill.path))
    }

    @Test("Delete symlinked skill with removeSource=true removes symlink and source")
    func deleteSymlinkSkillRemoveSource() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create source skill outside managed dirs
        let sourceDir = tempRoot.appendingPathComponent("repos", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "rm-source", in: sourceDir)

        // Create symlink in skills/
        let symlinkPath = skillsDir.appendingPathComponent("rm-source")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: sourceSkill)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "rm-source" })
        #expect(skill.isSymlink)

        try await manager.deleteSkill(skill, removeSource: true)

        // Both symlink and source should be removed
        #expect(!FileManager.default.fileExists(atPath: symlinkPath.path))
        #expect(!FileManager.default.fileExists(atPath: sourceSkill.path))
    }

    // MARK: - Read / Save Skill Content

    @Test("Read skill content returns SKILL.md contents")
    func readSkillContent() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let expectedContent = """
        ---
        name: readable
        description: A readable skill
        ---
        # Custom Instructions
        These are custom instructions.
        """
        try createSkillDirectory(named: "readable", in: skillsDir, content: expectedContent)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "readable" })
        let content = try manager.readSkillContent(skill)

        #expect(content.contains("Custom Instructions"))
        #expect(content.contains("These are custom instructions."))
    }

    @Test("Save skill content writes to SKILL.md")
    func saveSkillContent() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "writable", in: skillsDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "writable" })

        let newContent = """
        ---
        name: writable
        description: Updated description
        ---
        # Updated Instructions
        Brand new content.
        """
        try manager.saveSkillContent(skill, content: newContent)

        // Read back and verify
        let savedContent = try String(
            contentsOf: skill.directoryURL.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        #expect(savedContent.contains("Updated description"))
        #expect(savedContent.contains("Brand new content."))
    }

    @Test("Save skill content to symlinked skill modifies target file")
    func saveSkillContentSymlink() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create source skill
        let sourceDir = tempRoot.appendingPathComponent("repos", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "sym-editable", in: sourceDir)

        // Create symlink in skills/
        let symlinkPath = skillsDir.appendingPathComponent("sym-editable")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: sourceSkill)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "sym-editable" })
        #expect(skill.isSymlink)

        let newContent = """
        ---
        name: sym-editable
        description: Edited through symlink
        ---
        # Symlink Edited
        Content modified through the symlink.
        """
        try manager.saveSkillContent(skill, content: newContent)

        // Verify the source file was modified (not just the symlink entry)
        let sourceContent = try String(
            contentsOf: sourceSkill.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        #expect(sourceContent.contains("Edited through symlink"))
        #expect(sourceContent.contains("Content modified through the symlink."))
    }

    // MARK: - Loading State

    @Test("isLoading is false after loadSkills completes")
    func isLoadingAfterLoad() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )

        try await manager.loadSkills()
        #expect(!manager.isLoading)
    }

    // MARK: - Delete from Disabled Directory

    @Test("Delete skill from disabled directory removes it")
    func deleteDisabledSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "delete-disabled", in: disabledDir)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let skill = try #require(manager.skills.first { $0.name == "delete-disabled" })
        #expect(!skill.isEnabled)

        try await manager.deleteSkill(skill, removeSource: false)

        #expect(!FileManager.default.fileExists(atPath: skillDir.path))
    }

    // MARK: - Symlink Detection in Loaded Skills

    @Test("Loaded skills correctly identify symlinks vs regular directories")
    func loadedSkillsIdentifySymlinks() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Regular skill
        try createSkillDirectory(named: "regular-skill", in: skillsDir)

        // Symlinked skill
        let sourceDir = tempRoot.appendingPathComponent("repos", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "linked", in: sourceDir)
        let symlinkPath = skillsDir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: sourceSkill)

        let manager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        try await manager.loadSkills()

        let regularSkill = manager.skills.first { $0.name == "regular-skill" }
        let linkedSkill = manager.skills.first { $0.name == "linked" }

        #expect(regularSkill?.isSymlink == false)
        #expect(linkedSkill?.isSymlink == true)
        #expect(linkedSkill?.symlinkTarget != nil)
    }
}
