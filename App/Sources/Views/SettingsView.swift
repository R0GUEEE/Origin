import SwiftUI
import OriginKit

struct SettingsView: View {
    @EnvironmentObject private var store: OriginStore

    var body: some View {
        List {
            Section(header: Text("This device")) {
                row("Layout", store.layout.style.displayName)
                row("APT directory", store.layout.aptDirectory)
                row("Package architecture", store.layout.style.aptArchitecture)
                row("Helper", store.canWrite ? "installed" : "missing")
            }

            Section(header: Text("Files")) {
                ForEach(store.layout.sourcesDirectories, id: \.self) { directory in
                    row((directory as NSString).lastPathComponent, directory)
                }
                NavigationLink("Activity log") { LogView() }
            }

            Section {
                Button {
                    Task { await store.refreshPackageLists() }
                } label: {
                    Label("Refresh package lists", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isBusy || !store.canWrite)

                Button {
                    Task { await store.respring() }
                } label: {
                    Label("Restart SpringBoard", systemImage: "arrow.counterclockwise")
                }
                .disabled(store.isBusy || !store.canWrite)
            } footer: {
                Text(store.canWrite
                     ? "Both commands run through origin-helper as root."
                     : "origin-helper is not installed, so Origin cannot write sources files or refresh package lists. Reinstall the package.")
            }

            Section {
                Button {
                    store.reload()
                } label: {
                    Label("Reload sources", systemImage: "arrow.clockwise")
                }
            }

            Section {
                row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                Link("Report an issue", destination: URL(string: "https://github.com/R0GUEEE/Origin/issues")!)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .font(.footnote)
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var store: OriginStore

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        List {
            if store.log.isEmpty {
                Text("Nothing logged yet.").foregroundColor(.secondary)
            }
            ForEach(store.log) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Text(Self.formatter.string(from: entry.date))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(entry.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(entry.isError ? .red : .primary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Activity log")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") { store.clearLog() }
            }
        }
    }
}
