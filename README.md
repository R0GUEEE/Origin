# Origin

A package-source manager for jailbroken iOS, rebuilt from scratch.

Origin replaces the Cydia-era source managers (CSources2 and friends) with
something that matches how a modern jailbreak actually works: one codebase for
both rootless (`/var/jb`) and rootful installs, SwiftUI instead of storyboards,
and an engine that is a plain SwiftPM library so every decision it makes —
parsing, validation, planning — is unit-tested on Linux before an app build is
ever started.

## Why it is not a patch of the old app

The original ships as a compiled binary with no source. Nothing about it can be
modernised in place: it needs a separate compile per jailbreak layout because
its paths are baked into the binary, its UI is a set of `.storyboardc` files,
and its deployment target is iOS 9.

Origin is a clean-room replacement. Same job, nothing shared.

## What it does

* Reads and writes both APT source spellings: the one-line
  `deb https://repo/ ./` form and the deb822 `.sources` stanzas Sileo and
  apt 2.x use.
* Understands the `#deb` convention for a disabled repository, and keeps it —
  a disabled entry stays in the file, inert, instead of being deleted.
* Never rewrites a line it was not asked to change. Comments, blank lines,
  unknown deb822 fields and unreadable stanzas are preserved verbatim, so the
  app cannot corrupt a sources file a human also edits.
* Shows you exactly what it is about to write, line by line, before writing it.
* Snapshots every sources file before applying, and restores from the snapshot.
* Validates before it writes: a malformed line makes apt ignore the *whole*
  file, so every edit is checked as you type.

## Layout

```
Sources/OriginKit/     the engine — no Apple-only APIs, unit-tested on Linux
Sources/origin/        the `origin` command-line tool
Tests/OriginKitTests/  the test suite
App/                   the SwiftUI app (XcodeGen spec + sources)
Helper/                the setuid-root helper that performs the writes
Packaging/             .deb builder
```

The engine, the CLI and the app share one implementation. There is no second
copy of the path handling, which is what made the original need a binary per
jailbreak type.

## Command line

```
origin roots                       # detected layout and paths
origin list [--json]               # every repository
origin files                       # the sources files
origin doctor                      # validate everything
origin plan                        # what apply would write, line by line
origin apply --yes                 # write it (after taking a backup)
origin add <url> [suite] [comp…]   # --file NAME --deb-src --disabled --arch A,B
origin remove|enable|disable <url>
origin backup [label] / backups / restore <index|path>
```

`ORIGIN_LAYOUT=rootless|rootful` overrides layout detection.

## Building

Engine and tests, on any platform with a Swift toolchain:

```sh
swift build
swift test
```

App and packages, on macOS:

```sh
brew install xcodegen ldid dpkg
xcodegen generate --spec App/project.yml --project App
xcodebuild -project App/Origin.xcodeproj -scheme Origin -configuration Release \
           -sdk iphoneos -derivedDataPath build \
           CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
sh Packaging/build-deb.sh --rootless --output dist
sh Packaging/build-deb.sh --rootful  --output dist
```

CI does both: `.github/workflows/ci.yml` runs the engine on Linux,
`.github/workflows/app-build.yml` builds the app on a macOS runner and packages
the two debs.

## Licence

MIT.
