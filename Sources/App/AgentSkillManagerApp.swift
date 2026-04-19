import SwiftUI

@main
struct AgentSkillManagerApp: App {
    @State private var viewModel: AppViewModel

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let claudeSkillsDir = homeDir.appendingPathComponent(".claude/skills", isDirectory: true)
        let claudeDisabledDir = homeDir.appendingPathComponent(".claude/skills-disabled", isDirectory: true)
        let codexSkillsDir = homeDir.appendingPathComponent(".agents/skills", isDirectory: true)
        let codexConfigURL = homeDir.appendingPathComponent(".codex/config.toml")

        let appSupportDir: URL
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            appSupportDir = support.appendingPathComponent("Agent-Skill-Manager", isDirectory: true)
        } else {
            appSupportDir = homeDir.appendingPathComponent("Library/Application Support/Agent-Skill-Manager", isDirectory: true)
        }

        let claudeFileSystemManager = FileSystemManager(
            skillsDirectoryURL: claudeSkillsDir,
            disabledDirectoryURL: claudeDisabledDir
        )
        let claudeMetadataStore = MetadataStore(
            fileURL: appSupportDir.appendingPathComponent("metadata.json")
        )
        let claudeSkillManager = SkillManager(
            provider: .claudeCode,
            fileSystemManager: claudeFileSystemManager,
            gitManager: GitManager(),
            skillParser: SkillParser.self,
            metadataStore: claudeMetadataStore
        )

        let codexFileSystemManager = FileSystemManager(
            skillsDirectoryURL: codexSkillsDir
        )
        let codexMetadataStore = MetadataStore(
            fileURL: appSupportDir.appendingPathComponent("codex-metadata.json")
        )
        let codexSkillManager = SkillManager(
            provider: .codex,
            fileSystemManager: codexFileSystemManager,
            gitManager: GitManager(),
            skillParser: SkillParser.self,
            metadataStore: codexMetadataStore,
            codexConfigStore: CodexConfigStore(fileURL: codexConfigURL)
        )

        _viewModel = State(initialValue: AppViewModel(
            claudeSkillManager: claudeSkillManager,
            codexSkillManager: codexSkillManager
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
