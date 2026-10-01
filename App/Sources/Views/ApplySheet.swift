import SwiftUI
import OriginKit

/// The confirmation step. Nothing is written until the changes have been shown
/// line by line — a sources file that apt cannot read costs the user every
/// repository in it, so an edit is never applied silently.
struct ApplySheet: View {
    @EnvironmentObject private var store: OriginStore
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                ForEach(store.pendingPlan.writes, id: \.path) { write in
                    Section(header: Text(write.action.displayName)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text((write.path as NSString).lastPathComponent)
                                .font(.body.weight(.semibold))
                            Text(write.path)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        ForEach(Array(write.removedLines.enumerated()), id: \.offset) { _, line in
                            Text("− " + line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.red)
                        }
                        ForEach(Array(write.addedLines.enumerated()), id: \.offset) { _, line in
                            Text("+ " + line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }
                }

                Section(footer: Text("A snapshot of every sources file is taken before anything is written, and can be restored from the Backups tab.")) {
                    Text(store.pendingPlan.summary)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Review changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        presentationMode.wrappedValue.dismiss()
                        Task { await store.applyChanges() }
                    }
                    .disabled(store.isBusy)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
