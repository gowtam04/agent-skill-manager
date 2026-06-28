import SwiftUI

@main
struct AgentSkillManagerApp: App {
    @State private var viewModel: AppViewModel

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser

        // Claude Code paths
        let claudeSkillsDir = homeDir.appendingPathComponent(".claude/skills", isDirectory: true)
        let claudeDisabledDir = homeDir.appendingPathComponent(".claude/skills-disabled", isDirectory: true)

        // Codex paths (primary is now ~/.codex/skills/; .agents/ is exclusively the Shared tab)
        let codexSkillsDir = homeDir.appendingPathComponent(".codex/skills", isDirectory: true)
        let codexSystemSkillsDir = homeDir.appendingPathComponent(".codex/skills/.system", isDirectory: true)
        let codexConfigURL = homeDir.appendingPathComponent(".codex/config.toml")

        // Grok paths
        let grokSkillsDir = homeDir.appendingPathComponent(".grok/skills", isDirectory: true)
        let grokConfigURL = homeDir.appendingPathComponent(".grok/config.toml")

        // Shared (.agents) paths — the cross-tool standard
        let sharedSkillsDir = homeDir.appendingPathComponent(".agents/skills", isDirectory: true)
        let sharedDisabledDir = homeDir.appendingPathComponent(".agents/skills-disabled", isDirectory: true)

        let appSupportDir: URL
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            appSupportDir = support.appendingPathComponent("Agent-Skill-Manager", isDirectory: true)
        } else {
            appSupportDir = homeDir.appendingPathComponent("Library/Application Support/Agent-Skill-Manager", isDirectory: true)
        }

        // Claude Code manager (filesystem move for disabled)
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

        // Codex manager (config.toml overrides + read-only system skills)
        let codexFileSystemManager = FileSystemManager(
            skillsDirectoryURL: codexSkillsDir,
            readOnlySkillsDirectoryURLs: [codexSystemSkillsDir]
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

        // Grok manager (config.toml overrides, like Codex)
        let grokFileSystemManager = FileSystemManager(
            skillsDirectoryURL: grokSkillsDir
        )
        let grokMetadataStore = MetadataStore(
            fileURL: appSupportDir.appendingPathComponent("grok-metadata.json")
        )
        let grokSkillManager = SkillManager(
            provider: .grok,
            fileSystemManager: grokFileSystemManager,
            gitManager: GitManager(),
            skillParser: SkillParser.self,
            metadataStore: grokMetadataStore,
            grokConfigStore: GrokConfigStore(fileURL: grokConfigURL)
        )

        // Shared manager (filesystem move for disabled, the universal .agents/ standard)
        let sharedFileSystemManager = FileSystemManager(
            skillsDirectoryURL: sharedSkillsDir,
            disabledDirectoryURL: sharedDisabledDir
        )
        let sharedMetadataStore = MetadataStore(
            fileURL: appSupportDir.appendingPathComponent("shared-metadata.json")
        )
        let sharedSkillManager = SkillManager(
            provider: .shared,
            fileSystemManager: sharedFileSystemManager,
            gitManager: GitManager(),
            skillParser: SkillParser.self,
            metadataStore: sharedMetadataStore
        )

        _viewModel = State(initialValue: AppViewModel(
            claudeSkillManager: claudeSkillManager,
            codexSkillManager: codexSkillManager,
            grokSkillManager: grokSkillManager,
            sharedSkillManager: sharedSkillManager
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
