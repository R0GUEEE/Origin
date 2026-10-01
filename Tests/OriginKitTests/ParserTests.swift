import XCTest
@testable import OriginKit

final class APTListTests: XCTestCase {

    func testParsesEnabledDisabledAndOptions() {
        let text = """
        # Cydia-era header
        deb https://repo.example.com/ ./

        #deb https://disabled.example.com/ ./ 
        deb-src [arch=iphoneos-arm64 trusted=yes] http://src.example.com/ stable main contrib
        """
        let (entries, issues) = APTList.parse(text)

        XCTAssertTrue(issues.isEmpty, "unexpected issues: \(issues)")

        let repositories = entries.compactMap { entry -> Repository? in
            if case .repository(let repo) = entry { return repo }
            return nil
        }
        XCTAssertEqual(repositories.count, 3)

        XCTAssertEqual(repositories[0].url, "https://repo.example.com/")
        XCTAssertTrue(repositories[0].enabled)
        XCTAssertEqual(repositories[0].suites, ["./"])
        XCTAssertEqual(repositories[0].components, [])

        XCTAssertEqual(repositories[1].url, "https://disabled.example.com/")
        XCTAssertFalse(repositories[1].enabled)

        XCTAssertEqual(repositories[2].kinds, [.debSrc])
        XCTAssertEqual(repositories[2].architectures, ["iphoneos-arm64"])
        XCTAssertEqual(repositories[2].extraFields["trusted"], "yes")
        XCTAssertEqual(repositories[2].components, ["main", "contrib"])
    }

    func testPreservesCommentsAndBlankLines() {
        let text = "# header\n\ndeb https://a.example.com/ ./\n"
        let (entries, _) = APTList.parse(text)
        XCTAssertEqual(entries.count, 4)
        if case .comment(let value) = entries[0] { XCTAssertEqual(value, "# header") } else { XCTFail("expected comment") }
        if case .blank = entries[1] {} else { XCTFail("expected blank") }
        if case .repository = entries[2] {} else { XCTFail("expected repository") }
        if case .blank = entries[3] {} else { XCTFail("expected trailing blank") }
    }

    func testRoundTripsExactly() {
        let text = """
        # managed by hand
        deb https://repo.example.com/ ./
        #deb https://off.example.com/ ./
        deb-src [arch=iphoneos-arm64] http://src.example.com/ stable main
        """
        let (entries, _) = APTList.parse(text)
        XCTAssertEqual(APTList.serialize(entries), text + "\n")
    }

    func testCRLFIsNotOneLine() {
        // Swift treats "\r\n" as a single grapheme cluster, so a parser that
        // splits on "\n" without normalising first sees the whole file as one
        // line. This is the regression test for that.
        let text = "deb https://a.example.com/ ./\r\ndeb https://b.example.com/ ./\r\n"
        let (entries, _) = APTList.parse(text)
        let repositories = entries.compactMap { entry -> Repository? in
            if case .repository(let repo) = entry { return repo }
            return nil
        }
        XCTAssertEqual(repositories.count, 2)
        XCTAssertEqual(repositories[1].url, "https://b.example.com/")
    }

    func testDisabledFlagSurvivesAnEdit() {
        var repository = Repository(url: "https://a.example.com/", suites: ["./"], enabled: false)
        XCTAssertTrue(APTList.line(for: repository).hasPrefix("#deb"))
        repository.enabled = true
        XCTAssertTrue(APTList.line(for: repository).hasPrefix("deb "))
    }

    func testOptionsSpanningTokensAreJoined() {
        let (entries, _) = APTList.parse("deb [ arch=iphoneos-arm64 signed-by=/x.gpg ] https://a.example.com/ ./\n")
        let repository = entries.compactMap { entry -> Repository? in
            if case .repository(let repo) = entry { return repo }
            return nil
        }.first
        XCTAssertEqual(repository?.architectures, ["iphoneos-arm64"])
        XCTAssertEqual(repository?.extraFields["signed-by"], "/x.gpg")
    }
}

final class Deb822Tests: XCTestCase {

    let sample = """
    Types: deb
    URIs: https://repo.example.com/
    Suites: ./
    Components:
    Enabled: yes

    Types: deb-src
    URIs: http://src.example.com/
    Suites: stable
    Components: main
    Enabled: no
    """

    func testParsesStanzas() {
        let (entries, issues) = Deb822.parse(sample)
        XCTAssertTrue(issues.isEmpty, "unexpected issues: \(issues)")
        let repositories = entries.compactMap { entry -> Repository? in
            if case .repository(let repo) = entry { return repo }
            return nil
        }
        XCTAssertEqual(repositories.count, 2)
        XCTAssertEqual(repositories[0].url, "https://repo.example.com/")
        XCTAssertEqual(repositories[0].suites, ["./"])
        XCTAssertEqual(repositories[0].components, [])
        XCTAssertTrue(repositories[0].enabled)
        XCTAssertEqual(repositories[1].kinds, [.debSrc])
        XCTAssertEqual(repositories[1].components, ["main"])
        XCTAssertFalse(repositories[1].enabled)
    }

    func testRoundTripsThroughSerialize() {
        let (entries, _) = Deb822.parse(sample)
        let text = Deb822.serialize(entries)
        let (again, _) = Deb822.parse(text)
        let first = entries.compactMap { entry -> Repository? in
            if case .repository(let repo) = entry { return repo }
            return nil
        }
        let second = again.compactMap { entry -> Repository? in
            if case .repository(let repo) = entry { return repo }
            return nil
        }
        XCTAssertEqual(first, second)
    }

    func testKeepsUnknownFields() {
        let text = "Types: deb\nURIs: https://a.example.com/\nSuites: ./\nTargets: iphoneos-arm64\nEnabled: yes\n"
        let (entries, _) = Deb822.parse(text)
        let repository = entries.compactMap { entry -> Repository? in
            if case .repository(let repo) = entry { return repo }
            return nil
        }.first
        XCTAssertEqual(repository?.extraFields["Targets"], "iphoneos-arm64", "the spelling the file used is preserved")
        XCTAssertTrue(Deb822.stanza(for: repository!).contains("Targets: iphoneos-arm64"))
    }

    func testUnreadableStanzaIsPreservedVerbatim() {
        let text = "X-Whatever: 1\nY-Whatever: 2\n"
        let (entries, issues) = Deb822.parse(text)
        XCTAssertEqual(issues.count, 1)
        guard case .rawStanza(let raw) = entries.first else { return XCTFail("expected raw stanza") }
        XCTAssertTrue(raw.contains("X-Whatever: 1"))
        XCTAssertTrue(Deb822.serialize(entries).contains("Y-Whatever: 2"))
    }

    func testFoldsContinuationLines() {
        let text = "Types: deb\nURIs: https://a.example.com/\nSuites: stable\n  oldstable\nComponents: main\nEnabled: yes\n"
        let (entries, _) = Deb822.parse(text)
        let repository = entries.compactMap { entry -> Repository? in
            if case .repository(let repo) = entry { return repo }
            return nil
        }.first
        XCTAssertEqual(repository?.suites, ["stable", "oldstable"])
    }
}

final class LayoutTests: XCTestCase {

    func testDetectsRootlessFromVarJB() {
        let layout = JailbreakLayout.detect(fileExists: { $0 == "/var/jb" }, environment: [:])
        XCTAssertEqual(layout.style, .rootless)
        XCTAssertEqual(layout.aptDirectory, "/var/jb/etc/apt")
        XCTAssertEqual(layout.aptSourcesDirectory, "/var/jb/etc/apt/sources.list.d")
        XCTAssertEqual(layout.style.aptArchitecture, "iphoneos-arm64")
        XCTAssertEqual(layout.helperPath, "/var/jb/usr/libexec/origin/origin-helper")
    }

    func testDetectsRootfulWithoutVarJB() {
        let layout = JailbreakLayout.detect(fileExists: { _ in false }, environment: [:])
        XCTAssertEqual(layout.style, .rootful)
        XCTAssertEqual(layout.aptDirectory, "/etc/apt")
        XCTAssertEqual(layout.aptSourcesDirectory, "/etc/apt/sources.list.d")
        XCTAssertEqual(layout.mainSourcesList, "/etc/apt/sources.list")
        XCTAssertEqual(layout.style.aptArchitecture, "iphoneos-arm")
    }

    func testEnvironmentOverrideWins() {
        let layout = JailbreakLayout.detect(fileExists: { _ in true }, environment: ["ORIGIN_LAYOUT": "rootful"])
        XCTAssertEqual(layout.style, .rootful)
    }

    func testZebraPathsAreOnTheDataVolumeForBoth() {
        XCTAssertEqual(
            JailbreakLayout(style: .rootless).zebraSourcesList,
            JailbreakLayout(style: .rootful).zebraSourcesList
        )
    }
}

final class SourceStoreTests: XCTestCase {

    func testFormatDetection() {
        XCTAssertEqual(SourceStore.detectFormat(text: "URIs: https://a/\n", name: "x.list"), .deb822)
        XCTAssertEqual(SourceStore.detectFormat(text: "deb https://a/ ./\n", name: "x.list"), .oneLine)
        XCTAssertEqual(SourceStore.detectFormat(text: "deb https://a/ ./\n", name: "x.sources"), .deb822)
    }

    func testFilesAreTaggedWithTheirName() {
        let file = SourceStore.parse(text: "deb https://a.example.com/ ./\n", path: "/etc/apt/sources.list.d/a.list", name: "a.list")
        XCTAssertEqual(file.repositories.first?.file, "a.list")
        XCTAssertEqual(file.format, .oneLine)
    }

    func testRecognisesSourcesFileNames() {
        XCTAssertTrue(SourceStore.isSourcesFile("sileo.sources"))
        XCTAssertTrue(SourceStore.isSourcesFile("cydia.list"))
        XCTAssertFalse(SourceStore.isSourcesFile("sources.list.bak"))
        XCTAssertFalse(SourceStore.isSourcesFile("README"))
    }
}
