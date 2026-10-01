import Foundation

public struct BackupFile: Codable, Hashable, Sendable {
    public var path: String
    public var contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

/// A snapshot of every sources file, taken before Origin writes anything.
/// Kept as JSON under the app's own directory so restoring never depends on the
/// app still being installed where it was.
public struct SourceBackup: Codable, Hashable, Sendable {
    public var createdAt: Date
    public var label: String
    public var layout: String
    public var files: [BackupFile]

    public init(createdAt: Date = Date(), label: String, layout: String, files: [BackupFile]) {
        self.createdAt = createdAt
        self.label = label
        self.layout = layout
        self.files = files
    }

    public var summary: String {
        "\(files.count) file" + (files.count == 1 ? "" : "s")
    }
}

public struct BackupStore {

    public let directory: String
    private let fileManager: FileManager

    public init(directory: String, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func makeBackup(of files: [SourceFile], label: String, layout: String) -> SourceBackup {
        SourceBackup(
            label: label,
            layout: layout,
            files: files
                .filter { !$0.originalText.isEmpty }
                .map { BackupFile(path: $0.path, contents: $0.originalText) }
        )
    }

    @discardableResult
    public func save(_ backup: SourceBackup) throws -> String {
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: backup.createdAt)
            .replacingOccurrences(of: ":", with: "-")
        let path = directory + "/" + stamp + ".json"
        let data = try BackupStore.encoder.encode(backup)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    public func list() -> [SourceBackup] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { load(path: directory + "/" + $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Paths of every snapshot, newest first. The CLI addresses backups by
    /// index and needs the same order `list()` uses.
    public func paths() -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> (String, Date)? in
                guard let backup = load(path: directory + "/" + name) else { return nil }
                return (directory + "/" + name, backup.createdAt)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    public func load(path: String) -> SourceBackup? {
        guard let data = fileManager.contents(atPath: path) else { return nil }
        return try? BackupStore.decoder.decode(SourceBackup.self, from: data)
    }

    /// A restore is an ordinary plan: the backup's contents become the desired
    /// state of every file it mentions.
    public func plan(restoring backup: SourceBackup, currentFiles: [SourceFile]) -> ApplyPlan {
        var writes: [PlannedWrite] = []
        let current = Dictionary(uniqueKeysWithValues: currentFiles.map { ($0.path, $0) })

        for file in backup.files {
            let existing = current[file.path]?.originalText
            if existing == file.contents { continue }
            writes.append(PlannedWrite(
                action: existing == nil ? .create : .modify,
                path: file.path,
                contents: file.contents,
                previous: existing,
                addedLines: [],
                removedLines: []
            ))
        }

        // A file Origin created after the backup was taken would otherwise
        // survive the restore and silently re-add the repository it holds.
        let restoredPaths = Set(backup.files.map { $0.path })
        for file in currentFiles where !restoredPaths.contains(file.path) && !file.repositories.isEmpty {
            writes.append(PlannedWrite(
                action: .delete,
                path: file.path,
                contents: nil,
                previous: file.originalText,
                addedLines: [],
                removedLines: Planner.lines(of: file.originalText)
            ))
        }

        return ApplyPlan(writes: writes)
    }
}
