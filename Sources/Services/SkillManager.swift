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

    let provider: SkillProvider
    private let fileSystemManager: FileSystemManager
    private let gitManager: GitManager
    private let skillParser: SkillParser.Type
    private let metadataStore: MetadataStore
    private let codexConfigStore: CodexConfigStore?

    init(
        provider: SkillProvider,
        fileSystemManager: FileSystemManager,
        gitManager: GitManager,
        skillParser: SkillParser.Type,
        metadataStore: MetadataStore,
        codexConfigStore: CodexConfigStore? = nil
    ) {
        self.provider = provider
        self.fileSystemManager = fileSystemManager
        self.gitManager = gitManager
        self.skillParser = skillParser
        self.metadataStore = metadataStore
        self.codexConfigStore = codexConfigStore
    }

    // MARK: - Load Skills

    func loadSkills() async throws {
        isLoading = true
        defer { isLoading = false }

        let fm = FileManager.default
        let skillsDirExists = fm.fileExists(atPath: fileSystemManager.skillsDirectoryURL.path)
        let disabledDirExists = fileSystemManager.disabledDirectoryURL.map { fm.fileExists(atPath: $0.path) } ?? false

        if provider == .claudeCode && !skillsDirExists && !disabledDirExists {
            throw SkillManagerError.skillsDirectoryNotFound(provider)
        }

        if provider == .codex && !skillsDirExists {
            skills = []
            return
        }

        let discovered = try fileSystemManager.scanSkills()
        let metadata = (try? metadataStore.load()) ?? [:]
        let disabledCodexPaths = (try? codexConfigStore?.disabledSkillMDPaths()) ?? []

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
            let isEnabled: Bool
            if provider == .codex {
                let skillMDURLs = skillMDURLs(
                    directoryURL: item.directoryURL,
                    symlinkTarget: item.symlinkTarget
                )
                isEnabled = !skillMDURLs.contains { url in
                    disabledCodexPaths.contains(url.standardizedFileURL.path)
                }
            } else {
                isEnabled = item.isEnabled
            }

            let skill = Skill(
                id: UUID(),
                provider: provider,
                name: name,
                description: description,
                directoryURL: item.directoryURL,
                isSymlink: item.isSymlink,
                symlinkTarget: item.symlinkTarget,
                isEnabled: isEnabled,
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
        try fileSystemManager.ensureDirectoryExists(at: fileSystemManager.skillsDirectoryURL)
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

        var skillDirs: [URL] = []
        let fm = FileManager.default

        if let enumerator = fm.enumerator(
            at: cloneDestination,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: nil
        ) {
            while let itemURL = enumerator.nextObject() as? URL {
                if itemURL.lastPathComponent == ".git" {
                    enumerator.skipDescendants()
                    continue
                }

                if itemURL.lastPathComponent == "SKILL.md" {
                    skillDirs.append(itemURL.deletingLastPathComponent())
                }
            }
        }

        skillDirs = Array(
            Dictionary(
                uniqueKeysWithValues: skillDirs.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) }
            ).values
        ).sorted { $0.path < $1.path }

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
        try fileSystemManager.ensureDirectoryExists(at: fileSystemManager.skillsDirectoryURL)

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
        switch provider {
        case .claudeCode:
            let dirName = skill.directoryURL.lastPathComponent
            let destinationURL = fileSystemManager.skillsDirectoryURL.appendingPathComponent(dirName)

            try fileSystemManager.ensureDirectoryExists(at: fileSystemManager.skillsDirectoryURL)
            try fileSystemManager.moveSkill(from: skill.directoryURL, to: destinationURL)
        case .codex:
            try codexConfigStore?.enableSkill(
                at: skill.skillMDURL,
                alternateSkillMDURLs: alternateSkillMDURLs(for: skill)
            )
        }

        try await loadSkills()
    }

    func disableSkill(_ skill: Skill) async throws {
        switch provider {
        case .claudeCode:
            guard let disabledDirectoryURL = fileSystemManager.disabledDirectoryURL else {
                throw SkillManagerError.disabledDirectoryUnsupported(provider)
            }

            let dirName = skill.directoryURL.lastPathComponent
            let destinationURL = disabledDirectoryURL.appendingPathComponent(dirName)

            try fileSystemManager.ensureDirectoryExists(at: disabledDirectoryURL)
            try fileSystemManager.moveSkill(from: skill.directoryURL, to: destinationURL)
        case .codex:
            try codexConfigStore?.disableSkill(
                at: skill.skillMDURL,
                alternateSkillMDURLs: alternateSkillMDURLs(for: skill)
            )
        }

        try await loadSkills()
    }

    // MARK: - Delete

    func deleteSkill(_ skill: Skill, removeSource: Bool) async throws {
        let metadataKey = skill.directoryURL.lastPathComponent
        let metadata = (try? metadataStore.load()) ?? [:]

        if skill.isSymlink && removeSource {
            // Remove the symlink first
            try fileSystemManager.deleteSkill(at: skill.directoryURL)
            if let clonedRepoPath = metadata[metadataKey]?.clonedRepoPath {
                let repoURL = URL(fileURLWithPath: clonedRepoPath)
                if FileManager.default.fileExists(atPath: repoURL.path) {
                    try fileSystemManager.deleteSkill(at: repoURL)
                }
            } else if let target = skill.symlinkTarget {
                try fileSystemManager.deleteSkill(at: target)
            }
        } else {
            try fileSystemManager.deleteSkill(at: skill.directoryURL)
        }

        // Clean up metadata entry for URL-installed skills (FR-8.3)
        var updatedMetadata = metadata
        if updatedMetadata.removeValue(forKey: metadataKey) != nil {
            try metadataStore.save(updatedMetadata)
        }

        if provider == .codex {
            try codexConfigStore?.removeOverrides(
                for: [skill.skillMDURL] + alternateSkillMDURLs(for: skill)
            )
        }

        try await loadSkills()
    }

    // MARK: - Pull Latest

    func pullLatest(for skill: Skill) async throws -> String {
        guard skill.sourceRepoURL != nil else {
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
    case skillsDirectoryNotFound(SkillProvider)
    case disabledDirectoryUnsupported(SkillProvider)

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
        case .skillsDirectoryNotFound(let provider):
            switch provider {
            case .claudeCode:
                return "Skills directory not found. Please ensure ~/.claude/skills/ exists."
            case .codex:
                return "Skills directory not found. Please ensure ~/.agents/skills/ exists."
            }
        case .disabledDirectoryUnsupported(let provider):
            return "\(provider.displayName) does not use a disabled skills directory."
        }
    }
}

private extension SkillManager {
    func skillMDURLs(directoryURL: URL, symlinkTarget: URL?) -> [URL] {
        var urls = [directoryURL.appendingPathComponent("SKILL.md")]
        if let symlinkTarget {
            urls.append(symlinkTarget.appendingPathComponent("SKILL.md"))
        }
        return Array(
            Dictionary(uniqueKeysWithValues: urls.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) }).values
        )
    }

    func alternateSkillMDURLs(for skill: Skill) -> [URL] {
        guard let symlinkTarget = skill.symlinkTarget else {
            return []
        }
        return [symlinkTarget.appendingPathComponent("SKILL.md")]
    }
}
