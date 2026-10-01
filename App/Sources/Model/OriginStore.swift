import Foundation
import OriginKit

/// Everything the views read and everything that writes happens here.
///
/// The store never edits a file on disk as you type: edits live in memory, the
/// pending `ApplyPlan` is what the UI shows, and only `applyChanges()` writes.
@MainActor
final class OriginStore: ObservableObject {

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let text: String
        let isError: Bool
    }

    @Published private(set) var files: [SourceFile] = []
    @Published private(set) var issues: [String] = []
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var backups: [BackupRecord] = []
    @Published var isBusy = false
    @Published var lastError: String?

    let layout: JailbreakLayout
    private let writer: PrivilegedWriter

    init(layout: JailbreakLayout = JailbreakLayout.detect()) {
        self.layout = layout
        self.writer = PrivilegedWriter(layout: layout)
        reload()
    }

    // MARK: - Derived state

    var repositories: [Repository] { files.flatMap { $0.repositories } }

    var pendingPlan: ApplyPlan { Planner.plan(files: files) }

    var hasPendingChanges: Bool { !pendingPlan.isEmpty }

    var canWrite: Bool { writer.isAvailable }

    var backupStore: BackupStore { BackupStore(directory: layout.backupDirectory) }

    // MARK: - Reading

    func reload() {
        let loaded = SourceStore(layout: layout).load()
        files = loaded.files
        issues = loaded.issues
        backups = BackupStore(directory: layout.backupDirectory).records()
    }

    // MARK: - Editing (in memory)

    func save(_ repository: Repository, replacing originalID: String?) {
        // Changing the URL changes the identity, so the old entry has to go
        // first or the edit would leave the previous one behind.
        if let originalID, originalID != repository.id {
            for index in files.indices where files[index].contains(id: originalID) {
                files[index].remove(id: originalID)
            }
        }

        if let index = files.firstIndex(where: { $0.contains(id: repository.id) }) {
            files[index].replace(repository)
            return
        }
        if let index = files.firstIndex(where: { $0.name == "origin.sources" }) {
            files[index].append(repository)
            return
        }
        var file = SourceStore(layout: layout).makeFile(named: "origin", format: .deb822)
        file.append(repository)
        files.append(file)
    }

    func remove(_ repository: Repository) {
        for index in files.indices where files[index].contains(id: repository.id) {
            files[index].remove(id: repository.id)
        }
    }

    func setEnabled(_ enabled: Bool, in repository: Repository) {
        for index in files.indices where files[index].contains(id: repository.id) {
            files[index].setEnabled(enabled, id: repository.id)
        }
    }

    // MARK: - Writing

    func applyChanges() async {
        let plan = pendingPlan
        guard !plan.isEmpty else { return }

        isBusy = true
        defer { isBusy = false }

        let layout = self.layout
        let snapshot = files
        var backupPath: String?
        do {
            backupPath = try await perform {
                let store = BackupStore(directory: layout.backupDirectory)
                let backup = store.makeBackup(of: snapshot, label: "before apply", layout: layout.style.rawValue)
                return try store.save(backup)
            }
        } catch {
            report(error)
            return
        }
        if let backupPath { append("Backed up to \(backupPath)") }

        do {
            let writer = self.writer
            let applied = try await perform { try PlanApplier.apply(plan, with: writer) }
            applied.forEach { append($0) }
            reload()
        } catch {
            report(error)
        }
    }

    func makeBackup(label: String) {
        let layout = self.layout
        let snapshot = files
        do {
            let store = BackupStore(directory: layout.backupDirectory)
            let backup = store.makeBackup(of: snapshot, label: label, layout: layout.style.rawValue)
            let path = try store.save(backup)
            reload()
            append("Saved \(path)")
        } catch {
            report(error)
        }
    }

    func restore(_ backup: SourceBackup) async {
        isBusy = true
        defer { isBusy = false }

        let layout = self.layout
        let snapshot = files
        do {
            let plan = try await perform { () -> ApplyPlan in
                let store = BackupStore(directory: layout.backupDirectory)
                return store.plan(restoring: backup, currentFiles: snapshot)
            }
            guard !plan.isEmpty else {
                append("Already matches that backup.")
                return
            }
            let writer = self.writer
            let applied = try await perform { try PlanApplier.apply(plan, with: writer) }
            applied.forEach { append($0) }
            reload()
        } catch {
            report(error)
        }
    }

    func deleteBackup(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        reload()
    }

    // MARK: - Package manager

    func refreshPackageLists() async {
        isBusy = true
        defer { isBusy = false }
        let layout = self.layout
        do {
            let result = try await perform {
                try Subprocess.run(executable: layout.helperPath, arguments: ["apt-update"])
            }
            append(result.output.isEmpty ? "(apt-get produced no output)" : result.output,
                   isError: !result.succeeded)
            append(result.succeeded ? "Package lists updated." : "apt-get exited \(result.status).",
                   isError: !result.succeeded)
        } catch {
            report(error)
        }
    }

    func respring() async {
        isBusy = true
        defer { isBusy = false }
        let layout = self.layout
        do {
            // `respring` execl's sbreload, so this call only returns if it
            // failed — which is exactly when the error is worth showing.
            let result = try await perform {
                try Subprocess.run(executable: layout.helperPath, arguments: ["respring"])
            }
            if !result.succeeded {
                append(result.output, isError: true)
            }
        } catch {
            report(error)
        }
    }

    // MARK: - Log

    func append(_ text: String, isError: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log.append(LogEntry(date: Date(), text: trimmed, isError: isError))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    func clearLog() { log.removeAll() }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
        append(message, isError: true)
    }

    /// Runs blocking work — spawning a process, touching the filesystem — off
    /// the main actor, because `Subprocess` waits for the child to exit.
    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
