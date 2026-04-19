import SwiftUI

struct AddSkillView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text(viewModel.addSkillTitle)
                .font(.title2)
                .fontWeight(.bold)

            Divider()

            // Import from file
            VStack(alignment: .leading, spacing: 8) {
                Text("Import from File")
                    .font(.headline)
                Text("Select one or more \(viewModel.providerDisplayName) skill directories containing a SKILL.md file.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Choose Folder...") {
                    openFilePanel()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Install from URL
            VStack(alignment: .leading, spacing: 8) {
                Text("Install from URL")
                    .font(.headline)
                Text("Enter a public Git repository URL (HTTPS) containing one or more \(viewModel.providerDisplayName) skills.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("https://github.com/user/repo", text: $viewModel.addSkillURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Install") {
                        Task {
                            await viewModel.addSkillFromURL()
                            if viewModel.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(viewModel.addSkillURL.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(width: 480, height: 360)
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select one or more \(viewModel.providerDisplayName) skill directories containing SKILL.md"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            Task {
                await viewModel.addSkillsFromFiles(urls: panel.urls)
                if viewModel.errorMessage == nil {
                    dismiss()
                }
            }
        }
    }
}
