import SwiftUI
import AppKit

struct DetailPanelView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        if let skill = viewModel.selectedSkill {
            VStack(alignment: .leading, spacing: 0) {
                // Header — always visible above tabs
                VStack(alignment: .leading, spacing: 16) {
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
                        .help("Copy \(skill.provider.displayName) skill name")

                        Button {
                            exportSkill(skill)
                        } label: {
                            if viewModel.isExporting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Export as zip")
                        .disabled(viewModel.isExporting)
                    }

                    Picker("Tab", selection: $viewModel.detailPanelTab) {
                        Text("Info").tag(DetailTab.info)
                        Text("Content").tag(DetailTab.content)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)

                    Divider()
                }
                .padding([.horizontal, .top])

                if viewModel.detailPanelTab == .info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                    // Metadata grid
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Provider:")
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Text(skill.provider.displayName)
                        }

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

                    if !skill.fileTree.isEmpty {
                        Divider()

                        DisclosureGroup("Files (\(totalFileCount(skill.fileTree)))") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(skill.fileTree) { node in
                                    FileTreeRowView(node: node, depth: 0)
                                }
                            }
                            .padding(.top, 4)
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
                    .padding(.horizontal)
                }
                } else {
                    MarkdownWebView(
                        html: MarkdownRenderer.renderHTML(
                            markdown: skill.rawContent,
                            includeFrontmatter: false
                        )
                    )
                }
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
                                   description: Text("Select a \(viewModel.providerDisplayName) skill from the sidebar to view its details."))
        }
    }

    private func exportSkill(_ skill: Skill) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(skill.name).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await viewModel.exportSkill(to: url)
            }
        }
    }

    private func totalFileCount(_ nodes: [FileTreeNode]) -> Int {
        nodes.reduce(0) { count, node in
            if node.isDirectory {
                return count + totalFileCount(node.children)
            } else {
                return count + 1
            }
        }
    }
}

struct FileTreeRowView: View {
    let node: FileTreeNode
    let depth: Int

    var body: some View {
        if node.isDirectory {
            DisclosureGroup {
                ForEach(node.children) { child in
                    FileTreeRowView(node: child, depth: depth + 1)
                }
            } label: {
                Label(node.name, systemImage: "folder")
                    .font(.callout)
            }
        } else {
            Label(node.name, systemImage: fileIcon(for: node.name))
                .font(.callout)
                .padding(.leading, 4)
        }
    }

    private func fileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "py": return "doc.text"
        case "sh", "bash", "zsh": return "terminal"
        case "js", "ts", "swift", "rs", "go", "rb", "java", "c", "cpp", "h":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "gearshape"
        case "md", "txt", "rst":
            return "doc.plaintext"
        default:
            return "doc"
        }
    }
}
