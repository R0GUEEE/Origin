import Foundation

public enum ValidationSeverity: String, Hashable, Sendable {
    case error
    case warning
}

public struct ValidationIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Field: String, Hashable, Sendable {
        case url
        case suite
        case component
        case architecture
        case kinds
    }

    public var severity: ValidationSeverity
    public var field: Field
    public var message: String

    public init(severity: ValidationSeverity, field: Field, message: String) {
        self.severity = severity
        self.field = field
        self.message = message
    }

    public var description: String { "\(field.rawValue): \(message)" }
}

/// Checks a repository *before* it reaches a sources file.
///
/// A malformed line is worse than a rejected one: apt refuses to read the whole
/// file, so every other repository in it disappears from the package managers.
/// That is why the checks are strict and run on every keystroke in the editor.
public enum Validator {

    public static func issues(for repository: Repository) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        let url = repository.url.trimmingCharacters(in: .whitespaces)
        if url.isEmpty {
            issues.append(.init(severity: .error, field: .url, message: "Enter a repository URL."))
        } else if url.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            issues.append(.init(severity: .error, field: .url, message: "A URL cannot contain spaces."))
        } else if url.contains("#") {
            issues.append(.init(severity: .error, field: .url, message: "A URL cannot contain '#'."))
        } else if !hasScheme(url) {
            issues.append(.init(severity: .warning, field: .url, message: "No scheme; the app will use https://."))
        } else if !isSupportedScheme(url) {
            issues.append(.init(severity: .error, field: .url, message: "Only http, https and file URLs are supported."))
        } else if Repository.host(of: url).isEmpty {
            issues.append(.init(severity: .error, field: .url, message: "This URL has no host."))
        } else if !url.contains("://") || !url.hasSuffix("/") {
            issues.append(.init(severity: .warning, field: .url, message: "Repository URLs normally end with '/'."))
        }

        if repository.kinds.isEmpty {
            issues.append(.init(severity: .error, field: .kinds, message: "Select deb, deb-src, or both."))
        }

        if repository.suites.isEmpty || repository.suites.allSatisfy({ $0.isEmpty }) {
            issues.append(.init(severity: .error, field: .suite, message: "A suite is required (use ./ for a flat repository)."))
        } else if repository.suites.contains(where: { $0.contains(where: { $0 == " " || $0 == "\t" }) || $0.hasPrefix("[") }) {
            issues.append(.init(severity: .error, field: .suite, message: "A suite cannot contain spaces or start with '['."))
        }

        if repository.components.isEmpty {
            if !repository.suites.allSatisfy(isFlat) {
                issues.append(.init(severity: .warning, field: .component, message: "Non-flat repositories usually name at least one component."))
            }
        } else if repository.components.contains(where: { $0.contains(where: { $0 == " " || $0 == "\t" }) || $0.hasPrefix("[") || $0.contains("/") }) {
            issues.append(.init(severity: .error, field: .component, message: "A component cannot contain spaces or '/'."))
        }

        for architecture in repository.architectures where !isValidArchitecture(architecture) {
            issues.append(.init(severity: .warning, field: .architecture, message: "'\(architecture)' does not look like an iPhone architecture."))
        }

        return issues
    }

    public static func errors(for repository: Repository) -> [ValidationIssue] {
        issues(for: repository).filter { $0.severity == .error }
    }

    public static func isValid(_ repository: Repository) -> Bool {
        errors(for: repository).isEmpty
    }

    public static func isFlat(_ suite: String) -> Bool {
        let s = suite.trimmingCharacters(in: .whitespaces)
        return s == "." || s == "./" || s.hasSuffix("/")
    }

    static func hasScheme(_ url: String) -> Bool {
        guard let range = url.range(of: "://") else { return false }
        return range.lowerBound != url.startIndex
    }

    static func isSupportedScheme(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://")
    }

    static func isValidArchitecture(_ architecture: String) -> Bool {
        let known: Set<String> = [
            "iphoneos-arm", "iphoneos-arm64", "iphoneos-arm64e",
            "all", "any", "amd64", "arm64", "armhf", "i386",
        ]
        return known.contains(architecture.lowercased()) || architecture.hasSuffix("-arm64")
    }

    /// A URL typed without a scheme is the single most common mistake, and
    /// guessing https is what every other package manager does.
    public static func normalised(url: String) -> String {
        var url = url.trimmingCharacters(in: .whitespaces)
        if !hasScheme(url), !url.isEmpty {
            url = "https://" + url
        }
        if !url.hasSuffix("/"), !url.contains("?") {
            url += "/"
        }
        return url
    }
}
