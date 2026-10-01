import Foundation

/// Reader and writer for the deb822 `.sources` spelling used by Sileo and
/// apt 2.x:
///
///     Types: deb
///     URIs: https://repo.example.com/
///     Suites: ./
///     Components:
///     Enabled: yes
///
/// Multi-line values (a continuation line begins with a space) are folded, and
/// a field Origin does not model is carried through untouched.
public enum Deb822 {

    public struct ParseIssue: Hashable, Sendable, CustomStringConvertible {
        public var line: Int
        public var text: String
        public var message: String
        public var description: String { "line \(line): \(message) [\(text)]" }
    }

    // MARK: - Reading

    public static func parse(_ text: String) -> (entries: [SourceEntry], issues: [ParseIssue]) {
        var entries: [SourceEntry] = []
        var issues: [ParseIssue] = []

        var stanza: [(key: String, value: String)] = []
        var stanzaStartLine = 0
        var lastKey: String?

        func flush() {
            guard !stanza.isEmpty else { return }
            switch entry(from: stanza) {
            case .repository(let repo):
                entries.append(.repository(repo))
            case .raw(let raw):
                issues.append(.init(
                    line: stanzaStartLine,
                    text: raw.split(separator: "\n").first.map(String.init) ?? "",
                    message: "stanza without URIs or Suites; kept as-is"
                ))
                entries.append(.rawStanza(raw))
            case .none:
                entries.append(.blank)
            }
            stanza = []
            lastKey = nil
        }

        let lines = text.normalisedLineEndings().components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmedRight = rawLine.isEmpty ? rawLine : String(rawLine.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())

            if trimmedRight.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                if entries.last != .blank { entries.append(.blank) }
                continue
            }

            if trimmedRight.hasPrefix("#") {
                flush()
                entries.append(.comment(trimmedRight.trimmingCharacters(in: .whitespaces)))
                continue
            }

            if trimmedRight.hasPrefix(" ") || trimmedRight.hasPrefix("\t") {
                guard let key = lastKey, !stanza.isEmpty else {
                    issues.append(.init(line: lineNumber, text: trimmedRight, message: "continuation line without a field"))
                    continue
                }
                let value = trimmedRight.trimmingCharacters(in: .whitespaces)
                let last = stanza.count - 1
                stanza[last].value += stanza[last].value.isEmpty ? value : "\n" + value
                _ = key
                continue
            }

            guard let colon = trimmedRight.firstIndex(of: ":") else {
                issues.append(.init(line: lineNumber, text: trimmedRight, message: "line is not a deb822 field"))
                continue
            }

            if stanza.isEmpty { stanzaStartLine = lineNumber }
            let key = String(trimmedRight[trimmedRight.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmedRight[trimmedRight.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            stanza.append((key: key, value: value))
            lastKey = key
        }

        flush()
        // A file ends with a newline, so the split produced one trailing empty
        // line; drop the blank entry it became rather than growing the file by a
        // line on every save.
        while let last = entries.last, last == .blank { entries.removeLast() }

        return (entries, issues)
    }

    private enum StanzaOutcome {
        case repository(Repository)
        case raw(String)
        case none
    }

    private static func entry(from stanza: [(key: String, value: String)]) -> StanzaOutcome {
        // Field names are matched case-insensitively (apt accepts `URIs:` and
        // `uris:` alike) but remembered in the spelling the file used, so a
        // field Origin does not model comes back out looking the way its author
        // wrote it rather than lower-cased by us.
        var values: [String: String] = [:]
        var spellings: [String: String] = [:]
        var order: [String] = []
        for field in stanza {
            let key = field.key.lowercased()
            if values[key] != nil { continue }
            values[key] = field.value
            spellings[key] = field.key
            order.append(key)
        }

        guard let uris = values["uris"], !uris.isEmpty else {
            return .raw(stanza.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        }

        let url = uris.split(separator: "\n").first.map(String.init) ?? uris
        let suites = split(values["suites"] ?? "")
        let components = split(values["components"] ?? "")
        let types = split(values["types"] ?? "deb").map { Repository.Kind(rawValue: $0) ?? .deb }
        let architectures = split(values["architectures"] ?? "")
        let enabled = (values["enabled"]?.lowercased() ?? "yes") != "no"

        var extra: [String: String] = [:]
        let modelled: Set<String> = ["uris", "suites", "components", "types", "architectures", "enabled"]
        for key in order where !modelled.contains(key) {
            extra[spellings[key] ?? key] = values[key] ?? ""
        }

        return .repository(Repository(
            url: url,
            suites: suites.isEmpty ? ["./"] : suites,
            components: components,
            kinds: types.isEmpty ? [.deb] : types,
            architectures: architectures,
            enabled: enabled,
            comment: nil,
            extraFields: extra,
            file: nil
        ))
    }

    private static func split(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    // MARK: - Writing

    public static func serialize(_ entries: [SourceEntry]) -> String {
        var chunks: [String] = []
        for entry in entries {
            switch entry {
            case .blank:
                continue // blank lines are re-inserted between stanzas below
            case .comment(let text):
                chunks.append(text)
            case .rawStanza(let text):
                chunks.append(text)
            case .repository(let repo):
                chunks.append(stanza(for: repo))
            }
        }
        return chunks.joined(separator: "\n\n") + "\n"
    }

    public static func stanza(for repo: Repository) -> String {
        var lines: [String] = ["Types: " + repo.kinds.map { $0.rawValue }.joined(separator: " ")]
        lines.append("URIs: \(repo.url)")
        lines.append("Suites: " + (repo.suites.isEmpty ? "./" : repo.suites.joined(separator: " ")))
        lines.append("Components: " + repo.components.joined(separator: " "))
        if !repo.architectures.isEmpty {
            lines.append("Architectures: " + repo.architectures.joined(separator: " "))
        }
        for key in repo.extraFields.keys.sorted() {
            lines.append("\(key): \(repo.extraFields[key] ?? "")")
        }
        lines.append("Enabled: \(repo.enabled ? "yes" : "no")")
        return lines.joined(separator: "\n")
    }
}
