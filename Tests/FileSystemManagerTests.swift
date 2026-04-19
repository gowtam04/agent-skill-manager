import Testing
import Foundation
@testable import AgentSkillManager

@Suite("FileSystemManager Tests")
struct FileSystemManagerTests {

    // MARK: - Helpers

    /// Creates a temporary directory structure with skills/ and skills-disabled/ subdirectories.
    /// Returns (tempRoot, skillsDir, disabledDir).
    private func makeTempEnvironment() throws -> (URL, URL, URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemManagerTests-\(UUID().uuidString)", isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        let disabledDir = tempRoot.appendingPathComponent("skills-disabled", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabledDir, withIntermediateDirectories: true)
        return (tempRoot, skillsDir, disabledDir)
    }

    /// Removes the given directory and all its contents.
    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates a skill directory with a SKILL.md file inside the given parent directory.
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
        Do something useful.
        """
        try skillMD.write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return skillDir
    }

    /// Creates a FileSystemManager pointing at the given temp directories.
    private func makeManager(skillsDir: URL, disabledDir: URL) -> FileSystemManager {
        FileSystemManager(
            skillsDirectoryURL: skillsDir,
            disabledDirectoryURL: disabledDir
        )
    }

    // MARK: - Scan: Empty Directories

    @Test("Scan empty skills directory returns empty list")
    func scanEmptyDirectories() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let results = try manager.scanSkills()

        #expect(results.isEmpty)
    }

    // MARK: - Scan: Finding Skills

    @Test("Scan finds skills in skills/ directory as enabled")
    func scanFindsEnabledSkills() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "alpha", in: skillsDir)
        try createSkillDirectory(named: "beta", in: skillsDir)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let results = try manager.scanSkills()

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.isEnabled })
    }

    @Test("Scan finds skills in skills-disabled/ directory as disabled")
    func scanFindsDisabledSkills() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "gamma", in: disabledDir)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let results = try manager.scanSkills()

        #expect(results.count == 1)
        #expect(results.allSatisfy { !$0.isEnabled })
    }

    @Test("Scan finds skills in both directories")
    func scanFindsBothEnabledAndDisabled() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "enabled-skill", in: skillsDir)
        try createSkillDirectory(named: "disabled-skill", in: disabledDir)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let results = try manager.scanSkills()

        #expect(results.count == 2)
        let enabledResults = results.filter { $0.isEnabled }
        let disabledResults = results.filter { !$0.isEnabled }
        #expect(enabledResults.count == 1)
        #expect(disabledResults.count == 1)
    }

    @Test("Scan works without a disabled directory for Codex-style storage")
    func scanWithoutDisabledDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemManagerTests-\(UUID().uuidString)", isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("codex-skills", isDirectory: true)
        defer { cleanUp(tempRoot) }

        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try createSkillDirectory(named: "codex-skill", in: skillsDir)

        let manager = FileSystemManager(skillsDirectoryURL: skillsDir)
        let results = try manager.scanSkills()

        #expect(results.count == 1)
        #expect(results.first?.directoryURL.lastPathComponent == "codex-skill")
        #expect(results.first?.isEnabled == true)
    }

    @Test("Scan ignores directories without SKILL.md")
    func scanIgnoresDirectoriesWithoutSkillMD() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create a directory without SKILL.md
        let noSkillDir = skillsDir.appendingPathComponent("not-a-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: noSkillDir, withIntermediateDirectories: true)
        try "just a readme".write(
            to: noSkillDir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        // Create one with SKILL.md
        try createSkillDirectory(named: "real-skill", in: skillsDir)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let results = try manager.scanSkills()

        #expect(results.count == 1)
        #expect(results.first?.skillMDContent.contains("real-skill") == true)
    }

    // MARK: - Scan: Symlink Detection

    @Test("Scan detects symlinked skill directories")
    func scanDetectsSymlinks() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create a "source" skill directory outside skills/
        let sourceDir = tempRoot.appendingPathComponent("source-repos", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "linked-skill", in: sourceDir)

        // Create a symlink in skills/ pointing to the source
        let symlinkPath = skillsDir.appendingPathComponent("linked-skill")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: sourceSkill)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let results = try manager.scanSkills()

        #expect(results.count == 1)
        let discovered = try #require(results.first)
        #expect(discovered.isSymlink == true)
        #expect(discovered.symlinkTarget != nil)
    }

    // MARK: - Copy Skill

    @Test("Copy a skill directory into skills/")
    func copySkill() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create source skill outside of skills/
        let sourceDir = tempRoot.appendingPathComponent("external", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "import-me", in: sourceDir)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.copySkill(from: sourceSkill, to: "import-me")

        // Verify the skill was copied
        let copiedSkillMD = skillsDir
            .appendingPathComponent("import-me")
            .appendingPathComponent("SKILL.md")
        #expect(FileManager.default.fileExists(atPath: copiedSkillMD.path))

        let content = try String(contentsOf: copiedSkillMD, encoding: .utf8)
        #expect(content.contains("import-me"))
    }

    @Test("Copy skill overwrites existing when same name exists")
    func copySkillOverwritesExisting() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create existing skill in skills/
        try createSkillDirectory(named: "overwrite-me", in: skillsDir, content: """
        ---
        name: overwrite-me
        description: Old version
        ---
        Old instructions.
        """)

        // Create new version outside
        let sourceDir = tempRoot.appendingPathComponent("external", isDirectory: true)
        try createSkillDirectory(named: "overwrite-me", in: sourceDir, content: """
        ---
        name: overwrite-me
        description: New version
        ---
        New instructions.
        """)

        let sourceSkill = sourceDir.appendingPathComponent("overwrite-me")
        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.copySkill(from: sourceSkill, to: "overwrite-me")

        let copiedContent = try String(
            contentsOf: skillsDir
                .appendingPathComponent("overwrite-me")
                .appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        #expect(copiedContent.contains("New version"))
    }

    // MARK: - Move Skill

    @Test("Move skill from skills/ to skills-disabled/ (disable)")
    func moveSkillToDisabled() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "movable", in: skillsDir)
        let destinationURL = disabledDir.appendingPathComponent("movable")

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.moveSkill(from: skillDir, to: destinationURL)

        #expect(!FileManager.default.fileExists(atPath: skillDir.path))
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("Move skill from skills-disabled/ to skills/ (enable)")
    func moveSkillToEnabled() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "re-enable", in: disabledDir)
        let destinationURL = skillsDir.appendingPathComponent("re-enable")

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.moveSkill(from: skillDir, to: destinationURL)

        #expect(!FileManager.default.fileExists(atPath: skillDir.path))
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("Move detects name conflict in target directory")
    func moveSkillConflict() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create skill in both directories with the same name
        let sourceDir = try createSkillDirectory(named: "conflict", in: disabledDir)
        try createSkillDirectory(named: "conflict", in: skillsDir)

        let destinationURL = skillsDir.appendingPathComponent("conflict")
        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)

        #expect(throws: (any Error).self) {
            try manager.moveSkill(from: sourceDir, to: destinationURL)
        }
    }

    // MARK: - Delete Skill

    @Test("Delete a regular directory")
    func deleteRegularDirectory() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "delete-me", in: skillsDir)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.deleteSkill(at: skillDir)

        #expect(!FileManager.default.fileExists(atPath: skillDir.path))
    }

    @Test("Delete a symlink removes link only, not source")
    func deleteSymlink() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create source skill
        let sourceDir = tempRoot.appendingPathComponent("source-repos", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "linked", in: sourceDir)

        // Create symlink in skills/
        let symlinkPath = skillsDir.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: sourceSkill)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.deleteSkill(at: symlinkPath)

        // Symlink should be gone
        #expect(!FileManager.default.fileExists(atPath: symlinkPath.path))
        // Source should still exist
        #expect(FileManager.default.fileExists(atPath: sourceSkill.path))
    }

    // MARK: - Symlink Operations

    @Test("Detect symlink correctly returns true for symlinks")
    func isSymlinkTrue() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let sourceDir = tempRoot.appendingPathComponent("source", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "target", in: sourceDir)
        let symlinkPath = skillsDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: sourceSkill)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        #expect(manager.isSymlink(at: symlinkPath))
    }

    @Test("Detect symlink correctly returns false for regular directories")
    func isSymlinkFalse() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "regular", in: skillsDir)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        #expect(!manager.isSymlink(at: skillDir))
    }

    @Test("Resolve symlink to target path")
    func resolveSymlink() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let sourceDir = tempRoot.appendingPathComponent("source", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "target-skill", in: sourceDir)
        let symlinkPath = skillsDir.appendingPathComponent("my-link")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: sourceSkill)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let resolved = try manager.resolveSymlink(at: symlinkPath)

        // Standardize both paths for comparison (resolves /private/var vs /var, etc.)
        #expect(resolved.standardizedFileURL == sourceSkill.standardizedFileURL)
    }

    @Test("Create symlink creates a working symbolic link")
    func createSymlink() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let sourceDir = tempRoot.appendingPathComponent("source", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "link-target", in: sourceDir)

        let symlinkPath = skillsDir.appendingPathComponent("new-link")

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.createSymlink(at: symlinkPath, pointingTo: sourceSkill)

        #expect(manager.isSymlink(at: symlinkPath))

        // Verify the symlink points to the correct target
        let resolved = try manager.resolveSymlink(at: symlinkPath)
        #expect(resolved.standardizedFileURL == sourceSkill.standardizedFileURL)

        // Verify the SKILL.md is accessible through the symlink
        let content = try String(
            contentsOf: symlinkPath.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        #expect(content.contains("link-target"))
    }

    // MARK: - Ensure Directory Exists

    @Test("Ensure directory creation creates directory when missing")
    func ensureDirectoryCreatesWhenMissing() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanUp(tempRoot) }

        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        let disabledDir = tempRoot.appendingPathComponent("skills-disabled", isDirectory: true)

        // Neither directory exists yet
        #expect(!FileManager.default.fileExists(atPath: skillsDir.path))

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.ensureDirectoryExists(at: skillsDir)

        #expect(FileManager.default.fileExists(atPath: skillsDir.path))
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: skillsDir.path, isDirectory: &isDir)
        #expect(isDir.boolValue)
    }

    @Test("Ensure directory creation is no-op when directory already exists")
    func ensureDirectoryNoOpWhenExists() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Directory already exists — this should not throw
        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.ensureDirectoryExists(at: skillsDir)

        #expect(FileManager.default.fileExists(atPath: skillsDir.path))
    }

    // MARK: - Scan: DiscoveredSkill Content

    @Test("Scan returns correct SKILL.md content for each discovered skill")
    func scanReturnsSkillMDContent() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let expectedContent = """
        ---
        name: content-test
        description: Testing content retrieval
        ---
        Custom body.
        """
        try createSkillDirectory(named: "content-test", in: skillsDir, content: expectedContent)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let results = try manager.scanSkills()

        let discovered = try #require(results.first)
        #expect(discovered.skillMDContent.contains("Testing content retrieval"))
        #expect(discovered.skillMDContent.contains("Custom body."))
    }

    @Test("Scan returns correct directory URL for each discovered skill")
    func scanReturnsCorrectDirectoryURL() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "url-check", in: skillsDir)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let results = try manager.scanSkills()

        let discovered = try #require(results.first)
        let expectedPath = skillsDir.appendingPathComponent("url-check").standardizedFileURL
        #expect(discovered.directoryURL.standardizedFileURL == expectedPath)
    }

    // MARK: - File Tree Enumeration

    @Test("Enumerate returns empty array for skill with only SKILL.md")
    func enumerateSkillOnlySkillMD() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "minimal", in: skillsDir)

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let tree = manager.enumerateSkillFiles(at: skillDir)

        #expect(tree.isEmpty)
    }

    @Test("Enumerate finds files alongside SKILL.md")
    func enumerateFindsExtraFiles() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "multi-file", in: skillsDir)
        try "print('hello')".write(
            to: skillDir.appendingPathComponent("helper.py"),
            atomically: true, encoding: .utf8
        )
        try "{}".write(
            to: skillDir.appendingPathComponent("config.json"),
            atomically: true, encoding: .utf8
        )

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let tree = manager.enumerateSkillFiles(at: skillDir)

        #expect(tree.count == 2)
        let names = tree.map(\.name).sorted()
        #expect(names == ["config.json", "helper.py"])
        #expect(tree.allSatisfy { !$0.isDirectory })
    }

    @Test("Enumerate builds nested tree for subdirectories")
    func enumerateBuildsNestedTree() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "nested-skill", in: skillsDir)

        // Create scripts/ subdirectory with files
        let scriptsDir = skillDir.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try "#!/bin/bash".write(
            to: scriptsDir.appendingPathComponent("run.sh"),
            atomically: true, encoding: .utf8
        )
        try "#!/bin/bash".write(
            to: scriptsDir.appendingPathComponent("build.sh"),
            atomically: true, encoding: .utf8
        )

        // Create a top-level file
        try "{}".write(
            to: skillDir.appendingPathComponent("data.json"),
            atomically: true, encoding: .utf8
        )

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let tree = manager.enumerateSkillFiles(at: skillDir)

        // Should have data.json and scripts/
        #expect(tree.count == 2)

        let scriptsNode = tree.first { $0.name == "scripts" }
        #expect(scriptsNode?.isDirectory == true)
        #expect(scriptsNode?.children.count == 2)

        let scriptNames = scriptsNode?.children.map(\.name).sorted()
        #expect(scriptNames == ["build.sh", "run.sh"])

        let dataNode = tree.first { $0.name == "data.json" }
        #expect(dataNode?.isDirectory == false)
    }

    @Test("Enumerate excludes hidden files")
    func enumerateExcludesHiddenFiles() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "hidden-test", in: skillsDir)
        try "hidden".write(
            to: skillDir.appendingPathComponent(".hidden"),
            atomically: true, encoding: .utf8
        )
        try "visible".write(
            to: skillDir.appendingPathComponent("visible.txt"),
            atomically: true, encoding: .utf8
        )

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let tree = manager.enumerateSkillFiles(at: skillDir)

        #expect(tree.count == 1)
        #expect(tree.first?.name == "visible.txt")
    }

    // MARK: - Zip Export

    @Test("zipSkill creates a valid zip file at the destination")
    func zipSkillCreatesZip() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "export-me", in: skillsDir)

        let zipURL = tempRoot.appendingPathComponent("export-me.zip")

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.zipSkill(at: skillDir, to: zipURL)

        #expect(FileManager.default.fileExists(atPath: zipURL.path))

        // Verify it's a real zip by checking the file has content
        let attrs = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let size = attrs[.size] as? UInt64 ?? 0
        #expect(size > 0)
    }

    @Test("zipSkill includes all skill files in the archive")
    func zipSkillIncludesAllFiles() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "multi-export", in: skillsDir)
        try "print('hello')".write(
            to: skillDir.appendingPathComponent("helper.py"),
            atomically: true, encoding: .utf8
        )
        try "{}".write(
            to: skillDir.appendingPathComponent("config.json"),
            atomically: true, encoding: .utf8
        )

        let zipURL = tempRoot.appendingPathComponent("multi-export.zip")
        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        try manager.zipSkill(at: skillDir, to: zipURL)

        #expect(FileManager.default.fileExists(atPath: zipURL.path))

        // Unzip and verify contents
        let unzipDir = tempRoot.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, unzipDir.path]
        try process.run()
        process.waitUntilExit()

        let extractedSkillDir = unzipDir.appendingPathComponent("multi-export")
        #expect(FileManager.default.fileExists(
            atPath: extractedSkillDir.appendingPathComponent("SKILL.md").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: extractedSkillDir.appendingPathComponent("helper.py").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: extractedSkillDir.appendingPathComponent("config.json").path
        ))
    }

    @Test("Scan populates fileTree in DiscoveredSkill")
    func scanPopulatesFileTree() throws {
        let (tempRoot, skillsDir, disabledDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let skillDir = try createSkillDirectory(named: "tree-scan", in: skillsDir)
        try "content".write(
            to: skillDir.appendingPathComponent("extra.txt"),
            atomically: true, encoding: .utf8
        )

        let manager = makeManager(skillsDir: skillsDir, disabledDir: disabledDir)
        let results = try manager.scanSkills()

        let discovered = try #require(results.first)
        #expect(discovered.fileTree.count == 1)
        #expect(discovered.fileTree.first?.name == "extra.txt")
    }
}
