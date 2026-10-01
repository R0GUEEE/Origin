import SwiftUI
import OriginKit

struct RepositoryEditorView: View {
    @EnvironmentObject private var store: OriginStore
    @Environment(\.presentationMode) private var presentationMode

    @State private var url: String
    @State private var suite: String
    @State private var components: String
    @State private var architectures: String
    @State private var note: String
    @State private var isDebSrc: Bool
    @State private var enabled: Bool

    private let originalID: String?
    private let isNew: Bool

    init(repository: Repository?) {
        let base = repository ?? Repository(url: "", suites: ["./"], components: [])
        _url = State(initialValue: base.url)
        _suite = State(initialValue: base.suites.joined(separator: " "))
        _components = State(initialValue: base.components.joined(separator: " "))
        _architectures = State(initialValue: base.architectures.joined(separator: ","))
        _note = State(initialValue: base.comment ?? "")
        _isDebSrc = State(initialValue: base.kinds.contains(.debSrc))
        _enabled = State(initialValue: base.enabled)
        originalID = repository?.id
        isNew = (repository == nil)
    }

    private var draft: Repository {
        let suites = suite.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return Repository(
            url: Validator.normalised(url: url),
            suites: suites.isEmpty ? ["./"] : suites,
            components: components.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init),
            kinds: isDebSrc ? [.deb, .debSrc] : [.deb],
            architectures: architectures
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            enabled: enabled,
            comment: note.isEmpty ? nil : note
        )
    }

    private var problems: [ValidationIssue] { Validator.issues(for: draft) }

    /// What the entry looks like in the file it will land in — deb822 for a new
    /// source, and whatever the file it is already in uses for an existing one.
    private var preview: String {
        let format = store.files.first { $0.contains(id: draft.id) }?.format ?? .deb822
        switch format {
        case .deb822: return Deb822.stanza(for: draft)
        case .oneLine: return APTList.line(for: draft)
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Repository")) {
                    TextField("https://repo.example.com/", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Suite — ./ for a flat repository", text: $suite)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Components, space separated", text: $components)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section(header: Text("Options")) {
                    Toggle("Also take source packages (deb-src)", isOn: $isDebSrc)
                    Toggle("Enabled", isOn: $enabled)
                    TextField("Architectures, comma separated", text: $architectures)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Note", text: $note)
                }

                if !problems.isEmpty {
                    Section(header: Text("Checks")) {
                        ForEach(Array(problems.enumerated()), id: \.offset) { _, issue in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(issue.severity == .error ? .red : .orange)
                                Text(issue.message).font(.footnote)
                            }
                        }
                    }
                }

                Section(header: Text("Will be written as")) {
                    Text(preview)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(isNew ? "New source" : "Edit source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.save(draft, replacing: originalID)
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(!Validator.errors(for: draft).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
