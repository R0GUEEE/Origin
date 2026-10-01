// swift-tools-version:5.9
import PackageDescription

// OriginKit is deliberately free of any Apple-only dependency so the whole
// decision layer (parsing, validation, planning, layout) can be built and
// tested on Linux. CI runs `swift test` on ubuntu-latest for that reason: it is
// the fast signal that catches a broken build before the macOS runner spends
// minutes on an Xcode build.
let package = Package(
    name: "Origin",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "OriginKit", targets: ["OriginKit"]),
        .executable(name: "origin", targets: ["origin"]),
    ],
    targets: [
        .target(name: "OriginKit"),
        .executableTarget(name: "origin", dependencies: ["OriginKit"]),
        .testTarget(name: "OriginKitTests", dependencies: ["OriginKit"]),
    ]
)
