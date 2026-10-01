import SwiftUI
import OriginKit

struct RepositoryListView: View {
    @EnvironmentObject private var store: OriginStore
    @State private var search = ""
    @State private var editing: Repository?
    @State private var showingNew = false
    @State private var showingApply = false

    private struct Group: Identifiable {
        var id: String { name }
        let name: String
        let repositories: [Repository]
    }

    private var groups: [Group] {
        let needle = search.lowercased()
        let filtered = store.repositories.filter { repository in
            guard !needle.isEmpty else { return true }
            return repository.url.lowercased().contains(needle)
                || repository.host.lowercased().contains(needle)
                || (repository.file ?? "").lowercased().contains(needle)
        }
        let byFile = Dictionary(grouping: filtered) { $0.file ?? "origin.sources" }
        return byFile.keys.sorted().map { name in
            Group(name: name, repositories: (byFile[name] ?? []).sorted { $0.host < $1.host })
        }
    }

    var body: some View {
        List {
            if store.repositories.isEmpty {
                Section { emptyState }
            }

            ForEach(groups) { group in
                Section(header: Text(group.name)) {
                    ForEach(group.repositories) { repository in
                        Button { editing = repository } label: {
                            RepositoryRow(
                                repository: repository,
                                onToggle: { store.setEnabled($0, in: repository) }
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.remove(repository)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !store.issues.isEmpty {
                Section(header: Text("Unreadable")) {
                    ForEach(Array(store.issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue).font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sources")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Host, URL or file")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showingApply = true } label: {
                    if store.hasPendingChanges {
                        Label("\(store.pendingPlan.writes.count)", systemImage: "checkmark.circle.fill")
                    } else {
                        Image(systemName: "checkmark.circle")
                    }
                }
                .disabled(!store.hasPendingChanges || store.isBusy)
                .accessibilityLabel("Review and apply changes")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingNew = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a source")
            }
        }
        .sheet(isPresented: $showingApply) { ApplySheet() }
        .sheet(isPresented: $showingNew) { RepositoryEditorView(repository: nil) }
        .sheet(item: $editing) { repository in RepositoryEditorView(repository: repository) }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(store.lastError ?? "") }
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No sources files found").font(.body.weight(.semibold))
            Text("Origin looked in \(store.layout.sourcesDirectories.joined(separator: " and ")). Add a source and it will create one.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct RepositoryRow: View {
    let repository: Repository
    let onToggle: (Bool) -> Void

    private var detail: String {
        var parts = [repository.suiteLabel]
        if !repository.components.isEmpty {
            parts.append(repository.components.joined(separator: " "))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(repository.host)
                    .font(.body.weight(.semibold))
                    .foregroundColor(repository.enabled ? .primary : .secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(repository.url)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if repository.isDebSrcOnly {
                Text("src")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }
            Toggle("", isOn: Binding(get: { repository.enabled }, set: onToggle))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}
