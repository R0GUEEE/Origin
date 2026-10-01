import Foundation

/// A single APT source, as the user thinks of it: one repository URL with the
/// distributions and components taken from it.
///
/// APT has two on-disk spellings of this (`deb <uri> <suite> <components>` and
/// the deb822 `.sources` stanza) and Cydia-era tools additionally mark a source
/// "disabled" by prefixing the line with `#`. All three are modelled here so a
/// file can be read, edited and written back without changing anything the user
/// did not touch.
public struct Repository: Hashable, Codable, Identifiable, Sendable {

    /// `deb` or `deb-src`.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case deb
        case debSrc = "deb-src"
    }

    public var url: String
    public var suites: [String]
    public var components: [String]
    public var kinds: [Kind]
    public var architectures: [String]
    public var enabled: Bool
    /// Free-text note shown in the UI. Written above the entry where the format
    /// allows it, and kept out of the apt data otherwise.
    public var comment: String?
    /// Fields of a deb822 stanza we do not model. Kept so an edit does not drop
    /// a field apt understands but we do not.
    public var extraFields: [String: String]
    /// Name of the file this entry was read from (informational only).
    public var file: String?

    public init(
        url: String,
        suites: [String] = ["./"],
        components: [String] = [],
        kinds: [Kind] = [.deb],
        architectures: [String] = [],
        enabled: Bool = true,
        comment: String? = nil,
        extraFields: [String: String] = [:],
        file: String? = nil
    ) {
        self.url = url
        self.suites = suites
        self.components = components
        self.kinds = kinds
        self.architectures = architectures
        self.enabled = enabled
        self.comment = comment
        self.extraFields = extraFields
        self.file = file
    }

    /// Stable identity for diffing: the URL plus the suites taken from it.
    /// Components and options are deliberately not part of it — switching a
    /// repository between `main` and `main contrib` is an edit, not a new repo.
    public var id: String {
        "\(url)|\(suites.joined(separator: ","))"
    }

    /// `repo.example.com` — what the list shows as the title.
    public var host: String {
        Repository.host(of: url)
    }

    /// The suite, or `./` when there is none — what the list shows as the
    /// subtitle next to the host.
    public var suiteLabel: String {
        suites.isEmpty ? "./" : suites.joined(separator: " ")
    }

    /// Everything after the host, for a disambiguating second line.
    public var pathLabel: String {
        guard let range = url.range(of: "://") else { return url }
        let rest = url[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return "" }
        return String(rest[slash...])
    }

    public static func host(of url: String) -> String {
        var s = url
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[s.startIndex..<slash]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        return s
    }

    public var isDebSrcOnly: Bool {
        !kinds.isEmpty && kinds.allSatisfy { $0 == .debSrc }
    }
}

/// One entry in a sources file. Comments and blank lines are modelled rather
/// than dropped, because a source file is usually hand-edited and the app has
/// no business reflowing lines it was not asked to change.
public enum SourceEntry: Hashable, Sendable {
    case blank
    case comment(String)
    case repository(Repository)
    /// A deb822 stanza we do not understand, kept verbatim.
    case rawStanza(String)
}

/// On-disk spelling of a sources file.
public enum SourceFormat: String, Hashable, Sendable {
    /// `deb https://repo.example.com/ ./`
    case oneLine
    /// `Types: deb` / `URIs: …` stanzas, as used by Sileo and apt 2.x.
    case deb822
}

/// A sources file that Origin knows how to read and write.
public struct SourceFile: Hashable, Sendable {
    /// Absolute path on disk.
    public var path: String
    /// File name, used as the title in the UI.
    public var name: String
    public var format: SourceFormat
    public var entries: [SourceEntry]
    /// Exactly what was on disk when this was read. Used to skip writes that
    /// would not change anything, and to refuse to overwrite a file that was
    /// modified by something else in the meantime.
    public var originalText: String

    public init(path: String, name: String, format: SourceFormat, entries: [SourceEntry], originalText: String) {
        self.path = path
        self.name = name
        self.format = format
        self.entries = entries
        self.originalText = originalText
    }

    public var repositories: [Repository] {
        entries.compactMap { entry in
            if case .repository(let repo) = entry { return repo }
            return nil
        }
    }

    /// A file with no repositories left is deleted rather than left behind as
    /// an empty stub — unless it is one the jailbreak itself ships.
    public var hasContent: Bool {
        !repositories.isEmpty || entries.contains { entry in
            switch entry {
            case .comment, .rawStanza: return true
            case .blank, .repository: return false
            }
        }
    }

    public func repository(id: String) -> Repository? {
        repositories.first { $0.id == id }
    }

    public func contains(id: String) -> Bool {
        repository(id: id) != nil
    }

    public mutating func append(_ repository: Repository) {
        if entries.isEmpty || !isBlank(entries[entries.count - 1]) {
            entries.append(.blank)
        }
        entries.append(.repository(repository))
    }

    public mutating func remove(id: String) {
        entries.removeAll { entry in
            if case .repository(let repo) = entry { return repo.id == id }
            return false
        }
        trimTrailingBlankLines()
    }

    public mutating func replace(_ repository: Repository) {
        for index in entries.indices {
            if case .repository(let existing) = entries[index], existing.id == repository.id {
                entries[index] = .repository(repository)
                return
            }
        }
        append(repository)
    }

    public mutating func setEnabled(_ enabled: Bool, id: String) {
        guard var repo = repository(id: id) else { return }
        repo.enabled = enabled
        replace(repo)
    }

    private func isBlank(_ entry: SourceEntry) -> Bool {
        if case .blank = entry { return true }
        return false
    }

    private mutating func trimTrailingBlankLines() {
        while let last = entries.last, isBlank(last) {
            entries.removeLast()
        }
    }
}
