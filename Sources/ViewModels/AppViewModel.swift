import Foundation
import Observation

enum EditorMode: Sendable {
    case edit, preview
}

enum DetailTab: String, Sendable {
    case info, content
}

@MainActor
@Observable
final class AppViewModel {

    private static let detailPanelTabDefaultsKey = "detailPanelTab"
    private static let selectedProviderDefaultsKey = "selectedSkillProvider"

    // MARK: - Published State

    var selectedProvider: SkillProvider = .claudeCode {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: Self.selectedProviderDefaultsKey)
        }
    }
    var skills: [Skill] = []
    var filteredSkills: [Skill] = []
    var selectedSkill: Skill? {
        didSet {
            selectedSkillPathByProvider[selectedProvider] = selectedSkill?.directoryURL.path
        }
    }
    var searchText: String = "" {
        didSet {
            searchTextByProvider[selectedProvider] = searchText
        }
    }
    var isLoading: Bool = false
    var errorMessage: String?

    // Editor state
    var isEditing: Bool = false
    var editorContent: String = ""
    var editorOriginalContent: String = ""
    var editorFileModificationDate: Date?
    var isShowingExternalModificationWarning: Bool = false
    var isShowingUnsavedChangesAlert: Bool = false
    var pendingSkillSelection: Skill?
    var pendingProviderSelection: SkillProvider?

    // Editor mode & detail tab
    var editorMode: EditorMode = .edit
    var detailPanelTab: DetailTab = .info {
        didSet {
            UserDefaults.standard.set(detailPanelTab.rawValue, forKey: Self.detailPanelTabDefaultsKey)
        }
    }

    // Add skill state
    var isShowingAddSheet: Bool = false
    var addSkillURL: String = ""

    // Duplicate confirmation state
    var isShowingDuplicateConfirmation: Bool = false
    var duplicateSkillNames: [String] = []
    private var pendingFileImportURLs: [URL] = []
    private var pendingStagedURLInstall: StagedURLInstall?

    // Drop import state
    var isDropTargeted: Bool = false

    // Delete state
    var isShowingDeleteConfirmation: Bool = false

    // Pull state
    var isPulling: Bool = false

    // Export state
    var isExporting: Bool = false

    // MARK: - Private

    private let claudeSkillManager: SkillManager
    private let codexSkillManager: SkillManager
    private var skillsByProvider: [SkillProvider: [Skill]] = [:]
    private var selectedSkillPathByProvider: [SkillProvider: String] = [:]
    private var searchTextByProvider: [SkillProvider: String] = [:]

    // MARK: - Init

    init(claudeSkillManager: SkillManager, codexSkillManager: SkillManager) {
        self.claudeSkillManager = claudeSkillManager
        self.codexSkillManager = codexSkillManager

        let savedProvider = UserDefaults.standard.string(forKey: Self.selectedProviderDefaultsKey)
        self.selectedProvider = SkillProvider(rawValue: savedProvider ?? "") ?? .claudeCode

        let savedTab = UserDefaults.standard.string(forKey: Self.detailPanelTabDefaultsKey)
        self.detailPanelTab = DetailTab(rawValue: savedTab ?? "") ?? .info

        self.skillsByProvider = Dictionary(uniqueKeysWithValues: SkillProvider.allCases.map { ($0, []) })
        self.searchTextByProvider = Dictionary(uniqueKeysWithValues: SkillProvider.allCases.map { ($0, "") })
        restoreState(for: selectedProvider)
    }

    // MARK: - Load Skills

    func loadSkills() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        await loadSkills(for: .claudeCode)
        await loadSkills(for: .codex)
        restoreState(for: selectedProvider)
    }

    private func loadSkills(for provider: SkillProvider) async {
        do {
            try await refreshProvider(provider)
        } catch {
            skillsByProvider[provider] = []
            selectedSkillPathByProvider[provider] = nil

            if provider == selectedProvider {
                restoreState(for: provider)
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Selection

    func selectSkill(_ skill: Skill) {
        if isEditing {
            if editorContent != editorOriginalContent {
                pendingSkillSelection = skill
                pendingProviderSelection = nil
                isShowingUnsavedChangesAlert = true
            } else {
                selectedSkill = skill
                startEditing()
            }
        } else {
            selectedSkill = skill
        }
    }

    func requestProviderSelection(_ provider: SkillProvider) {
        guard provider != selectedProvider else { return }

        if isEditing {
            if editorContent != editorOriginalContent {
                pendingProviderSelection = provider
                pendingSkillSelection = nil
                isShowingUnsavedChangesAlert = true
            } else {
                cancelEditing()
                switchProvider(to: provider)
            }
        } else {
            switchProvider(to: provider)
        }
    }

    // MARK: - Search

    func searchSkills(query: String) {
        searchText = query
        applyFilter()
    }

    private func applyFilter() {
        if searchText.isEmpty {
            filteredSkills = skills
        } else {
            let lowered = searchText.lowercased()
            filteredSkills = skills.filter { skill in
                skill.name.lowercased().contains(lowered) ||
                skill.description.lowercased().contains(lowered)
            }
        }
    }

    // MARK: - Add Skill from File (FR-4)

    func addSkillFromFile(url: URL) async {
        await addSkillsFromFiles(urls: [url])
    }

    func addSkillsFromFiles(urls: [URL]) async {
        let duplicates = activeSkillManager.findDuplicateNames(for: urls)
        if duplicates.isEmpty {
            await performFileImport(urls: urls)
        } else {
            pendingFileImportURLs = urls
            duplicateSkillNames = duplicates
            isShowingDuplicateConfirmation = true
        }
    }

    private func performFileImport(urls: [URL]) async {
        var errors: [String] = []
        for url in urls {
            do {
                try await activeSkillManager.addSkillFromFile(sourceURL: url)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        do {
            try await refreshProvider(selectedProvider)
        } catch {
            errors.append(error.localizedDescription)
        }

        if errors.isEmpty {
            isShowingAddSheet = false
        } else {
            errorMessage = errors.joined(separator: "\n")
        }
    }

    // MARK: - Add Skill from URL (FR-5)

    func addSkillFromURL() async {
        do {
            let staged = try await activeSkillManager.stageSkillFromURL(repoURL: addSkillURL)
            let duplicates = activeSkillManager.findDuplicateSkillNames(staged.skillNames)
            if duplicates.isEmpty {
                try await activeSkillManager.commitStagedURLInstall(staged)
                try await refreshProvider(selectedProvider)
                isShowingAddSheet = false
                addSkillURL = ""
            } else {
                pendingStagedURLInstall = staged
                duplicateSkillNames = duplicates
                isShowingDuplicateConfirmation = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Duplicate Confirmation

    func confirmOverwriteDuplicates() async {
        if !pendingFileImportURLs.isEmpty {
            let urls = pendingFileImportURLs
            pendingFileImportURLs = []
            duplicateSkillNames = []
            await performFileImport(urls: urls)
        } else if let staged = pendingStagedURLInstall {
            pendingStagedURLInstall = nil
            duplicateSkillNames = []
            do {
                try await activeSkillManager.commitStagedURLInstall(staged)
                try await refreshProvider(selectedProvider)
                isShowingAddSheet = false
                addSkillURL = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelOverwriteDuplicates() {
        if let staged = pendingStagedURLInstall {
            activeSkillManager.cancelStagedURLInstall(staged)
            pendingStagedURLInstall = nil
        }
        pendingFileImportURLs = []
        duplicateSkillNames = []
    }

    // MARK: - Drop Import

    func handleDroppedURLs(_ urls: [URL]) async {
        isShowingAddSheet = false
        let directoryURLs = urls.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        guard !directoryURLs.isEmpty else { return }
        await addSkillsFromFiles(urls: directoryURLs)
    }

    // MARK: - Enable / Disable (FR-7)

    func enableSkill() async {
        guard let skill = selectedSkill else { return }
        let directoryName = skill.directoryURL.lastPathComponent
        do {
            try await activeSkillManager.enableSkill(skill)
            try await refreshProvider(selectedProvider)
            selectedSkill = skills.first { $0.directoryURL.lastPathComponent == directoryName }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disableSkill() async {
        guard let skill = selectedSkill else { return }
        let directoryName = skill.directoryURL.lastPathComponent
        do {
            try await activeSkillManager.disableSkill(skill)
            try await refreshProvider(selectedProvider)
            selectedSkill = skills.first { $0.directoryURL.lastPathComponent == directoryName }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Delete (FR-8)

    func deleteSkill(removeSource: Bool) async {
        guard let skill = selectedSkill else { return }
        do {
            try await activeSkillManager.deleteSkill(skill, removeSource: removeSource)
            selectedSkillPathByProvider[selectedProvider] = nil
            selectedSkill = nil
            try await refreshProvider(selectedProvider)
            isShowingDeleteConfirmation = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pull Latest (FR-9)

    func pullLatest() async {
        guard let skill = selectedSkill else { return }
        isPulling = true
        defer { isPulling = false }
        do {
            _ = try await activeSkillManager.pullLatest(for: skill)
            try await refreshProvider(selectedProvider)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export

    func exportSkill(to url: URL) async {
        guard let skill = selectedSkill else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            try activeSkillManager.exportSkill(skill, to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Editor (FR-6)

    func startEditing() {
        editorMode = .edit
        guard let skill = selectedSkill else { return }
        do {
            let content = try activeSkillManager.readSkillContent(skill)
            editorContent = content
            editorOriginalContent = content
            let filePath = skill.directoryURL.appendingPathComponent("SKILL.md").path
            let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
            editorFileModificationDate = attrs[.modificationDate] as? Date
            isEditing = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveEditing() async {
        guard let skill = selectedSkill else { return }
        do {
            // Check for external modification
            let filePath = skill.directoryURL.appendingPathComponent("SKILL.md").path
            let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
            let currentDate = attrs[.modificationDate] as? Date
            if let stored = editorFileModificationDate, let current = currentDate, stored != current {
                isShowingExternalModificationWarning = true
                return
            }
            try activeSkillManager.saveSkillContent(skill, content: editorContent)
            editorMode = .edit
            isEditing = false
            editorFileModificationDate = nil
            try await refreshProvider(selectedProvider)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forceSaveEditing() async {
        guard let skill = selectedSkill else { return }
        do {
            try activeSkillManager.saveSkillContent(skill, content: editorContent)
            editorMode = .edit
            isEditing = false
            editorFileModificationDate = nil
            isShowingExternalModificationWarning = false
            try await refreshProvider(selectedProvider)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelEditing() {
        editorMode = .edit
        isEditing = false
        editorContent = ""
        editorOriginalContent = ""
        editorFileModificationDate = nil
    }

    // MARK: - Unsaved Changes Navigation

    func saveAndNavigateToSkill() async {
        let pendingSkillPath = pendingSkillSelection?.directoryURL.path
        let pendingProvider = pendingProviderSelection
        await saveEditing()
        guard !isEditing else { return }

        pendingSkillSelection = nil
        pendingProviderSelection = nil

        if let pendingProvider {
            switchProvider(to: pendingProvider)
        } else if let pendingSkillPath {
            selectSkillForCurrentProvider(at: pendingSkillPath, restartEditing: true)
        }
    }

    func discardAndNavigateToSkill() {
        let pendingSkillPath = pendingSkillSelection?.directoryURL.path
        let pendingProvider = pendingProviderSelection
        cancelEditing()
        pendingSkillSelection = nil
        pendingProviderSelection = nil

        if let pendingProvider {
            switchProvider(to: pendingProvider)
        } else if let pendingSkillPath {
            selectSkillForCurrentProvider(at: pendingSkillPath, restartEditing: true)
        }
    }

    func cancelNavigationToSkill() {
        pendingSkillSelection = nil
        pendingProviderSelection = nil
    }

    // MARK: - View Helpers

    var providerSearchPrompt: String {
        selectedProvider.searchPrompt
    }

    var addSkillTitle: String {
        selectedProvider.addSkillTitle
    }

    var addSkillHelp: String {
        selectedProvider.addSkillHelp
    }

    var providerDisplayName: String {
        selectedProvider.displayName
    }

    // MARK: - Private Helpers

    private var activeSkillManager: SkillManager {
        manager(for: selectedProvider)
    }

    private func manager(for provider: SkillProvider) -> SkillManager {
        switch provider {
        case .claudeCode:
            return claudeSkillManager
        case .codex:
            return codexSkillManager
        }
    }

    private func refreshProvider(_ provider: SkillProvider) async throws {
        try await manager(for: provider).loadSkills()
        syncProviderState(for: provider)
    }

    private func syncProviderState(for provider: SkillProvider) {
        let loadedSkills = manager(for: provider).skills
        skillsByProvider[provider] = loadedSkills

        if let selectedPath = selectedSkillPathByProvider[provider],
           !loadedSkills.contains(where: { $0.directoryURL.path == selectedPath }) {
            selectedSkillPathByProvider[provider] = nil
        }

        if provider == selectedProvider {
            restoreState(for: provider)
        }
    }

    private func restoreState(for provider: SkillProvider) {
        skills = skillsByProvider[provider, default: []]
        searchText = searchTextByProvider[provider, default: ""]
        selectedSkill = selectedSkillFor(provider: provider, within: skills)
        applyFilter()
    }

    private func switchProvider(to provider: SkillProvider) {
        persistActiveState()
        selectedProvider = provider
        restoreState(for: provider)
    }

    private func persistActiveState() {
        skillsByProvider[selectedProvider] = skills
        searchTextByProvider[selectedProvider] = searchText
        selectedSkillPathByProvider[selectedProvider] = selectedSkill?.directoryURL.path
    }

    private func selectedSkillFor(provider: SkillProvider, within skills: [Skill]) -> Skill? {
        guard let selectedPath = selectedSkillPathByProvider[provider] else {
            return nil
        }

        return skills.first { $0.directoryURL.path == selectedPath }
    }

    private func selectSkillForCurrentProvider(at path: String, restartEditing: Bool) {
        guard let skill = skills.first(where: { $0.directoryURL.path == path }) else { return }
        selectedSkill = skill
        if restartEditing {
            startEditing()
        }
    }
}
