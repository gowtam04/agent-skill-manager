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
    var selectedSkillIDs: Set<Skill.ID> = [] {
        didSet {
            let paths = Set(
                skills
                    .filter { selectedSkillIDs.contains($0.id) }
                    .map { $0.directoryURL.path }
            )
            selectedSkillPathsByProvider[selectedProvider] = paths
        }
    }
    var selectedSkill: Skill? {
        guard selectedSkillIDs.count == 1, let id = selectedSkillIDs.first else {
            return nil
        }
        return skills.first { $0.id == id }
    }
    var selectedSkills: [Skill] {
        skills.filter { selectedSkillIDs.contains($0.id) }
    }
    var selectedMutableSkills: [Skill] {
        selectedSkills.filter { !$0.isReadOnly }
    }
    var selectionContainsSymlinks: Bool {
        selectedMutableSkills.contains(where: { $0.isSymlink })
    }
    var selectionContainsReadOnlySkills: Bool {
        selectedSkills.contains(where: { $0.isReadOnly })
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
    var pendingSelectionPaths: Set<String>?
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
    private let grokSkillManager: SkillManager
    private let sharedSkillManager: SkillManager
    private var skillsByProvider: [SkillProvider: [Skill]] = [:]
    private var selectedSkillPathsByProvider: [SkillProvider: Set<String>] = [:]
    private var searchTextByProvider: [SkillProvider: String] = [:]

    // MARK: - Init

    init(
        claudeSkillManager: SkillManager,
        codexSkillManager: SkillManager,
        grokSkillManager: SkillManager,
        sharedSkillManager: SkillManager
    ) {
        self.claudeSkillManager = claudeSkillManager
        self.codexSkillManager = codexSkillManager
        self.grokSkillManager = grokSkillManager
        self.sharedSkillManager = sharedSkillManager

        let savedProvider = UserDefaults.standard.string(forKey: Self.selectedProviderDefaultsKey)
        self.selectedProvider = SkillProvider(rawValue: savedProvider ?? "") ?? .claudeCode

        let savedTab = UserDefaults.standard.string(forKey: Self.detailPanelTabDefaultsKey)
        self.detailPanelTab = DetailTab(rawValue: savedTab ?? "") ?? .info

        self.skillsByProvider = Dictionary(uniqueKeysWithValues: SkillProvider.allCases.map { ($0, []) })
        self.selectedSkillPathsByProvider = Dictionary(uniqueKeysWithValues: SkillProvider.allCases.map { ($0, Set<String>()) })
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
        await loadSkills(for: .grok)
        await loadSkills(for: .shared)
        restoreState(for: selectedProvider)
    }

    private func loadSkills(for provider: SkillProvider) async {
        do {
            try await refreshProvider(provider)
        } catch {
            skillsByProvider[provider] = []
            selectedSkillPathsByProvider[provider] = []

            if provider == selectedProvider {
                restoreState(for: provider)
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Selection

    func selectSkill(_ skill: Skill) {
        setSelection(ids: [skill.id])
    }

    func setSelection(ids: Set<Skill.ID>) {
        let matchedSkill = ids.count == 1
            ? ids.first.flatMap { id in skills.first { $0.id == id } }
            : nil
        let isDirty = isEditing && editorContent != editorOriginalContent

        if isDirty {
            pendingProviderSelection = nil
            if let matchedSkill {
                pendingSkillSelection = matchedSkill
                pendingSelectionPaths = nil
            } else {
                pendingSkillSelection = nil
                pendingSelectionPaths = Set(
                    skills.filter { ids.contains($0.id) }.map { $0.directoryURL.path }
                )
            }
            isShowingUnsavedChangesAlert = true
            return
        }

        if isEditing, let matchedSkill {
            selectedSkillIDs = [matchedSkill.id]
            startEditing()
        } else if isEditing {
            cancelEditing()
            selectedSkillIDs = ids
        } else {
            selectedSkillIDs = ids
        }
    }

    func requestProviderSelection(_ provider: SkillProvider) {
        guard provider != selectedProvider else { return }

        if isEditing {
            if editorContent != editorOriginalContent {
                pendingProviderSelection = provider
                pendingSkillSelection = nil
                pendingSelectionPaths = nil
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
        guard !skill.isReadOnly else {
            errorMessage = SkillManagerError.readOnlySkill.localizedDescription
            return
        }

        let directoryName = skill.directoryURL.lastPathComponent
        do {
            try await activeSkillManager.enableSkill(skill)
            try await refreshProvider(selectedProvider)
            if let refreshed = skills.first(where: { $0.directoryURL.lastPathComponent == directoryName }) {
                selectedSkillIDs = [refreshed.id]
            } else {
                selectedSkillIDs = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disableSkill() async {
        guard let skill = selectedSkill else { return }
        guard !skill.isReadOnly else {
            errorMessage = SkillManagerError.readOnlySkill.localizedDescription
            return
        }

        let directoryName = skill.directoryURL.lastPathComponent
        do {
            try await activeSkillManager.disableSkill(skill)
            try await refreshProvider(selectedProvider)
            if let refreshed = skills.first(where: { $0.directoryURL.lastPathComponent == directoryName }) {
                selectedSkillIDs = [refreshed.id]
            } else {
                selectedSkillIDs = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func enableSelectedSkills() async {
        let targets = selectedSkills.filter { !$0.isEnabled && !$0.isReadOnly }
        guard !targets.isEmpty else { return }
        let trackedDirectoryNames = Set(selectedSkills.map { $0.directoryURL.lastPathComponent })
        var errors: [String] = []
        for skill in targets {
            do {
                try await activeSkillManager.enableSkill(skill)
            } catch {
                errors.append("\(skill.name): \(error.localizedDescription)")
            }
        }
        do {
            try await refreshProvider(selectedProvider)
        } catch {
            errors.append(error.localizedDescription)
        }
        selectedSkillIDs = Set(
            skills
                .filter { trackedDirectoryNames.contains($0.directoryURL.lastPathComponent) }
                .map { $0.id }
        )
        if !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
        }
    }

    func disableSelectedSkills() async {
        let targets = selectedSkills.filter { $0.isEnabled && !$0.isReadOnly }
        guard !targets.isEmpty else { return }
        let trackedDirectoryNames = Set(selectedSkills.map { $0.directoryURL.lastPathComponent })
        var errors: [String] = []
        for skill in targets {
            do {
                try await activeSkillManager.disableSkill(skill)
            } catch {
                errors.append("\(skill.name): \(error.localizedDescription)")
            }
        }
        do {
            try await refreshProvider(selectedProvider)
        } catch {
            errors.append(error.localizedDescription)
        }
        selectedSkillIDs = Set(
            skills
                .filter { trackedDirectoryNames.contains($0.directoryURL.lastPathComponent) }
                .map { $0.id }
        )
        if !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
        }
    }

    // MARK: - Delete (FR-8)

    func deleteSkill(removeSource: Bool) async {
        guard let skill = selectedSkill else { return }
        guard !skill.isReadOnly else {
            errorMessage = SkillManagerError.readOnlySkill.localizedDescription
            isShowingDeleteConfirmation = false
            return
        }

        do {
            try await activeSkillManager.deleteSkill(skill, removeSource: removeSource)
            selectedSkillIDs = []
            try await refreshProvider(selectedProvider)
            isShowingDeleteConfirmation = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteCurrentSelection(removeSource: Bool) async {
        if selectedSkillIDs.count > 1 {
            await deleteSelectedSkills(removeSource: removeSource)
        } else {
            await deleteSkill(removeSource: removeSource)
        }
    }

    func deleteSelectedSkills(removeSource: Bool) async {
        let targets = selectedMutableSkills
        guard !targets.isEmpty else {
            isShowingDeleteConfirmation = false
            return
        }

        let remainingReadOnlyPaths = Set(selectedSkills.filter(\.isReadOnly).map { $0.directoryURL.path })
        var errors: [String] = []
        for skill in targets {
            do {
                try await activeSkillManager.deleteSkill(skill, removeSource: removeSource)
            } catch {
                errors.append("\(skill.name): \(error.localizedDescription)")
            }
        }
        isShowingDeleteConfirmation = false
        do {
            try await refreshProvider(selectedProvider)
        } catch {
            errors.append(error.localizedDescription)
        }
        selectedSkillIDs = Set(
            skills
                .filter { remainingReadOnlyPaths.contains($0.directoryURL.path) }
                .map { $0.id }
        )
        if !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
        }
    }

    // MARK: - Pull Latest (FR-9)

    func pullLatest() async {
        guard let skill = selectedSkill else { return }
        guard !skill.isReadOnly else {
            errorMessage = SkillManagerError.readOnlySkill.localizedDescription
            return
        }

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
        guard !skill.isReadOnly else {
            errorMessage = SkillManagerError.readOnlySkill.localizedDescription
            return
        }

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
        guard !skill.isReadOnly else {
            errorMessage = SkillManagerError.readOnlySkill.localizedDescription
            return
        }

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
        guard !skill.isReadOnly else {
            errorMessage = SkillManagerError.readOnlySkill.localizedDescription
            return
        }

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
        let pendingPaths = pendingSelectionPaths
        let pendingProvider = pendingProviderSelection
        await saveEditing()
        guard !isEditing else { return }

        pendingSkillSelection = nil
        pendingSelectionPaths = nil
        pendingProviderSelection = nil

        if let pendingProvider {
            switchProvider(to: pendingProvider)
        } else if let pendingSkillPath {
            selectSkillForCurrentProvider(at: pendingSkillPath, restartEditing: true)
        } else if let pendingPaths {
            applyPendingSelectionPaths(pendingPaths)
        }
    }

    func discardAndNavigateToSkill() {
        let pendingSkillPath = pendingSkillSelection?.directoryURL.path
        let pendingPaths = pendingSelectionPaths
        let pendingProvider = pendingProviderSelection
        cancelEditing()
        pendingSkillSelection = nil
        pendingSelectionPaths = nil
        pendingProviderSelection = nil

        if let pendingProvider {
            switchProvider(to: pendingProvider)
        } else if let pendingSkillPath {
            selectSkillForCurrentProvider(at: pendingSkillPath, restartEditing: true)
        } else if let pendingPaths {
            applyPendingSelectionPaths(pendingPaths)
        }
    }

    func cancelNavigationToSkill() {
        pendingSkillSelection = nil
        pendingSelectionPaths = nil
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
        case .grok:
            return grokSkillManager
        case .shared:
            return sharedSkillManager
        }
    }

    private func refreshProvider(_ provider: SkillProvider) async throws {
        try await manager(for: provider).loadSkills()
        syncProviderState(for: provider)
    }

    private func syncProviderState(for provider: SkillProvider) {
        let loadedSkills = manager(for: provider).skills
        skillsByProvider[provider] = loadedSkills

        let loadedPaths = Set(loadedSkills.map { $0.directoryURL.path })
        var retainedPaths = selectedSkillPathsByProvider[provider] ?? []
        retainedPaths.formIntersection(loadedPaths)
        selectedSkillPathsByProvider[provider] = retainedPaths

        if provider == selectedProvider {
            restoreState(for: provider)
        }
    }

    private func restoreState(for provider: SkillProvider) {
        skills = skillsByProvider[provider, default: []]
        searchText = searchTextByProvider[provider, default: ""]
        let paths = selectedSkillPathsByProvider[provider] ?? []
        selectedSkillIDs = Set(
            skills
                .filter { paths.contains($0.directoryURL.path) }
                .map { $0.id }
        )
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
    }

    private func selectSkillForCurrentProvider(at path: String, restartEditing: Bool) {
        guard let skill = skills.first(where: { $0.directoryURL.path == path }) else { return }
        selectedSkillIDs = [skill.id]
        if restartEditing {
            startEditing()
        }
    }

    private func applyPendingSelectionPaths(_ paths: Set<String>) {
        let matchedIDs = Set(
            skills
                .filter { paths.contains($0.directoryURL.path) }
                .map { $0.id }
        )
        selectedSkillIDs = matchedIDs
    }
}
