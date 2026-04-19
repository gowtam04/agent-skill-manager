import SwiftUI

struct SidebarView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            providerPicker
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            List(viewModel.filteredSkills, selection: Binding<Skill.ID?>(
                get: { viewModel.selectedSkill?.id },
                set: { newID in
                    if let id = newID,
                       let skill = viewModel.filteredSkills.first(where: { $0.id == id }) {
                        viewModel.selectSkill(skill)
                    }
                }
            )) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.headline)
                    Text(skill.description.prefix(80).description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(skill.isEnabled ? 1.0 : 0.5)
                .tag(skill.id)
            }
            .listStyle(.sidebar)
        }
        .searchable(text: Binding(
            get: { viewModel.searchText },
            set: { viewModel.searchSkills(query: $0) }
        ), prompt: viewModel.providerSearchPrompt)
        .navigationTitle("Skills")
    }

    private var providerPicker: some View {
        Picker("Provider", selection: Binding(
            get: { viewModel.selectedProvider },
            set: { viewModel.requestProviderSelection($0) }
        )) {
            ForEach(SkillProvider.allCases) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
