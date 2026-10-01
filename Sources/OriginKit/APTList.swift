import Foundation

/// Reader and writer for the one-line `sources.list` spelling:
///
///     deb [arch=iphoneos-arm64] https://repo.example.com/ ./
///     #deb https://example.invalid/ ./
///
/// The `#deb` form is not an apt feature — it is the convention Cydia-era
/// managers use for "disabled", and it is what Origin writes when a repository
/// is switched off, so a device that boots without the app still has a valid,
/// inert sources list.
public enum APTList {

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

        let lines = text.normalisedLineEndings().components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                entries.append(.blank)
                continue
            }

            if trimmed.hasPrefix("#") {
                let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if isDebLine(body) {
                    if let repo = parseDebLine(body, enabled: false, file: nil) {
                        entries.append(.repository(repo))
                    } else {
                        issues.append(.init(line: lineNumber, text: trimmed, message: "could not read the disabled entry"))
                        entries.append(.comment(trimmed))
                    }
                } else {
                    entries.append(.comment(trimmed))
                }
                continue
            }

            if isDebLine(trimmed) {
                if let repo = parseDebLine(trimmed, enabled: true, file: nil) {
                    entries.append(.repository(repo))
                } else {
                    issues.append(.init(line: lineNumber, text: trimmed, message: "could not read this entry"))
                    entries.append(.comment(trimmed))
                }
                continue
            }

            // Anything else (an apt option line, a stray word) is preserved
            // verbatim so writing the file back does not change it.
            issues.append(.init(line: lineNumber, text: trimmed, message: "not a source line; kept as-is"))
            entries.append(.comment(trimmed))
        }

        return (entries, issues)
    }

    static func isDebLine(_ s: String) -> Bool {
        s == "deb" || s == "deb-src"
            || s.hasPrefix("deb ") || s.hasPrefix("deb\t")
            || s.hasPrefix("deb-src ") || s.hasPrefix("deb-src\t")
    }

    /// Parses the part after an optional leading `#`.
    public static func parseDebLine(_ body: String, enabled: Bool, file: String?) -> Repository? {
        var tokens = tokenize(body)
        guard !tokens.isEmpty else { return nil }

        var kinds: [Repository.Kind] = []
        while let first = tokens.first, first == "deb" || first == "deb-src" {
            kinds.append(first == "deb" ? .deb : .debSrc)
            tokens.removeFirst()
        }
        guard !kinds.isEmpty else { return nil }

        var options: [String: String] = [:]
        if let first = tokens.first, first.hasPrefix("[") {
            var collected = ""
            while !tokens.isEmpty {
                let token = tokens.removeFirst()
                collected += token
                if token.hasSuffix("]") { break }
            }
            let inner = collected.hasPrefix("[") ? String(collected.dropFirst()) : collected
            let withoutBracket = inner.hasSuffix("]") ? String(inner.dropLast()) : inner
            for pair in withoutBracket.split(separator: " ").map(String.init) {
                guard let equals = pair.firstIndex(of: "=") else {
                    options[pair] = ""
                    continue
                }
                let key = String(pair[pair.startIndex..<equals]).lowercased()
                let value = String(pair[pair.index(after: equals)...])
                options[key] = value
            }
        }

        guard !tokens.isEmpty else { return nil }
        let url = tokens.removeFirst()
        guard !tokens.isEmpty else { return nil }
        let suite = tokens.removeFirst()
        let components = tokens

        var architectures: [String] = []
        if let arch = options.removeValue(forKey: "arch") ?? options.removeValue(forKey: "architecture") {
            architectures = arch.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        return Repository(
            url: url,
            suites: [suite],
            components: components,
            kinds: kinds,
            architectures: architectures,
            enabled: enabled,
            comment: nil,
            extraFields: options,
            file: file
        )
    }

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var bracketDepth = 0
        for character in s {
            switch character {
            case "[":
                bracketDepth += 1
                current.append(character)
            case "]":
                if bracketDepth > 0 { bracketDepth -= 1 }
                current.append(character)
            case " ", "\t":
                if bracketDepth > 0 {
                    current.append(character)
                } else if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Writing

    public static func serialize(_ entries: [SourceEntry]) -> String {
        entries.map(line(for:)).joined(separator: "\n") + "\n"
    }

    public static func line(for entry: SourceEntry) -> String {
        switch entry {
        case .blank:
            return ""
        case .comment(let text):
            return text
        case .rawStanza(let text):
            return text
        case .repository(let repo):
            return line(for: repo)
        }
    }

    public static func line(for repo: Repository) -> String {
        var parts: [String] = repo.kinds.map { $0 == .deb ? "deb" : "deb-src" }
        if parts.isEmpty { parts = ["deb"] }

        var options: [String] = []
        if !repo.architectures.isEmpty {
            options.append("arch=\(repo.architectures.joined(separator: ","))")
        }
        for key in repo.extraFields.keys.sorted() {
            let value = repo.extraFields[key] ?? ""
            options.append(value.isEmpty ? key : "\(key)=\(value)")
        }
        if !options.isEmpty {
            parts.append("[\(options.joined(separator: " "))]")
        }

        parts.append(repo.url)
        parts.append(contentsOf: repo.suites.isEmpty ? ["./"] : repo.suites)
        parts.append(contentsOf: repo.components)

        let body = parts.joined(separator: " ")
        return repo.enabled ? body : "#\(body)"
    }
}

extension String {
    /// Swift treats "\r\n" as a *single* grapheme cluster, so splitting on "\n"
    /// silently fails to see a CRLF line ending and the whole file parses as one
    /// enormous line. Normalise first; the `utf8.contains` guard keeps the
    /// common LF-only path allocation-free.
    public func normalisedLineEndings() -> String {
        guard utf8.contains(13) else { return self }
        return replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
