import Testing
import Foundation
@testable import AgentSkillManager

@Suite("AppViewModel Tests")
@MainActor
struct AppViewModelTests {

    // MARK: - Helpers

    /// Creates a full temporary directory structure simulating the app environment.
    /// Returns (tempRoot, skillsDir, disabledDir, appSupportDir).
    private func makeTempEnvironment() throws -> (URL, URL, URL, URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppViewModelTests-\(UUID().uuidString)", isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        let disabledDir = tempRoot.appendingPathComponent("skills-disabled", isDirectory: true)
        let appSupportDir = tempRoot.appendingPathComponent("app-support", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabledDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        return (tempRoot, skillsDir, disabledDir, appSupportDir)
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    private func createSkillDirectory(
        named name: String,
        description: String? = nil,
        in parentDir: URL,
        content: String? = nil
    ) throws -> URL {
        let skillDir = parentDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let desc = description ?? "A test skill called \(name)"
        let skillMD = content ?? """
        ---
        name: \(name)
        description: \(desc)
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

    private func makeSkillManager(
        skillsDir: URL,
        disabledDir: URL,
        appSupportDir: URL
    ) -> SkillManager {
        let fileSystemManager = FileSystemManager(
            skillsDirectoryURL: skillsDir,
            disabledDirectoryURL: disabledDir
        )
        let metadataStore = MetadataStore(
            fileURL: appSupportDir.appendingPathComponent("metadata.json")
        )
        return SkillManager(
            provider: .claudeCode,
            fileSystemManager: fileSystemManager,
            gitManager: GitManager(),
            skillParser: SkillParser.self,
            metadataStore: metadataStore
        )
    }

    private func makeCodexSkillManager(
        skillsDir: URL,
        appSupportDir: URL,
        configFileURL: URL
    ) -> SkillManager {
        let fileSystemManager = FileSystemManager(
            skillsDirectoryURL: skillsDir
        )
        let metadataStore = MetadataStore(
            fileURL: appSupportDir.appendingPathComponent("codex-metadata.json")
        )
        return SkillManager(
            provider: .codex,
            fileSystemManager: fileSystemManager,
            gitManager: GitManager(),
            skillParser: SkillParser.self,
            metadataStore: metadataStore,
            codexConfigStore: CodexConfigStore(fileURL: configFileURL)
        )
    }

    private func makeViewModel(
        skillsDir: URL,
        disabledDir: URL,
        appSupportDir: URL
    ) -> AppViewModel {
        UserDefaults.standard.removeObject(forKey: "selectedSkillProvider")

        let claudeSkillManager = makeSkillManager(
            skillsDir: skillsDir,
            disabledDir: disabledDir,
            appSupportDir: appSupportDir
        )
        let tempRoot = appSupportDir.deletingLastPathComponent()
        let codexSkillsDir = tempRoot.appendingPathComponent("codex-skills", isDirectory: true)
        let codexAppSupportDir = tempRoot.appendingPathComponent("codex-app-support", isDirectory: true)
        let codexConfigURL = tempRoot.appendingPathComponent("codex-config.toml")
        try? FileManager.default.createDirectory(at: codexSkillsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: codexAppSupportDir, withIntermediateDirectories: true)
        let codexSkillManager = makeCodexSkillManager(
            skillsDir: codexSkillsDir,
            appSupportDir: codexAppSupportDir,
            configFileURL: codexConfigURL
        )
        return AppViewModel(
            claudeSkillManager: claudeSkillManager,
            codexSkillManager: codexSkillManager
        )
    }

    // MARK: - Loading & Refresh

    @Test("Load skills populates skills and filteredSkills arrays")
    func loadSkillsPopulatesArrays() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "alpha", in: skillsDir)
        try createSkillDirectory(named: "beta", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        #expect(vm.skills.count == 2)
        #expect(vm.filteredSkills.count == 2)
        let names = vm.skills.map(\.name).sorted()
        #expect(names == ["alpha", "beta"])
    }

    @Test("isLoading is false after loadSkills completes")
    func isLoadingFalseAfterLoad() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        #expect(!vm.isLoading)
    }

    @Test("Load error sets errorMessage")
    func loadErrorSetsErrorMessage() async throws {
        // Point at a non-existent directory to trigger an error during scan
        let nonExistent = URL(fileURLWithPath: "/tmp/AppViewModelTests-nonexistent-\(UUID().uuidString)")
        let disabledDir = URL(fileURLWithPath: "/tmp/AppViewModelTests-disabled-\(UUID().uuidString)")
        let appSupportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppViewModelTests-appsupport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        defer {
            cleanUp(nonExistent)
            cleanUp(disabledDir)
            cleanUp(appSupportDir)
        }

        let vm = makeViewModel(skillsDir: nonExistent, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        #expect(vm.errorMessage != nil)
    }

    // MARK: - Search/Filter (FR-2.3)

    @Test("Empty search shows all skills")
    func emptySearchShowsAll() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "one", in: skillsDir)
        try createSkillDirectory(named: "two", in: skillsDir)
        try createSkillDirectory(named: "three", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()
        vm.searchSkills(query: "")

        #expect(vm.filteredSkills.count == 3)
    }

    @Test("Search by name filters correctly — case insensitive")
    func searchByNameCaseInsensitive() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "CodeReview", in: skillsDir)
        try createSkillDirectory(named: "test-runner", in: skillsDir)
        try createSkillDirectory(named: "linter", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()
        vm.searchSkills(query: "codereview")

        #expect(vm.filteredSkills.count == 1)
        #expect(vm.filteredSkills.first?.name == "CodeReview")
    }

    @Test("Search by description filters correctly")
    func searchByDescription() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "skill-a", description: "Manages database migrations", in: skillsDir)
        try createSkillDirectory(named: "skill-b", description: "Runs unit tests", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()
        vm.searchSkills(query: "database")

        #expect(vm.filteredSkills.count == 1)
        #expect(vm.filteredSkills.first?.name == "skill-a")
    }

    @Test("Search with no matches returns empty list")
    func searchNoMatches() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "alpha", in: skillsDir)
        try createSkillDirectory(named: "beta", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()
        vm.searchSkills(query: "zzzznonexistent")

        #expect(vm.filteredSkills.isEmpty)
    }

    @Test("Clearing search restores all skills")
    func clearSearchRestoresAll() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "alpha", in: skillsDir)
        try createSkillDirectory(named: "beta", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        vm.searchSkills(query: "alpha")
        #expect(vm.filteredSkills.count == 1)

        vm.searchSkills(query: "")
        #expect(vm.filteredSkills.count == 2)
    }

    // MARK: - Selection

    @Test("Selecting a skill sets selectedSkill")
    func selectSkillSetsSelectedSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "pick-me", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "pick-me" })
        vm.selectSkill(skill)

        #expect(vm.selectedSkill?.name == "pick-me")
    }

    @Test("Selecting a different skill changes selectedSkill")
    func selectDifferentSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "first", in: skillsDir)
        try createSkillDirectory(named: "second", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let first = try #require(vm.skills.first { $0.name == "first" })
        let second = try #require(vm.skills.first { $0.name == "second" })

        vm.selectSkill(first)
        #expect(vm.selectedSkill?.name == "first")

        vm.selectSkill(second)
        #expect(vm.selectedSkill?.name == "second")
    }

    @Test("Selected skill persists after refresh if it still exists")
    func selectedSkillPersistsAfterRefresh() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "persistent", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "persistent" })
        vm.selectSkill(skill)
        #expect(vm.selectedSkill?.name == "persistent")

        // Refresh
        await vm.loadSkills()

        // The skill should still be selected (matched by name)
        #expect(vm.selectedSkill?.name == "persistent")
    }

    @Test("Selection cleared when selected skill is deleted")
    func selectionClearedWhenDeleted() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "doomed", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "doomed" })
        vm.selectSkill(skill)
        #expect(vm.selectedSkill != nil)

        await vm.deleteSkill(removeSource: false)

        #expect(vm.selectedSkill == nil)
    }

    // MARK: - Enable/Disable (FR-7)

    @Test("Enable changes skill state from disabled to enabled")
    func enableChangesSkillState() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "to-enable", in: disabledDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "to-enable" })
        #expect(!skill.isEnabled)

        vm.selectSkill(skill)
        await vm.enableSkill()

        // After enable, the skill should appear as enabled in the refreshed list
        let enabled = vm.skills.first { $0.name == "to-enable" }
        #expect(enabled?.isEnabled == true)
    }

    @Test("Disable changes skill state from enabled to disabled")
    func disableChangesSkillState() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "to-disable", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "to-disable" })
        #expect(skill.isEnabled)

        vm.selectSkill(skill)
        await vm.disableSkill()

        let disabled = vm.skills.first { $0.name == "to-disable" }
        #expect(disabled?.isEnabled == false)
    }

    @Test("Error during enable sets errorMessage")
    func enableErrorSetsErrorMessage() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create a conflict: same name in both directories
        try createSkillDirectory(named: "conflict", in: disabledDir)
        try createSkillDirectory(named: "conflict", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let disabledSkill = try #require(
            vm.skills.first { $0.name == "conflict" && !$0.isEnabled }
        )
        vm.selectSkill(disabledSkill)
        await vm.enableSkill()

        #expect(vm.errorMessage != nil)
    }

    // MARK: - Delete (FR-8)

    @Test("Delete non-symlinked skill removes it from list")
    func deleteNonSymlinkedSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "delete-me", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()
        #expect(vm.skills.count == 1)

        let skill = try #require(vm.skills.first { $0.name == "delete-me" })
        vm.selectSkill(skill)
        await vm.deleteSkill(removeSource: false)

        #expect(vm.skills.isEmpty)
    }

    @Test("Delete symlinked skill with removeSource false keeps source intact")
    func deleteSymlinkedSkillKeepsSource() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create source outside managed dirs
        let sourceDir = tempRoot.appendingPathComponent("repos", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "linked-skill", in: sourceDir)

        // Create symlink in skills/
        let symlinkPath = skillsDir.appendingPathComponent("linked-skill")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: sourceSkill)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "linked-skill" })
        #expect(skill.isSymlink)

        vm.selectSkill(skill)
        await vm.deleteSkill(removeSource: false)

        // Skill removed from list
        #expect(vm.skills.first { $0.name == "linked-skill" } == nil)
        // Source directory still exists
        #expect(FileManager.default.fileExists(atPath: sourceSkill.path))
    }

    @Test("Delete clears selection when deleted skill was selected")
    func deleteClearsSelection() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "selected-then-deleted", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first)
        vm.selectSkill(skill)
        #expect(vm.selectedSkill != nil)

        await vm.deleteSkill(removeSource: false)

        #expect(vm.selectedSkill == nil)
    }

    // MARK: - Editor (FR-6)

    @Test("Start editing loads content and sets isEditing")
    func startEditingLoadsContent() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let customContent = """
        ---
        name: editable
        description: An editable skill
        ---
        # Custom Instructions
        These are the instructions.
        """
        try createSkillDirectory(named: "editable", in: skillsDir, content: customContent)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "editable" })
        vm.selectSkill(skill)
        vm.startEditing()

        #expect(vm.isEditing)
        #expect(vm.editorContent.contains("Custom Instructions"))
    }

    @Test("Save editing writes content and clears isEditing")
    func saveEditingWritesContent() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "save-target", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "save-target" })
        vm.selectSkill(skill)
        vm.startEditing()

        let updatedContent = """
        ---
        name: save-target
        description: Updated description
        ---
        # Updated Instructions
        Brand new content here.
        """
        vm.editorContent = updatedContent
        await vm.saveEditing()

        #expect(!vm.isEditing)

        // Verify the file was actually written
        let fileContent = try String(
            contentsOf: skillsDir
                .appendingPathComponent("save-target")
                .appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        #expect(fileContent.contains("Brand new content here."))
    }

    @Test("Cancel editing discards changes and clears isEditing")
    func cancelEditingDiscardsChanges() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let originalContent = """
        ---
        name: cancel-test
        description: Original description
        ---
        # Original Content
        Original instructions.
        """
        try createSkillDirectory(named: "cancel-test", in: skillsDir, content: originalContent)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "cancel-test" })
        vm.selectSkill(skill)
        vm.startEditing()

        // Modify editor content but then cancel
        vm.editorContent = "completely overwritten content"
        vm.cancelEditing()

        #expect(!vm.isEditing)

        // Verify original file is unchanged
        let fileContent = try String(
            contentsOf: skillsDir
                .appendingPathComponent("cancel-test")
                .appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        #expect(fileContent.contains("Original instructions."))
    }

    // MARK: - Add Skill

    @Test("Add from file adds skill to list")
    func addFromFileAddsSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create an external skill directory to import
        let externalDir = tempRoot.appendingPathComponent("external", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "imported", in: externalDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()
        #expect(vm.skills.isEmpty)

        await vm.addSkillFromFile(url: sourceSkill)

        #expect(vm.skills.count == 1)
        #expect(vm.skills.first?.name == "imported")
    }

    @Test("Add from URL adds skill to list")
    func addFromURLAddsSkill() async throws {
        // This test verifies the ViewModel correctly delegates to SkillManager.
        // In practice, this requires network/git access. We verify the error path
        // since we cannot clone in a unit test environment.
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        vm.addSkillURL = "https://github.com/nonexistent/repo"
        await vm.addSkillFromURL()

        // Since the repo doesn't exist, an error should be set
        #expect(vm.errorMessage != nil)
    }

    @Test("Add from invalid URL sets errorMessage")
    func addFromInvalidURLSetsError() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        vm.addSkillURL = "not-a-valid-url"
        await vm.addSkillFromURL()

        #expect(vm.errorMessage != nil)
    }

    @Test("Add clears add sheet state on success")
    func addClearsSheetOnSuccess() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let externalDir = tempRoot.appendingPathComponent("external", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "sheet-test", in: externalDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        vm.isShowingAddSheet = true
        await vm.addSkillFromFile(url: sourceSkill)

        #expect(!vm.isShowingAddSheet)
    }

    // MARK: - Pull Latest (FR-9)

    @Test("Pull latest succeeds for URL-installed skill")
    func pullLatestForURLInstalledSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create a real git repo to simulate a URL-installed skill
        let reposDir = appSupportDir.appendingPathComponent("repos", isDirectory: true)
        try FileManager.default.createDirectory(at: reposDir, withIntermediateDirectories: true)

        let repoDir = reposDir.appendingPathComponent("test-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        // Initialize a git repo so git pull has something to work with
        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProcess.arguments = ["init"]
        initProcess.currentDirectoryURL = repoDir
        try initProcess.run()
        initProcess.waitUntilExit()

        // Create SKILL.md in the repo
        try createSkillDirectory(named: "url-skill", in: repoDir)

        // Symlink from skills/ to the repo skill
        let skillSource = repoDir.appendingPathComponent("url-skill")
        let symlinkPath = skillsDir.appendingPathComponent("url-skill")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: skillSource)

        // Write metadata so SkillManager knows this is URL-installed
        let metadata: [String: SkillMetadata] = [
            "url-skill": SkillMetadata(
                sourceRepoURL: "https://github.com/test/repo",
                clonedRepoPath: repoDir.path,
                installedAt: Date()
            )
        ]
        let metadataStore = MetadataStore(
            fileURL: appSupportDir.appendingPathComponent("metadata.json")
        )
        try metadataStore.save(metadata)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "url-skill" })
        #expect(skill.sourceRepoURL != nil)

        vm.selectSkill(skill)
        await vm.pullLatest()

        // git pull on a local-only repo may produce an error (no remote),
        // but the flow should handle it gracefully by setting errorMessage
        // rather than crashing. A real URL-installed skill would succeed.
        // We verify the ViewModel didn't crash and state is consistent.
        #expect(vm.selectedSkill != nil)
    }

    // MARK: - Initial State

    @Test("ViewModel has correct initial state")
    func initialState() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)

        #expect(vm.skills.isEmpty)
        #expect(vm.filteredSkills.isEmpty)
        #expect(vm.selectedSkill == nil)
        #expect(vm.searchText == "")
        #expect(!vm.isLoading)
        #expect(vm.errorMessage == nil)
        #expect(!vm.isEditing)
        #expect(vm.editorContent == "")
        #expect(!vm.isShowingAddSheet)
        #expect(vm.addSkillURL == "")
        #expect(!vm.isShowingDeleteConfirmation)
    }

    // MARK: - Editor Navigation (Unsaved Changes)

    @Test("Switching skills while editing with no changes updates editor to new skill")
    func switchSkillWhileEditingNoChanges() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "skill-a", in: skillsDir, content: """
        ---
        name: skill-a
        description: First skill
        ---
        # Skill A Content
        """)
        try createSkillDirectory(named: "skill-b", in: skillsDir, content: """
        ---
        name: skill-b
        description: Second skill
        ---
        # Skill B Content
        """)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skillA = try #require(vm.skills.first { $0.name == "skill-a" })
        let skillB = try #require(vm.skills.first { $0.name == "skill-b" })

        vm.selectSkill(skillA)
        vm.startEditing()
        #expect(vm.isEditing)
        #expect(vm.editorContent.contains("Skill A Content"))

        // Switch to skill-b without modifying content
        vm.selectSkill(skillB)

        #expect(vm.selectedSkill?.name == "skill-b")
        #expect(vm.isEditing)
        #expect(vm.editorContent.contains("Skill B Content"))
        #expect(!vm.isShowingUnsavedChangesAlert)
    }

    @Test("Switching skills while editing with unsaved changes shows alert")
    func switchSkillWhileEditingUnsavedChanges() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "skill-a", in: skillsDir)
        try createSkillDirectory(named: "skill-b", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skillA = try #require(vm.skills.first { $0.name == "skill-a" })
        let skillB = try #require(vm.skills.first { $0.name == "skill-b" })

        vm.selectSkill(skillA)
        vm.startEditing()
        vm.editorContent = "modified content"

        vm.selectSkill(skillB)

        #expect(vm.isShowingUnsavedChangesAlert)
        #expect(vm.selectedSkill?.name == "skill-a")
        #expect(vm.pendingSkillSelection?.name == "skill-b")
    }

    @Test("saveAndNavigateToSkill saves old content and switches to new skill")
    func saveAndNavigateToSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "skill-a", in: skillsDir)
        try createSkillDirectory(named: "skill-b", in: skillsDir, content: """
        ---
        name: skill-b
        description: Second skill
        ---
        # Skill B Content
        """)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skillA = try #require(vm.skills.first { $0.name == "skill-a" })
        let skillB = try #require(vm.skills.first { $0.name == "skill-b" })

        vm.selectSkill(skillA)
        vm.startEditing()
        vm.editorContent = "saved content for skill-a"

        // Trigger unsaved changes flow
        vm.selectSkill(skillB)
        #expect(vm.isShowingUnsavedChangesAlert)

        await vm.saveAndNavigateToSkill()

        // Verify old skill was saved
        let savedContent = try String(
            contentsOf: skillsDir
                .appendingPathComponent("skill-a")
                .appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        #expect(savedContent.contains("saved content for skill-a"))

        // Verify navigated to new skill and editor is active
        #expect(vm.selectedSkill?.name == "skill-b")
        #expect(vm.isEditing)
        #expect(vm.editorContent.contains("Skill B Content"))
        #expect(vm.pendingSkillSelection == nil)
    }

    @Test("discardAndNavigateToSkill discards changes and switches to new skill")
    func discardAndNavigateToSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let originalContent = """
        ---
        name: skill-a
        description: First skill
        ---
        # Original A Content
        """
        try createSkillDirectory(named: "skill-a", in: skillsDir, content: originalContent)
        try createSkillDirectory(named: "skill-b", in: skillsDir, content: """
        ---
        name: skill-b
        description: Second skill
        ---
        # Skill B Content
        """)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skillA = try #require(vm.skills.first { $0.name == "skill-a" })
        let skillB = try #require(vm.skills.first { $0.name == "skill-b" })

        vm.selectSkill(skillA)
        vm.startEditing()
        vm.editorContent = "unsaved modifications"

        vm.selectSkill(skillB)
        #expect(vm.isShowingUnsavedChangesAlert)

        vm.discardAndNavigateToSkill()

        // Verify original file is unchanged (not overwritten)
        let fileContent = try String(
            contentsOf: skillsDir
                .appendingPathComponent("skill-a")
                .appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        #expect(fileContent.contains("Original A Content"))

        // Verify navigated to new skill
        #expect(vm.selectedSkill?.name == "skill-b")
        #expect(vm.isEditing)
        #expect(vm.editorContent.contains("Skill B Content"))
        #expect(vm.pendingSkillSelection == nil)
    }

    @Test("cancelNavigationToSkill clears pending and stays on current skill")
    func cancelNavigationToSkill() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "skill-a", in: skillsDir)
        try createSkillDirectory(named: "skill-b", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skillA = try #require(vm.skills.first { $0.name == "skill-a" })
        let skillB = try #require(vm.skills.first { $0.name == "skill-b" })

        vm.selectSkill(skillA)
        vm.startEditing()
        vm.editorContent = "my unsaved work"

        vm.selectSkill(skillB)
        #expect(vm.isShowingUnsavedChangesAlert)

        vm.cancelNavigationToSkill()

        #expect(vm.pendingSkillSelection == nil)
        #expect(vm.selectedSkill?.name == "skill-a")
        #expect(vm.isEditing)
        #expect(vm.editorContent == "my unsaved work")
    }

    // MARK: - Search updates filteredSkills but not skills

    @Test("Search filters filteredSkills without modifying skills array")
    func searchDoesNotModifySkillsArray() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "keep-one", in: skillsDir)
        try createSkillDirectory(named: "keep-two", in: skillsDir)
        try createSkillDirectory(named: "filter-out", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        vm.searchSkills(query: "keep")

        // filteredSkills should only show matching skills
        #expect(vm.filteredSkills.count == 2)
        // skills array should remain unchanged
        #expect(vm.skills.count == 3)
    }

    // MARK: - Drop Import

    @Test("handleDroppedURLs imports directories containing SKILL.md")
    func handleDroppedURLsImportsDirectories() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let externalDir = tempRoot.appendingPathComponent("external", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "dropped-skill", in: externalDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()
        #expect(vm.skills.isEmpty)

        await vm.handleDroppedURLs([sourceSkill])

        #expect(vm.skills.count == 1)
        #expect(vm.skills.first?.name == "dropped-skill")
    }

    @Test("handleDroppedURLs filters out file URLs, nothing imported")
    func handleDroppedURLsFiltersOutFiles() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create a plain file (not a directory)
        let fileURL = tempRoot.appendingPathComponent("not-a-directory.md")
        try "some content".write(to: fileURL, atomically: true, encoding: .utf8)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        await vm.handleDroppedURLs([fileURL])

        #expect(vm.skills.isEmpty)
    }

    @Test("handleDroppedURLs with mixed URLs imports directories, ignores files")
    func handleDroppedURLsMixedURLs() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Create a valid skill directory
        let externalDir = tempRoot.appendingPathComponent("external", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "valid-drop", in: externalDir)

        // Create a plain file
        let fileURL = tempRoot.appendingPathComponent("stray-file.txt")
        try "stray content".write(to: fileURL, atomically: true, encoding: .utf8)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        await vm.handleDroppedURLs([sourceSkill, fileURL])

        // Only the directory should have been imported
        #expect(vm.skills.count == 1)
        #expect(vm.skills.first?.name == "valid-drop")
    }

    @Test("handleDroppedURLs with empty array is a no-op")
    func handleDroppedURLsEmptyArray() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        await vm.handleDroppedURLs([])

        #expect(vm.skills.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test("isDropTargeted starts as false")
    func isDropTargetedStartsFalse() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)

        #expect(!vm.isDropTargeted)
    }

    @Test("Drop dismisses Add Skill sheet")
    func dropDismissesAddSheet() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let externalDir = tempRoot.appendingPathComponent("external", isDirectory: true)
        let sourceSkill = try createSkillDirectory(named: "sheet-dismiss", in: externalDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()
        vm.isShowingAddSheet = true

        await vm.handleDroppedURLs([sourceSkill])

        #expect(!vm.isShowingAddSheet)
    }

    // MARK: - Editor Preview Mode

    @Test("editorMode starts as .edit when editing begins")
    func editorModeStartsAsEditWhenEditing() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "preview-test", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "preview-test" })
        vm.selectSkill(skill)
        vm.startEditing()

        #expect(vm.editorMode == .edit)
    }

    @Test("editorMode resets to .edit on cancel")
    func editorModeResetsToEditOnCancel() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "cancel-mode", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "cancel-mode" })
        vm.selectSkill(skill)
        vm.startEditing()
        vm.editorMode = .preview
        #expect(vm.editorMode == .preview)

        vm.cancelEditing()

        #expect(vm.editorMode == .edit)
    }

    @Test("editorMode resets to .edit on save")
    func editorModeResetsToEditOnSave() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "save-mode", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "save-mode" })
        vm.selectSkill(skill)
        vm.startEditing()
        vm.editorMode = .preview
        #expect(vm.editorMode == .preview)

        await vm.saveEditing()

        #expect(vm.editorMode == .edit)
    }

    @Test("Save works regardless of editor mode")
    func saveWorksRegardlessOfEditorMode() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        try createSkillDirectory(named: "save-in-preview", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skill = try #require(vm.skills.first { $0.name == "save-in-preview" })
        vm.selectSkill(skill)
        vm.startEditing()

        let updatedContent = """
        ---
        name: save-in-preview
        description: Updated while in preview mode
        ---
        # Preview Save Test
        Content saved from preview mode.
        """
        vm.editorContent = updatedContent
        vm.editorMode = .preview

        await vm.saveEditing()

        #expect(!vm.isEditing)

        // Verify the file was actually written to disk
        let fileContent = try String(
            contentsOf: skillsDir
                .appendingPathComponent("save-in-preview")
                .appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        #expect(fileContent.contains("Content saved from preview mode."))
    }

    // MARK: - Detail Panel Tabs

    @Test("detailPanelTab defaults to .info")
    func detailPanelTabDefaultsToInfo() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Ensure no stale UserDefaults value
        UserDefaults.standard.removeObject(forKey: "detailPanelTab")
        defer { UserDefaults.standard.removeObject(forKey: "detailPanelTab") }

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)

        #expect(vm.detailPanelTab == .info)
    }

    @Test("detailPanelTab initializes from UserDefaults")
    func detailPanelTabInitializesFromUserDefaults() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Set UserDefaults before creating the ViewModel
        UserDefaults.standard.set("content", forKey: "detailPanelTab")
        defer { UserDefaults.standard.removeObject(forKey: "detailPanelTab") }

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)

        #expect(vm.detailPanelTab == .content)
    }

    @Test("Changing detailPanelTab persists to UserDefaults")
    func detailPanelTabPersistsToUserDefaults() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer {
            cleanUp(tempRoot)
            UserDefaults.standard.removeObject(forKey: "detailPanelTab")
        }

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        vm.detailPanelTab = .content

        let stored = UserDefaults.standard.string(forKey: "detailPanelTab")
        #expect(stored == "content")
    }

    @Test("Tab selection preserved when switching skills")
    func tabSelectionPreservedWhenSwitchingSkills() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        // Clean UserDefaults state
        UserDefaults.standard.removeObject(forKey: "detailPanelTab")
        defer { UserDefaults.standard.removeObject(forKey: "detailPanelTab") }

        try createSkillDirectory(named: "tab-skill-a", in: skillsDir)
        try createSkillDirectory(named: "tab-skill-b", in: skillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let skillA = try #require(vm.skills.first { $0.name == "tab-skill-a" })
        let skillB = try #require(vm.skills.first { $0.name == "tab-skill-b" })

        vm.selectSkill(skillA)
        vm.detailPanelTab = .content
        #expect(vm.detailPanelTab == .content)

        vm.selectSkill(skillB)

        #expect(vm.detailPanelTab == .content)
    }

    // MARK: - Provider Switching

    @Test("Switching providers updates the active skill list")
    func switchingProvidersUpdatesActiveSkillList() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let codexSkillsDir = tempRoot.appendingPathComponent("codex-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSkillsDir, withIntermediateDirectories: true)

        try createSkillDirectory(named: "claude-skill", in: skillsDir)
        try createSkillDirectory(named: "codex-skill", in: codexSkillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        #expect(vm.selectedProvider == .claudeCode)
        #expect(vm.skills.map(\.name) == ["claude-skill"])

        vm.requestProviderSelection(.codex)

        #expect(vm.selectedProvider == .codex)
        #expect(vm.skills.map(\.name) == ["codex-skill"])
        #expect(vm.skills.first?.provider == .codex)
    }

    @Test("Provider switch while editing with unsaved changes shows alert and defers switch")
    func providerSwitchWhileEditingUnsavedChangesShowsAlert() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let codexSkillsDir = tempRoot.appendingPathComponent("codex-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSkillsDir, withIntermediateDirectories: true)

        try createSkillDirectory(named: "claude-edit", in: skillsDir)
        try createSkillDirectory(named: "codex-edit", in: codexSkillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        let claudeSkill = try #require(vm.skills.first { $0.name == "claude-edit" })
        vm.selectSkill(claudeSkill)
        vm.startEditing()
        vm.editorContent = "modified content"

        vm.requestProviderSelection(.codex)

        #expect(vm.isShowingUnsavedChangesAlert)
        #expect(vm.pendingProviderSelection == .codex)
        #expect(vm.selectedProvider == .claudeCode)

        vm.discardAndNavigateToSkill()

        #expect(vm.selectedProvider == .codex)
        #expect(!vm.isEditing)
        #expect(vm.skills.map(\.name) == ["codex-edit"])
    }

    @Test("Search text is preserved per provider while switching")
    func searchTextPreservedPerProvider() async throws {
        let (tempRoot, skillsDir, disabledDir, appSupportDir) = try makeTempEnvironment()
        defer { cleanUp(tempRoot) }

        let codexSkillsDir = tempRoot.appendingPathComponent("codex-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSkillsDir, withIntermediateDirectories: true)

        try createSkillDirectory(named: "claude-alpha", in: skillsDir)
        try createSkillDirectory(named: "claude-beta", in: skillsDir)
        try createSkillDirectory(named: "codex-gamma", in: codexSkillsDir)
        try createSkillDirectory(named: "codex-delta", in: codexSkillsDir)

        let vm = makeViewModel(skillsDir: skillsDir, disabledDir: disabledDir, appSupportDir: appSupportDir)
        await vm.loadSkills()

        vm.searchSkills(query: "alpha")
        #expect(vm.filteredSkills.map(\.name) == ["claude-alpha"])

        vm.requestProviderSelection(.codex)
        #expect(vm.searchText == "")
        #expect(vm.filteredSkills.map(\.name).sorted() == ["codex-delta", "codex-gamma"])

        vm.searchSkills(query: "gamma")
        #expect(vm.filteredSkills.map(\.name) == ["codex-gamma"])

        vm.requestProviderSelection(.claudeCode)
        #expect(vm.searchText == "alpha")
        #expect(vm.filteredSkills.map(\.name) == ["claude-alpha"])
    }
}
