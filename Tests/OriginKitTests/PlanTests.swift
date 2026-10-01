import XCTest
@testable import OriginKit

final class ValidatorTests: XCTestCase {

    func testAcceptsAWellFormedRepository() {
        let repository = Repository(url: "https://repo.example.com/", suites: ["./"], components: [])
        XCTAssertTrue(Validator.errors(for: repository).isEmpty)
        XCTAssertTrue(Validator.issues(for: repository).isEmpty)
    }

    func testRejectsMissingScheme() {
        let repository = Repository(url: "repo.example.com", suites: ["./"])
        XCTAssertTrue(Validator.errors(for: repository).isEmpty, "a missing scheme is a warning, not an error")
        XCTAssertTrue(Validator.issues(for: repository).contains { $0.severity == .warning && $0.field == .url })
    }

    func testRejectsSpacesInURL() {
        let repository = Repository(url: "https://repo example.com/", suites: ["./"])
        XCTAssertFalse(Validator.errors(for: repository).isEmpty)
    }

    func testRejectsEmptySuite() {
        let repository = Repository(url: "https://a.example.com/", suites: [])
        XCTAssertTrue(Validator.errors(for: repository).contains { $0.field == .suite })
    }

    func testWarnsWhenNonFlatRepositoryHasNoComponent() {
        let repository = Repository(url: "https://a.example.com/", suites: ["stable"], components: [])
        XCTAssertTrue(Validator.issues(for: repository).contains { $0.field == .component && $0.severity == .warning })
    }

    func testNoComponentWarningForFlatRepository() {
        let repository = Repository(url: "https://a.example.com/", suites: ["./"], components: [])
        XCTAssertFalse(Validator.issues(for: repository).contains { $0.field == .component })
    }

    func testNormalisesURL() {
        XCTAssertEqual(Validator.normalised(url: "repo.example.com"), "https://repo.example.com/")
        XCTAssertEqual(Validator.normalised(url: "https://repo.example.com"), "https://repo.example.com/")
        XCTAssertEqual(Validator.normalised(url: "https://repo.example.com/"), "https://repo.example.com/")
    }

    func testHostExtraction() {
        XCTAssertEqual(Repository.host(of: "https://user@repo.example.com/path"), "repo.example.com")
        XCTAssertEqual(Repository.host(of: "http://repo.example.com"), "repo.example.com")
    }
}

final class PlannerTests: XCTestCase {

    private func file(_ name: String, _ text: String) -> SourceFile {
        var parsed = SourceStore.parse(text: text, path: "/etc/apt/sources.list.d/" + name, name: name)
        parsed.originalText = text
        return parsed
    }

    func testUnchangedFileProducesNoPlan() {
        let source = file("origin.sources", Deb822.stanza(for: Repository(url: "https://a.example.com/")) + "\n")
        XCTAssertTrue(Planner.plan(files: [source]).isEmpty)
    }

    func testAddingARepositoryModifiesTheFile() {
        var source = file("origin.sources", Deb822.stanza(for: Repository(url: "https://a.example.com/")) + "\n")
        source.append(Repository(url: "https://b.example.com/"))
        let plan = Planner.plan(files: [source])
        XCTAssertEqual(plan.modified, 1)
        XCTAssertEqual(plan.created, 0)
        XCTAssertTrue(plan.writes[0].addedLines.contains { $0.contains("b.example.com") })
    }

    func testEmptyingAFileDeletesIt() {
        var source = file("origin.list", "deb https://a.example.com/ ./\n")
        source.remove(id: Repository(url: "https://a.example.com/").id)
        let plan = Planner.plan(files: [source])
        XCTAssertEqual(plan.deleted, 1)
        XCTAssertEqual(plan.writes[0].action, .delete)
    }

    func testAFileThatNeverExistedIsNotDeleted() {
        var source = SourceFile(path: "/etc/apt/sources.list.d/new.list", name: "new.list", format: .oneLine, entries: [], originalText: "")
        source.remove(id: "nothing")
        XCTAssertTrue(Planner.plan(files: [source]).isEmpty)
    }

    func testCommentsSurviveAnEdit() {
        var source = file("origin.list", "# keep me\ndeb https://a.example.com/ ./\n")
        source.append(Repository(url: "https://b.example.com/"))
        let plan = Planner.plan(files: [source])
        XCTAssertTrue(plan.writes[0].contents?.contains("# keep me") == true)
    }

    func testDiffReportsAddedAndRemovedLines() {
        let result = Planner.diff(old: ["a", "b", "c"], new: ["a", "c", "d"])
        XCTAssertEqual(result.added, ["d"])
        XCTAssertEqual(result.removed, ["b"])
    }

    func testApplyingAPlanIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var source = SourceFile(
            path: directory.path + "/origin.sources",
            name: "origin.sources",
            format: .deb822,
            entries: [],
            originalText: ""
        )
        source.append(Repository(url: "https://a.example.com/"))

        let first = Planner.plan(files: [source])
        XCTAssertEqual(first.created, 1)
        _ = try PlanApplier.apply(first, with: DirectWriter())

        var reread = SourceStore.parse(
            text: try String(contentsOfFile: source.path, encoding: .utf8),
            path: source.path,
            name: "origin.sources"
        )
        reread.originalText = try String(contentsOfFile: source.path, encoding: .utf8)
        XCTAssertTrue(Planner.plan(files: [reread]).isEmpty, "applying twice must be a no-op")
    }
}

final class BackupTests: XCTestCase {

    func testBackupRoundTripAndRestorePlan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let backups = BackupStore(directory: directory.path)
        let original = SourceStore.parse(
            text: "deb https://a.example.com/ ./\n",
            path: "/etc/apt/sources.list.d/a.list",
            name: "a.list"
        )
        let snapshot = backups.makeBackup(of: [original], label: "test", layout: "rootless")
        XCTAssertEqual(snapshot.files.count, 1)
        let saved = try backups.save(snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved))

        XCTAssertEqual(backups.list().count, 1)
        XCTAssertEqual(backups.paths().count, 1)
        XCTAssertEqual(backups.load(path: saved)?.label, "test")

        let changed = SourceStore.parse(
            text: "deb https://b.example.com/ ./\n",
            path: "/etc/apt/sources.list.d/a.list",
            name: "a.list"
        )
        let plan = backups.plan(restoring: snapshot, currentFiles: [changed])
        XCTAssertEqual(plan.modified, 1)
        XCTAssertTrue(plan.writes[0].contents?.contains("a.example.com") == true)
    }

    func testRestoreDeletesFilesAddedAfterTheBackup() {
        let backups = BackupStore(directory: "/tmp/does-not-matter")
        let snapshot = SourceBackup(label: "x", layout: "rootless", files: [
            BackupFile(path: "/etc/apt/sources.list.d/a.list", contents: "deb https://a.example.com/ ./\n")
        ])
        let added = SourceStore.parse(
            text: "deb https://new.example.com/ ./\n",
            path: "/etc/apt/sources.list.d/new.list",
            name: "new.list"
        )
        let plan = backups.plan(restoring: snapshot, currentFiles: [added])
        XCTAssertEqual(plan.deleted, 1)
    }
}

final class SubprocessTests: XCTestCase {

    func testCapturesOutputAndStatus() throws {
        let result = try Subprocess.run(executable: "/bin/echo", arguments: ["hello"])
        XCTAssertTrue(result.succeeded, "status \(result.status): \(result.output)")
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testReportsANonZeroExitStatus() throws {
        let result = try Subprocess.run(executable: "/bin/sh", arguments: ["-c", "exit 3"])
        XCTAssertEqual(result.status, 3)
    }

    func testMissingExecutableThrows() {
        XCTAssertThrowsError(try Subprocess.run(executable: "/nonexistent/definitely-not-here"))
    }
}
