import SwiftUI

@main
struct CCSkillManagerApp: App {
    @State private var viewModel: AppViewModel

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let skillsDir = homeDir.appendingPathComponent(".claude/skills", isDirectory: true)
        let disabledDir = homeDir.appendingPathComponent(".claude/skills-disabled", isDirectory: true)

        let appSupportDir: URL
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            appSupportDir = support.appendingPathComponent("CC-Skill-Manager", isDirectory: true)
        } else {
            appSupportDir = homeDir.appendingPathComponent("Library/Application Support/CC-Skill-Manager", isDirectory: true)
        }

        let fileSystemManager = FileSystemManager(
            skillsDirectoryURL: skillsDir,
            disabledDirectoryURL: disabledDir
        )
        let metadataStore = MetadataStore(
            fileURL: appSupportDir.appendingPathComponent("metadata.json")
        )
        let skillManager = SkillManager(
            fileSystemManager: fileSystemManager,
            gitManager: GitManager(),
            skillParser: SkillParser.self,
            metadataStore: metadataStore
        )

        let syncSettings = SyncSettings()
        let syncManager = SyncManager(
            localSkillsURL: skillsDir,
            localDisabledURL: disabledDir,
            syncSettings: syncSettings
        )

        _viewModel = State(initialValue: AppViewModel(
            skillManager: skillManager,
            syncManager: syncManager
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}
