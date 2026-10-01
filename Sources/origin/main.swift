import Foundation
import OriginKit

// `origin` is the same engine the app uses, without the app. It exists for two
// reasons: it is how CI exercises the whole pipeline on Linux (where the app
// cannot run), and it is how a repository is managed over SSH when the phone is
// not in front of you.

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("origin: " + message + "\n").utf8))
    exit(1)
}

func layout() -> JailbreakLayout {
    JailbreakLayout.detect()
}

func usage() {
    print("""
    origin — manage APT sources on a jailbroken iOS device

    Usage: origin <command> [options]

      roots                        show the detected jailbreak layout and paths
      list [--json]                list every repository
      files                        list the sources files
      doctor                       validate every repository
      plan                         show what apply would write
      apply [--yes]                write the pending changes
      add <url> [suite] [comp...]  add a repository (--file NAME, --deb-src,
                                   --disabled, --arch A,B)
      remove <url>                 remove a repository
      enable <url> / disable <url> toggle a repository
      backup [label]               snapshot the sources files
      backups                      list snapshots
      restore <index|path>         restore a snapshot

    Environment: ORIGIN_LAYOUT=rootless|rootful overrides detection.
    """)
}

func store() -> SourceStore { SourceStore(layout: layout()) }

/// Loads, applies `mutate` to the file holding `url`, then writes.
func mutate(byURL url: String, _ change: (inout SourceFile) -> Void) -> Never {
    let store = store()
    let loaded = store.load()
    for var file in loaded.files where file.repositories.contains(where: { $0.url == url || $0.id == url }) {
        change(&file)
        let plan = store.plan(for: loaded.files.map { $0.path == file.path ? file : $0 })
        do {
            let log = try PlanApplier.apply(plan, with: DirectWriter())
            log.forEach { print($0) }
            if log.isEmpty { print("Nothing to do.") }
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }
    fail("no repository matches '\(url)'")
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func hasFlag(_ name: String, in arguments: [String]) -> Bool {
    arguments.contains(name)
}

func positional(_ arguments: [String], skipping: Set<String>) -> [String] {
    var result: [String] = []
    var skipNext = false
    for argument in arguments.dropFirst() {
        if skipNext { skipNext = false; continue }
        if argument.hasPrefix("--") {
            if ["--file", "--arch"].contains(argument) { skipNext = true }
            continue
        }
        if skipping.contains(argument) { continue }
        result.append(argument)
    }
    return result
}

guard let command = arguments.first else {
    usage()
    exit(0)
}

switch command {

case "roots":
    let layout = layout()
    print("style:            \(layout.style.displayName)")
    print("root:             \(layout.root.isEmpty ? "/" : layout.root)")
    print("apt directory:    \(layout.aptDirectory)")
    print("sources dirs:     \(layout.sourcesDirectories.joined(separator: ", "))")
    print("apt-get:          \(layout.aptGetPath)")
    print("helper:           \(layout.helperPath)")
    print("state:            \(layout.stateDirectory)")

case "list", "ls":
    let loaded = store().load()
    if hasFlag("--json", in: arguments) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(loaded.repositories)) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }
    if loaded.repositories.isEmpty { print("No repositories.") }
    for repository in loaded.repositories.sorted(by: { $0.host < $1.host }) {
        let marker = repository.enabled ? " " : "×"
        print("\(marker) \(repository.host)  \(repository.suiteLabel)  [\(repository.file ?? "?")]")
        print("    \(repository.url)")
    }
    for issue in loaded.issues { print("warning: \(issue)") }

case "files":
    for file in store().load().files {
        print("\(file.path)  (\(file.format.rawValue), \(file.repositories.count) repositories)")
    }

case "doctor":
    var problems = 0
    for repository in store().load().repositories {
        for issue in Validator.issues(for: repository) {
            problems += 1
            print("\(issue.severity.rawValue): \(repository.url) — \(issue.message)")
        }
    }
    print(problems == 0 ? "No problems found." : "\(problems) problem(s).")
    exit(problems == 0 ? 0 : 1)

case "plan", "apply":
    let store = store()
    let plan = store.plan(for: store.load().files)
    if plan.isEmpty { print("No changes."); exit(0) }
    print("Plan: \(plan.summary)")
    for write in plan.writes {
        print("\n  \(write.action.displayName) \(write.path)")
        for line in write.removedLines { print("    - \(line)") }
        for line in write.addedLines { print("    + \(line)") }
    }
    if command == "plan" { exit(0) }
    if !hasFlag("--yes", in: arguments) {
        print("\nRe-run with --yes to write these changes.")
        exit(0)
    }
    let backups = BackupStore(directory: layout().backupDirectory)
    if let snapshot = try? backups.save(backups.makeBackup(
        of: store.load().files, label: "before apply", layout: layout().style.rawValue
    )) {
        print("\nBacked up to \(snapshot)")
    }
    do {
        let log = try PlanApplier.apply(plan, with: DirectWriter())
        log.forEach { print($0) }
    } catch {
        fail(error.localizedDescription)
    }

case "add":
    let parts = positional(arguments, skipping: ["add"])
    guard let url = parts.first else { fail("add needs a URL") }
    let suite = parts.count > 1 ? parts[1] : "./"
    let components = Array(parts.dropFirst(2))
    let store = store()
    let loaded = store.load()
    let name = option("--file", in: arguments) ?? "origin"
    let repository = Repository(
        url: Validator.normalised(url: url),
        suites: [suite],
        components: components,
        kinds: hasFlag("--deb-src", in: arguments) ? [.deb, .debSrc] : [.deb],
        architectures: option("--arch", in: arguments)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
        enabled: !hasFlag("--disabled", in: arguments)
    )
    let errors = Validator.errors(for: repository)
    if !errors.isEmpty { fail(errors.map { $0.message }.joined(separator: " ")) }

    var files = loaded.files
    if let index = files.firstIndex(where: { $0.name.hasPrefix(name) }) {
        files[index].append(repository)
    } else {
        var file = store.makeFile(named: name, format: .deb822)
        file.append(repository)
        files.append(file)
    }
    do {
        let log = try PlanApplier.apply(store.plan(for: files), with: DirectWriter())
        log.forEach { print($0) }
    } catch {
        fail(error.localizedDescription)
    }

case "remove", "enable", "disable":
    let parts = positional(arguments, skipping: [command])
    guard let url = parts.first else { fail("\(command) needs a URL") }
    switch command {
    case "remove":  mutate(byURL: url) { $0.remove(id: $0.repositories.first { $0.url == url || $0.id == url }?.id ?? url) }
    case "enable":  mutate(byURL: url) { file in
        guard let repo = file.repositories.first(where: { $0.url == url || $0.id == url }) else { return }
        file.setEnabled(true, id: repo.id)
    }
    default:        mutate(byURL: url) { file in
        guard let repo = file.repositories.first(where: { $0.url == url || $0.id == url }) else { return }
        file.setEnabled(false, id: repo.id)
    }
    }

case "backup":
    let store = store()
    let backups = BackupStore(directory: layout().backupDirectory)
    let label = positional(arguments, skipping: ["backup"]).first ?? "manual"
    let snapshot = backups.makeBackup(of: store.load().files, label: label, layout: layout().style.rawValue)
    do {
        print(try backups.save(snapshot))
    } catch {
        fail(error.localizedDescription)
    }

case "backups":
    let backups = BackupStore(directory: layout().backupDirectory)
    let list = backups.list()
    if list.isEmpty { print("No backups.") }
    for (index, backup) in list.enumerated() {
        print("\(index)  \(ISO8601DateFormatter().string(from: backup.createdAt))  \(backup.summary)  \(backup.label)")
    }

case "restore":
    let backups = BackupStore(directory: layout().backupDirectory)
    guard let selector = positional(arguments, skipping: ["restore"]).first else { fail("restore needs an index or a path") }
    let path: String
    if let index = Int(selector) {
        let paths = backups.paths()
        guard index >= 0, index < paths.count else { fail("no backup at index \(index)") }
        path = paths[index]
    } else {
        path = selector
    }
    guard let backup = backups.load(path: path) else { fail("could not read \(path)") }
    let store = store()
    let plan = backups.plan(restoring: backup, currentFiles: store.load().files)
    do {
        let log = try PlanApplier.apply(plan, with: DirectWriter())
        log.forEach { print($0) }
        if log.isEmpty { print("Already up to date.") }
    } catch {
        fail(error.localizedDescription)
    }

case "-h", "--help", "help":
    usage()

default:
    fail("unknown command '\(command)' (try: origin help)")
}
