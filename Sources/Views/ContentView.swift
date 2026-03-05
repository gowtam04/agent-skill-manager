import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
        } detail: {
            if viewModel.isEditing {
                EditorView(viewModel: viewModel)
            } else {
                DetailPanelView(viewModel: viewModel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.isShowingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Skill")
            }
        }
        .task {
            await viewModel.loadSkills()
            await viewModel.triggerSync()
        }
        .sheet(isPresented: $viewModel.isShowingAddSheet) {
            AddSkillView(viewModel: viewModel)
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .alert("Unsaved Changes", isPresented: $viewModel.isShowingUnsavedChangesAlert) {
            Button("Save") {
                Task {
                    await viewModel.saveAndNavigateToSkill()
                }
            }
            Button("Discard", role: .destructive) {
                viewModel.discardAndNavigateToSkill()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelNavigationToSkill()
            }
        } message: {
            Text("You have unsaved changes. What would you like to do?")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await viewModel.loadSkills()
                await viewModel.triggerSync()
            }
        }
        .alert("Sync Conflicts", isPresented: $viewModel.isShowingSyncConflictAlert) {
            Button("OK") {
                viewModel.dismissSyncConflicts()
            }
        } message: {
            Text(syncConflictMessage)
        }
    }

    private var syncConflictMessage: String {
        let descriptions = viewModel.syncConflicts.map { conflict in
            switch conflict.reason {
            case .deletedRemotelyButModifiedLocally:
                return "\(conflict.skillName): deleted on another device but modified locally (kept local copy)"
            case .deletedLocallyButModifiedRemotely:
                return "\(conflict.skillName): deleted locally but modified on another device (kept remote copy)"
            }
        }
        return descriptions.joined(separator: "\n")
    }
}
