import Foundation
import Observation

@MainActor
@Observable
final class AppViewModel {

    // MARK: - Published State

    var skills: [Skill] = []
    var filteredSkills: [Skill] = []
    var selectedSkill: Skill?
    var searchText: String = ""
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

    // Add skill state
    var isShowingAddSheet: Bool = false
    var addSkillURL: String = ""

    // Duplicate confirmation state
    var isShowingDuplicateConfirmation: Bool = false
    var duplicateSkillNames: [String] = []
    private var pendingFileImportURLs: [URL] = []
    private var pendingStagedURLInstall: StagedURLInstall?

    // Delete state
    var isShowingDeleteConfirmation: Bool = false

    // Pull state
    var isPulling: Bool = false

    // Export state
    var isExporting: Bool = false

    // MARK: - Private

    private let skillManager: SkillManager

    // MARK: - Init

    init(skillManager: SkillManager) {
        self.skillManager = skillManager
    }

    // MARK: - Load Skills

    func loadSkills() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await skillManager.loadSkills()
            skills = skillManager.skills
            applyFilter()

            // Preserve selection if the skill still exists
            if let selected = selectedSkill {
                selectedSkill = skills.first { $0.name == selected.name }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Selection

    func selectSkill(_ skill: Skill) {
        if isEditing {
            if editorContent != editorOriginalContent {
                pendingSkillSelection = skill
                isShowingUnsavedChangesAlert = true
            } else {
                selectedSkill = skill
                startEditing()
            }
        } else {
            selectedSkill = skill
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
        let duplicates = skillManager.findDuplicateNames(for: urls)
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
                try await skillManager.addSkillFromFile(sourceURL: url)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        skills = skillManager.skills
        applyFilter()
        if errors.isEmpty {
            isShowingAddSheet = false
        } else {
            errorMessage = errors.joined(separator: "\n")
        }
    }

    // MARK: - Add Skill from URL (FR-5)

    func addSkillFromURL() async {
        do {
            let staged = try await skillManager.stageSkillFromURL(repoURL: addSkillURL)
            let duplicates = skillManager.findDuplicateSkillNames(staged.skillNames)
            if duplicates.isEmpty {
                try await skillManager.commitStagedURLInstall(staged)
                skills = skillManager.skills
                applyFilter()
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
                try await skillManager.commitStagedURLInstall(staged)
                skills = skillManager.skills
                applyFilter()
                isShowingAddSheet = false
                addSkillURL = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelOverwriteDuplicates() {
        if let staged = pendingStagedURLInstall {
            skillManager.cancelStagedURLInstall(staged)
            pendingStagedURLInstall = nil
        }
        pendingFileImportURLs = []
        duplicateSkillNames = []
    }

    // MARK: - Enable / Disable (FR-7)

    func enableSkill() async {
        guard let skill = selectedSkill else { return }
        do {
            try await skillManager.enableSkill(skill)
            skills = skillManager.skills
            applyFilter()
            selectedSkill = skills.first { $0.name == skill.name }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disableSkill() async {
        guard let skill = selectedSkill else { return }
        do {
            try await skillManager.disableSkill(skill)
            skills = skillManager.skills
            applyFilter()
            selectedSkill = skills.first { $0.name == skill.name }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Delete (FR-8)

    func deleteSkill(removeSource: Bool) async {
        guard let skill = selectedSkill else { return }
        do {
            try await skillManager.deleteSkill(skill, removeSource: removeSource)
            selectedSkill = nil
            skills = skillManager.skills
            applyFilter()
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
            _ = try await skillManager.pullLatest(for: skill)
            await loadSkills()
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
            try skillManager.exportSkill(skill, to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Editor (FR-6)

    func startEditing() {
        guard let skill = selectedSkill else { return }
        do {
            let content = try skillManager.readSkillContent(skill)
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
            try skillManager.saveSkillContent(skill, content: editorContent)
            isEditing = false
            editorFileModificationDate = nil
            await loadSkills()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forceSaveEditing() async {
        guard let skill = selectedSkill else { return }
        do {
            try skillManager.saveSkillContent(skill, content: editorContent)
            isEditing = false
            editorFileModificationDate = nil
            isShowingExternalModificationWarning = false
            await loadSkills()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelEditing() {
        isEditing = false
        editorContent = ""
        editorOriginalContent = ""
        editorFileModificationDate = nil
    }

    // MARK: - Unsaved Changes Navigation

    func saveAndNavigateToSkill() async {
        guard let pending = pendingSkillSelection else { return }
        await saveEditing()
        pendingSkillSelection = nil
        selectedSkill = pending
        startEditing()
    }

    func discardAndNavigateToSkill() {
        guard let pending = pendingSkillSelection else { return }
        cancelEditing()
        pendingSkillSelection = nil
        selectedSkill = pending
        startEditing()
    }

    func cancelNavigationToSkill() {
        pendingSkillSelection = nil
    }
}
