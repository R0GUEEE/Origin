import Foundation

public enum PlannedAction: String, Hashable, Sendable {
    case create
    case modify
    case delete

    public var displayName: String {
        switch self {
        case .create: return "Add"
        case .modify: return "Update"
        case .delete: return "Remove"
        }
    }
}

/// One file the plan will change.
public struct PlannedWrite: Hashable, Sendable {
    public var action: PlannedAction
    public var path: String
    public var contents: String?
    public var previous: String?
    public var addedLines: [String]
    public var removedLines: [String]

    public init(
        action: PlannedAction,
        path: String,
        contents: String?,
        previous: String?,
        addedLines: [String] = [],
        removedLines: [String] = []
    ) {
        self.action = action
        self.path = path
        self.contents = contents
        self.previous = previous
        self.addedLines = addedLines
        self.removedLines = removedLines
    }
}

/// What applying the current edits would do. Shown before anything is written —
/// this is the whole reason the app never mutates a sources file as you type.
public struct ApplyPlan: Hashable, Sendable {
    public var writes: [PlannedWrite]

    public init(writes: [PlannedWrite]) {
        self.writes = writes
    }

    public var isEmpty: Bool { writes.isEmpty }

    public var created: Int { writes.filter { $0.action == .create }.count }
    public var modified: Int { writes.filter { $0.action == .modify }.count }
    public var deleted: Int { writes.filter { $0.action == .delete }.count }

    public var summary: String {
        if writes.isEmpty { return "No changes." }
        var parts: [String] = []
        if created > 0 { parts.append("\(created) added") }
        if modified > 0 { parts.append("\(modified) updated") }
        if deleted > 0 { parts.append("\(deleted) removed") }
        return parts.joined(separator: ", ") + " file" + (writes.count == 1 ? "" : "s")
    }
}

public enum Planner {

    /// Compares the edited in-memory files against what is on disk and returns
    /// only the differences. A file whose text is unchanged is left alone, so
    /// applying twice is a no-op and an app restart cannot rewrite a file it was
    /// not asked to touch.
    public static func plan(files: [SourceFile], deleteEmptyFiles: Bool = true) -> ApplyPlan {
        var writes: [PlannedWrite] = []

        for file in files {
            let text = Serializer.text(for: file)
            let emptied = file.repositories.isEmpty && !file.hasContent

            if emptied && deleteEmptyFiles {
                if file.originalText.isEmpty { continue }
                writes.append(PlannedWrite(
                    action: .delete,
                    path: file.path,
                    contents: nil,
                    previous: file.originalText,
                    removedLines: lines(of: file.originalText)
                ))
                continue
            }

            if text == file.originalText { continue }

            if file.originalText.isEmpty {
                writes.append(PlannedWrite(
                    action: .create,
                    path: file.path,
                    contents: text,
                    previous: nil,
                    addedLines: lines(of: text)
                ))
            } else {
                let difference = diff(old: lines(of: file.originalText), new: lines(of: text))
                writes.append(PlannedWrite(
                    action: .modify,
                    path: file.path,
                    contents: text,
                    previous: file.originalText,
                    addedLines: difference.added,
                    removedLines: difference.removed
                ))
            }
        }

        return ApplyPlan(writes: writes)
    }

    public static func lines(of text: String) -> [String] {
        let normalised = text.normalisedLineEndings()
        var result = normalised.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    /// Longest-common-subsequence diff. Sources files are tiny, so the quadratic
    /// table costs nothing and a real diff reads far better in the confirmation
    /// sheet than "this file changed".
    public static func diff(old: [String], new: [String]) -> (added: [String], removed: [String]) {
        let n = old.count
        let m = new.count
        if n == 0 { return (new, []) }
        if m == 0 { return ([], old) }
        if n * m > 250_000 {
            // Pathological input: fall back to a set difference rather than
            // building a multi-megabyte table.
            let newSet = Set(new)
            let oldSet = Set(old)
            return (new.filter { !oldSet.contains($0) }, old.filter { !newSet.contains($0) })
        }

        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var added: [String] = []
        var removed: [String] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if old[i] == new[j] {
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                removed.append(old[i])
                i += 1
            } else {
                added.append(new[j])
                j += 1
            }
        }
        while i < n { removed.append(old[i]); i += 1 }
        while j < m { added.append(new[j]); j += 1 }
        return (added, removed)
    }
}

/// Turns the parsed entries back into file text, in the format the file was
/// read in.
public enum Serializer {
    public static func text(for file: SourceFile) -> String {
        switch file.format {
        case .oneLine:
            return APTList.serialize(file.entries)
        case .deb822:
            return Deb822.serialize(file.entries)
        }
    }
}

public enum SourcesWriterError: Error, LocalizedError {
    case notPermitted(String)
    case underlying(String, String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted(let path):
            return "Not allowed to write \(path)."
        case .underlying(let path, let message):
            return "Could not write \(path): \(message)"
        }
    }
}

/// Where the bytes go. The app supplies a helper-backed writer on a real device
/// and this one in a simulator; both are validated against the same allow-list
/// of directories.
public protocol SourcesWriter {
    func write(contents: String, to path: String) throws
    func remove(_ path: String) throws
}

/// Writes directly, as whatever user the process runs as.
public struct DirectWriter: SourcesWriter {
    public init() {}

    public func write(contents: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw SourcesWriterError.underlying(path, error.localizedDescription)
        }
    }

    public func remove(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            return
        } catch {
            throw SourcesWriterError.underlying(path, error.localizedDescription)
        }
    }
}

public enum PlanApplier {

    /// Applies a plan in path order and returns a log line per change.
    /// Deletions run after writes so a rename (delete A, create B) leaves a
    /// working file on disk even if the second step fails.
    public static func apply(_ plan: ApplyPlan, with writer: SourcesWriter) throws -> [String] {
        var log: [String] = []
        let ordered = plan.writes.sorted { lhs, rhs in
            if (lhs.action == .delete) != (rhs.action == .delete) { return rhs.action == .delete }
            return lhs.path < rhs.path
        }
        for write in ordered {
            switch write.action {
            case .create, .modify:
                guard let contents = write.contents else { continue }
                try writer.write(contents: contents, to: write.path)
                log.append("\(write.action.displayName)d \(write.path)")
            case .delete:
                try writer.remove(write.path)
                log.append("Removed \(write.path)")
            }
        }
        return log
    }
}
