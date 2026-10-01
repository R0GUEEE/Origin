import SwiftUI
import OriginKit

struct BackupsView: View {
    @EnvironmentObject private var store: OriginStore
    @State private var pendingRestore: BackupRecord?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            Section {
                Button {
                    store.makeBackup(label: "manual")
                } label: {
                    Label("Back up now", systemImage: "plus.circle")
                }
            } footer: {
                Text("Origin also snapshots every sources file automatically before it applies a change. Snapshots are kept in \(store.layout.backupDirectory).")
            }

            if store.backups.isEmpty {
                Section { Text("No snapshots yet.").foregroundColor(.secondary) }
            } else {
                ForEach(store.backups) { record in
                    Button {
                        pendingRestore = record
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.formatter.string(from: record.backup.createdAt))
                                .font(.body.weight(.semibold))
                            Text("\(record.backup.summary) · \(record.backup.label)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.deleteBackup(at: record.path)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Backups")
        .refreshable { store.reload() }
        .alert(
            "Restore this snapshot?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            actions: {
                Button("Cancel", role: .cancel) { pendingRestore = nil }
                Button("Restore", role: .destructive) {
                    if let record = pendingRestore {
                        let backup = record.backup
                        Task { await store.restore(backup) }
                    }
                    pendingRestore = nil
                }
            },
            message: {
                Text("Every sources file is put back to how it was, and files added since the snapshot are removed.")
            }
        )
    }
}
