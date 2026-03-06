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
        .alert("Duplicate Skills", isPresented: $viewModel.isShowingDuplicateConfirmation) {
            Button("Overwrite", role: .destructive) {
                Task { await viewModel.confirmOverwriteDuplicates() }
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelOverwriteDuplicates()
            }
        } message: {
            if viewModel.duplicateSkillNames.count == 1 {
                Text("A skill named \"\(viewModel.duplicateSkillNames.first ?? "")\" already exists. Do you want to overwrite it?")
            } else {
                let names = viewModel.duplicateSkillNames.map { "\"\($0)\"" }.joined(separator: ", ")
                Text("Skills named \(names) already exist. Do you want to overwrite them?")
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
            }
        }
    }
}
