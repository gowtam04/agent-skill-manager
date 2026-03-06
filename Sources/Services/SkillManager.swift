import Foundation
import Observation

struct StagedURLInstall: Sendable {
    let repoURL: String
    let cloneDestination: URL
    let skillDirs: [URL]
    let skillNames: [String]
}

@MainActor
@Observable
final class SkillManager {

    var skills: [Skill] = []
    var isLoading: Bool = false

    private let fileSystemManager: FileSystemManager
    private let gitManager: GitManager
    private let skillParser: SkillParser.Type
    private let metadataStore: MetadataStore

    init(
        fileSystemManager: FileSystemManager,
        gitManager: GitManager,
        skillParser: SkillParser.Type,
        metadataStore: MetadataStore
    ) {
        self.fileSystemManager = fileSystemManager
        self.gitManager = gitManager
        self.skillParser = skillParser
        self.metadataStore = metadataStore
    }

    // MARK: - Load Skills

    func loadSkills() async throws {
        isLoading = true
        defer { isLoading = false }

        let fm = FileManager.default
        let skillsDirExists = fm.fileExists(atPath: fileSystemManager.skillsDirectoryURL.path)
        let disabledDirExists = fm.fileExists(atPath: fileSystemManager.disabledDirectoryURL.path)
        if !skillsDirExists && !disabledDirExists {
            throw SkillManagerError.skillsDirectoryNotFound
        }

        let discovered = try fileSystemManager.scanSkills()
        let metadata = (try? metadataStore.load()) ?? [:]

        var loadedSkills: [Skill] = []

        for item in discovered {
            let dirName = item.directoryURL.lastPathComponent

            // Try to parse frontmatter; fall back to directory name per NFR-2
            let name: String
            let description: String
            let rawContent: String = item.skillMDContent

            if let parsed = try? skillParser.parse(content: item.skillMDContent) {
                name = parsed.name
                description = parsed.description
            } else {
                name = dirName
                description = ""
            }

            let sourceRepoURL = metadata[dirName]?.sourceRepoURL

            let skill = Skill(
                id: UUID(),
                name: name,
                description: description,
                directoryURL: item.directoryURL,
                isSymlink: item.isSymlink,
                symlinkTarget: item.symlinkTarget,
                isEnabled: item.isEnabled,
                sourceRepoURL: sourceRepoURL,
                rawContent: rawContent,
                fileTree: item.fileTree
            )
            loadedSkills.append(skill)
        }

        skills = loadedSkills
    }

    // MARK: - Add Skill from File

    func addSkillFromFile(sourceURL: URL) async throws {
        // Validate SKILL.md exists
        let skillMDURL = sourceURL.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: skillMDURL.path) else {
            throw SkillManagerError.noSkillMD
        }

        let dirName = sourceURL.lastPathComponent
        try fileSystemManager.copySkill(from: sourceURL, to: dirName)

        try await loadSkills()
    }

    // MARK: - Duplicate Detection

    func findDuplicateNames(for sourceURLs: [URL]) -> [String] {
        sourceURLs
            .map { $0.lastPathComponent }
            .filter { fileSystemManager.skillExists(named: $0) }
    }

    func findDuplicateSkillNames(_ names: [String]) -> [String] {
        names.filter { fileSystemManager.skillExists(named: $0) }
    }

    // MARK: - Add Skill from URL

    func stageSkillFromURL(repoURL: String) async throws -> StagedURLInstall {
        guard repoURL.hasPrefix("https://") else {
            throw SkillManagerError.invalidURL
        }

        let repoName = URL(string: repoURL)?.lastPathComponent ?? UUID().uuidString

        let appSupportDir = metadataStore.fileURL.deletingLastPathComponent()
        let reposDir = appSupportDir.appendingPathComponent("repos")
        try fileSystemManager.ensureDirectoryExists(at: reposDir)

        let cloneDestination = reposDir.appendingPathComponent(repoName)
        try await gitManager.clone(repoURL: repoURL, to: cloneDestination)

        // Find SKILL.md in the cloned repo
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: cloneDestination,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        // Check root level for SKILL.md
        let rootSkillMD = cloneDestination.appendingPathComponent("SKILL.md")
        var skillDirs: [URL] = []

        if fm.fileExists(atPath: rootSkillMD.path) {
            skillDirs.append(cloneDestination)
        }

        // Check subdirectories
        for item in contents {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                let subSkillMD = item.appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: subSkillMD.path) {
                    skillDirs.append(item)
                }
            }
        }

        guard !skillDirs.isEmpty else {
            throw SkillManagerError.noSkillMDInRepo
        }

        let skillNames = skillDirs.map { dir in
            dir == cloneDestination ? repoName : dir.lastPathComponent
        }

        return StagedURLInstall(
            repoURL: repoURL,
            cloneDestination: cloneDestination,
            skillDirs: skillDirs,
            skillNames: skillNames
        )
    }

    func commitStagedURLInstall(_ staged: StagedURLInstall) async throws {
        let fm = FileManager.default
        for (skillDir, skillName) in zip(staged.skillDirs, staged.skillNames) {
            let symlinkPath = fileSystemManager.skillsDirectoryURL.appendingPathComponent(skillName)

            // Remove existing item if present (user already confirmed overwrite)
            if fm.fileExists(atPath: symlinkPath.path) {
                try fm.removeItem(at: symlinkPath)
            }

            try fileSystemManager.createSymlink(at: symlinkPath, pointingTo: skillDir)

            // Store metadata
            var metadata = (try? metadataStore.load()) ?? [:]
            metadata[skillName] = SkillMetadata(
                sourceRepoURL: staged.repoURL,
                clonedRepoPath: staged.cloneDestination.path,
                installedAt: Date()
            )
            try metadataStore.save(metadata)
        }

        try await loadSkills()
    }

    func cancelStagedURLInstall(_ staged: StagedURLInstall) {
        try? FileManager.default.removeItem(at: staged.cloneDestination)
    }

    func addSkillFromURL(repoURL: String) async throws {
        let staged = try await stageSkillFromURL(repoURL: repoURL)
        try await commitStagedURLInstall(staged)
    }

    // MARK: - Enable / Disable

    func enableSkill(_ skill: Skill) async throws {
        let dirName = skill.directoryURL.lastPathComponent
        let destinationURL = fileSystemManager.skillsDirectoryURL.appendingPathComponent(dirName)

        try fileSystemManager.ensureDirectoryExists(at: fileSystemManager.skillsDirectoryURL)
        try fileSystemManager.moveSkill(from: skill.directoryURL, to: destinationURL)

        try await loadSkills()
    }

    func disableSkill(_ skill: Skill) async throws {
        let dirName = skill.directoryURL.lastPathComponent
        let destinationURL = fileSystemManager.disabledDirectoryURL.appendingPathComponent(dirName)

        try fileSystemManager.ensureDirectoryExists(at: fileSystemManager.disabledDirectoryURL)
        try fileSystemManager.moveSkill(from: skill.directoryURL, to: destinationURL)

        try await loadSkills()
    }

    // MARK: - Delete

    func deleteSkill(_ skill: Skill, removeSource: Bool) async throws {
        if skill.isSymlink && removeSource, let target = skill.symlinkTarget {
            // Remove the symlink first
            try fileSystemManager.deleteSkill(at: skill.directoryURL)
            // Then remove the source
            try fileSystemManager.deleteSkill(at: target)
        } else {
            try fileSystemManager.deleteSkill(at: skill.directoryURL)
        }

        // Clean up metadata entry for URL-installed skills (FR-8.3)
        let dirName = skill.directoryURL.lastPathComponent
        var metadata = (try? metadataStore.load()) ?? [:]
        if metadata.removeValue(forKey: dirName) != nil {
            try metadataStore.save(metadata)
        }

        try await loadSkills()
    }

    // MARK: - Pull Latest

    func pullLatest(for skill: Skill) async throws -> String {
        guard let sourceRepoURL = skill.sourceRepoURL else {
            throw SkillManagerError.notURLInstalled
        }

        let metadata = (try? metadataStore.load()) ?? [:]
        let dirName = skill.directoryURL.lastPathComponent

        guard let meta = metadata[dirName] else {
            throw SkillManagerError.noMetadata
        }

        let repoURL = URL(fileURLWithPath: meta.clonedRepoPath)
        return try await gitManager.pull(in: repoURL)
    }

    // MARK: - Export

    func exportSkill(_ skill: Skill, to destinationURL: URL) throws {
        let sourceURL: URL
        if skill.isSymlink, let target = skill.symlinkTarget {
            sourceURL = target
        } else {
            sourceURL = skill.directoryURL
        }
        try fileSystemManager.zipSkill(at: sourceURL, to: destinationURL)
    }

    // MARK: - Read / Save Content

    func readSkillContent(_ skill: Skill) throws -> String {
        let skillMDURL = skill.directoryURL.appendingPathComponent("SKILL.md")
        return try String(contentsOf: skillMDURL, encoding: .utf8)
    }

    func saveSkillContent(_ skill: Skill, content: String) throws {
        let skillMDURL = skill.directoryURL.appendingPathComponent("SKILL.md")
        try content.write(to: skillMDURL, atomically: true, encoding: .utf8)
    }
}

enum SkillManagerError: Error, LocalizedError {
    case noSkillMD
    case noSkillMDInRepo
    case notURLInstalled
    case noMetadata
    case invalidURL
    case skillsDirectoryNotFound

    var errorDescription: String? {
        switch self {
        case .noSkillMD:
            return "The selected directory does not contain a SKILL.md file."
        case .noSkillMDInRepo:
            return "No SKILL.md file was found in the cloned repository."
        case .notURLInstalled:
            return "This skill was not installed from a URL."
        case .noMetadata:
            return "No metadata found for this skill."
        case .invalidURL:
            return "Only HTTPS URLs are supported."
        case .skillsDirectoryNotFound:
            return "Skills directory not found. Please ensure ~/.claude/skills/ exists."
        }
    }
}
