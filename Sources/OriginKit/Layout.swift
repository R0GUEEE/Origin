import Foundation

/// Where a jailbreak keeps its APT configuration, on a rootless jailbreak
/// (`/var/jb` prefix) or a rootful one (no prefix).
///
/// Every path Origin touches comes from here, so the difference between the two
/// layouts lives in exactly one place instead of being sprinkled through the app
/// as string literals — which is the failure mode that made the original app
/// need a separately compiled binary per jailbreak type.
public struct JailbreakLayout: Hashable, Sendable {

    public enum Style: String, Hashable, Sendable, CaseIterable {
        case rootless
        case rootful

        public var displayName: String {
            switch self {
            case .rootless: return "Rootless"
            case .rootful: return "Rootful"
            }
        }

        public var aptArchitecture: String {
            switch self {
            case .rootless: return "iphoneos-arm64"
            case .rootful: return "iphoneos-arm"
            }
        }
    }

    public let style: Style
    /// Empty for rootful, `/var/jb` for rootless.
    public let root: String

    public init(style: Style) {
        self.style = style
        self.root = (style == .rootless) ? "/var/jb" : ""
    }

    public static func detect(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> JailbreakLayout {
        if let forced = environment["ORIGIN_LAYOUT"]?.lowercased() {
            if forced == "rootful" { return JailbreakLayout(style: .rootful) }
            if forced == "rootless" { return JailbreakLayout(style: .rootless) }
        }
        // A rootless bootstrap always has /var/jb; a rootful one never does.
        if fileExists("/var/jb/usr/bin/dpkg") || fileExists("/var/jb") {
            return JailbreakLayout(style: .rootless)
        }
        return JailbreakLayout(style: .rootful)
    }

    private func joined(_ path: String) -> String { root + path }

    // APT

    public var aptDirectory: String { joined("/etc/apt") }
    public var aptSourcesDirectory: String { joined("/etc/apt/sources.list.d") }
    public var sileoSourcesDirectory: String { joined("/etc/apt/sileo.list.d") }
    public var mainSourcesList: String { joined("/etc/apt/sources.list") }
    public var aptListsDirectory: String { joined("/var/lib/apt/lists") }
    public var aptGetPath: String { joined("/usr/bin/apt-get") }
    public var dpkgPath: String { joined("/usr/bin/dpkg") }

    /// Directories Origin reads and writes.
    public var sourcesDirectories: [String] { [aptSourcesDirectory, sileoSourcesDirectory] }

    /// Every path Origin is ever allowed to write. The setuid helper validates
    /// its arguments against this same list, so the app cannot be talked into
    /// writing something else.
    public var writableDirectories: [String] { [aptSourcesDirectory, sileoSourcesDirectory] }

    // Other package managers that keep their own copy of the source list.

    public var zebraDirectory: String { "/var/mobile/Library/Application Support/xyz.willy.Zebra" }
    public var zebraSourcesList: String { zebraDirectory + "/sources.list" }
    public var installerSourcesList: String { "/var/mobile/Library/Application Support/Installer/SourcesFiles" }

    // Origin's own state.

    public var stateDirectory: String { "/var/mobile/Library/Origin" }
    public var backupDirectory: String { stateDirectory + "/Backups" }
    public var helperPath: String { joined("/usr/libexec/origin/origin-helper") }

    // Refreshing the UI after a change.

    public var respringPaths: [String] {
        [joined("/usr/bin/sbreload"), joined("/usr/bin/killall")]
    }
}
