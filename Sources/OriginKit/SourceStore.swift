import Foundation

public struct LoadedSources: Sendable {
    public var files: [SourceFile]
    public var issues: [String]
    public var scannedDirectories: [String]

    public init(files: [SourceFile] = [], issues: [String] = [], scannedDirectories: [String] = []) {
        self.files = files
        self.issues = issues
        self.scannedDirectories = scannedDirectories
    }

    public var repositories: [Repository] {
        files.flatMap { $0.repositories }
    }

    public var fileNames: [String] { files.map { $0.name } }
}

/// Reads and writes the sources files a package manager actually uses.
public struct SourceStore {

    public let layout: JailbreakLayout
    private let fileManager: FileManager

    public init(layout: JailbreakLayout, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    // MARK: - Reading

    public func load() -> LoadedSources {
        var files: [SourceFile] = []
        var issues: [String] = []
        var scanned: [String] = []

        for directory in layout.sourcesDirectories {
            scanned.append(directory)
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for name in names.sorted() where SourceStore.isSourcesFile(name) {
                let path = directory + "/" + name
                if let file = readFile(at: path) {
                    files.append(file)
                } else {
                    issues.append("Could not read \(path)")
                }
            }
        }

        return LoadedSources(files: files, issues: issues, scannedDirectories: scanned)
    }

    public static func isSourcesFile(_ name: String) -> Bool {
        name.hasSuffix(".list") || name.hasSuffix(".sources")
    }

    public func readFile(at path: String) -> SourceFile? {
        guard let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let name = (path as NSString).lastPathComponent
        return SourceStore.parse(text: text, path: path, name: name)
    }

    public static func parse(text: String, path: String, name: String) -> SourceFile {
        let format = detectFormat(text: text, name: name)
        var (entries, _) = parseEntries(text: text, format: format)

        // Tag every repository with the file it lives in, so the UI can say
        // where an entry came from and the editor can move it if it has to.
        for index in entries.indices {
            if case .repository(var repo) = entries[index] {
                repo.file = name
                entries[index] = .repository(repo)
            }
        }

        return SourceFile(path: path, name: name, format: format, entries: entries, originalText: text)
    }

    public static func parseEntries(text: String, format: SourceFormat) -> (entries: [SourceEntry], issues: [String]) {
        switch format {
        case .oneLine:
            let result = APTList.parse(text)
            return (result.entries, result.issues.map { $0.description })
        case .deb822:
            let result = Deb822.parse(text)
            return (result.entries, result.issues.map { $0.description })
        }
    }

    /// The extension is the primary signal, and a file that says `URIs:` is
    /// deb822 whatever it is called — Sileo names its files `.sources` but a
    /// hand-renamed one still has to work.
    public static func detectFormat(text: String, name: String) -> SourceFormat {
        if name.hasSuffix(".sources") { return .deb822 }
        if name.hasSuffix(".list") {
            return containsDeb822Marker(text) ? .deb822 : .oneLine
        }
        return containsDeb822Marker(text) ? .deb822 : .oneLine
    }

    static func containsDeb822Marker(_ text: String) -> Bool {
        for rawLine in text.normalisedLineEndings().components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            return line.lowercased().hasPrefix("uris:") || line.lowercased().hasPrefix("types:")
        }
        return false
    }

    // MARK: - Writing

    /// Where a newly added repository goes by default.
    public func defaultTargetPath() -> String {
        layout.aptSourcesDirectory + "/origin.sources"
    }

    public func path(for name: String, preferredFormat: SourceFormat) -> String {
        let directory = layout.aptSourcesDirectory
        let suffix = preferredFormat == .deb822 ? ".sources" : ".list"
        return directory + "/" + (name.hasSuffix(suffix) ? name : name + suffix)
    }

    public func makeFile(named name: String, format: SourceFormat) -> SourceFile {
        SourceFile(
            path: path(for: name, preferredFormat: format),
            name: name.hasSuffix(format == .deb822 ? ".sources" : ".list")
                ? name
                : name + (format == .deb822 ? ".sources" : ".list"),
            format: format,
            entries: [],
            originalText: ""
        )
    }

    public func plan(for files: [SourceFile], deleteEmptyFiles: Bool = true) -> ApplyPlan {
        Planner.plan(files: files, deleteEmptyFiles: deleteEmptyFiles)
    }
}
