import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: AppViewModel

    @State private var syncFolderPath: String = ""
    @State private var isSyncEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable iCloud Sync", isOn: $isSyncEnabled)
                    .onChange(of: isSyncEnabled) { _, newValue in
                        if !newValue {
                            viewModel.disableSync()
                        } else if let syncManager = viewModel.syncManager,
                                  syncManager.syncSettings.syncFolderURL != nil {
                            viewModel.configureSyncFolder(syncManager.syncSettings.syncFolderURL!)
                        }
                    }

                HStack {
                    TextField("Sync Folder", text: $syncFolderPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)

                    Button("Choose...") {
                        chooseSyncFolder()
                    }
                }

                HStack {
                    Button("Sync Now") {
                        Task {
                            await viewModel.triggerSync()
                        }
                    }
                    .disabled(!isSyncEnabled || viewModel.isSyncing)

                    if viewModel.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    if let lastSync = viewModel.lastSyncDate {
                        Text("Last synced: \(lastSync.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            } header: {
                Text("iCloud Sync")
            } footer: {
                Text("Choose a folder inside iCloud Drive to sync skills across your Macs. The app will mirror your enabled and disabled skills to this folder.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 220)
        .onAppear {
            if let syncManager = viewModel.syncManager {
                isSyncEnabled = syncManager.syncSettings.isSyncEnabled
                syncFolderPath = syncManager.syncSettings.syncFolderURL?.path ?? ""
            }
        }
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose iCloud Sync Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            syncFolderPath = url.path
            isSyncEnabled = true
            viewModel.configureSyncFolder(url)
            Task {
                await viewModel.triggerSync()
            }
        }
    }
}
