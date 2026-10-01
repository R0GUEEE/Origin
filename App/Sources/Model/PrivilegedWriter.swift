import Foundation
import OriginKit

/// Writes sources files through the setuid-root helper.
///
/// The app runs as `mobile` and the files live in `/var/jb/etc/apt` (rootless)
/// or `/etc/apt` (rootful), so the app cannot write them itself. Everything it
/// asks for goes through `origin-helper`, which re-validates the path and the
/// contents before touching anything.
struct PrivilegedWriter: SourcesWriter, Sendable {
    let layout: JailbreakLayout

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: layout.helperPath)
    }

    func write(contents: String, to path: String) throws {
        guard isAvailable else { throw SourcesWriterError.notPermitted(path) }

        // The helper reads a file rather than argv, so the contents never travel
        // through a command line. The staging file is transient and is removed
        // however this returns.
        let staged = NSTemporaryDirectory() + "origin-stage-\(UUID().uuidString).sources"
        do {
            try contents.write(toFile: staged, atomically: true, encoding: .utf8)
        } catch {
            throw SourcesWriterError.underlying(path, error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(atPath: staged) }

        let result = try Subprocess.run(executable: layout.helperPath, arguments: ["install", staged, path])
        guard result.succeeded else {
            throw SourcesWriterError.underlying(path, Self.message(from: result))
        }
    }

    func remove(_ path: String) throws {
        guard isAvailable else { throw SourcesWriterError.notPermitted(path) }
        let result = try Subprocess.run(executable: layout.helperPath, arguments: ["remove", path])
        guard result.succeeded else {
            throw SourcesWriterError.underlying(path, Self.message(from: result))
        }
    }

    private static func message(from result: Subprocess.Result) -> String {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "origin-helper exited \(result.status)" : output
    }
}
