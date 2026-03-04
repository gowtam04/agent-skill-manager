import SwiftUI

struct DetailPanelView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        if let skill = viewModel.selectedSkill {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Name
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(skill.name)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(skill.name, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy skill name")
                    }

                    Divider()

                    // Metadata grid
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Description:")
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Text(skill.description)
                        }

                        GridRow {
                            Text("Path:")
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Text(skill.directoryURL.path)
                                .textSelection(.enabled)
                        }

                        GridRow {
                            Text("Type:")
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            if skill.isSymlink, let target = skill.symlinkTarget {
                                Text("Symlink \u{2192} \(target.path)")
                            } else {
                                Text("Local copy")
                            }
                        }

                        if let sourceURL = skill.sourceRepoURL {
                            GridRow {
                                Text("Source:")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                Text("Cloned from \(sourceURL)")
                            }
                        } else {
                            GridRow {
                                Text("Source:")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                Text("Imported from file")
                            }
                        }

                        GridRow {
                            Text("Status:")
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(skill.isEnabled ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(skill.isEnabled ? "Enabled" : "Disabled")
                            }
                        }
                    }

                    Divider()

                    // Action buttons
                    HStack(spacing: 12) {
                        Button("Edit") {
                            viewModel.startEditing()
                        }

                        Button(skill.isEnabled ? "Disable" : "Enable") {
                            Task {
                                if skill.isEnabled {
                                    await viewModel.disableSkill()
                                } else {
                                    await viewModel.enableSkill()
                                }
                            }
                        }

                        if skill.sourceRepoURL != nil {
                            Button {
                                Task {
                                    await viewModel.pullLatest()
                                }
                            } label: {
                                if viewModel.isPulling {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Pulling...")
                                } else {
                                    Text("Pull Latest")
                                }
                            }
                            .disabled(viewModel.isPulling)
                        }

                        Button("Delete", role: .destructive) {
                            viewModel.isShowingDeleteConfirmation = true
                        }
                    }

                    Spacer()
                }
                .padding()
            }
            .alert("Delete Skill", isPresented: $viewModel.isShowingDeleteConfirmation) {
                if skill.isSymlink {
                    Button("Remove link only", role: .destructive) {
                        Task { await viewModel.deleteSkill(removeSource: false) }
                    }
                    Button("Remove link and source", role: .destructive) {
                        Task { await viewModel.deleteSkill(removeSource: true) }
                    }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("Delete", role: .destructive) {
                        Task { await viewModel.deleteSkill(removeSource: false) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                if skill.isSymlink {
                    Text("This skill is a symlink. Choose how to remove it.")
                } else {
                    Text("Delete \(skill.name)? This will permanently remove the skill and its files.")
                }
            }
        } else {
            ContentUnavailableView("No Skill Selected",
                                   systemImage: "doc.text",
                                   description: Text("Select a skill from the sidebar to view its details."))
        }
    }
}
