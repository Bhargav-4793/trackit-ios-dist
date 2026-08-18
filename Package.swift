// swift-tools-version: 6.0
import PackageDescription

// The distribution manifest — what a host actually resolves. No source.
//
// In the shipped two-repository model (05-distribution §2) this file is the whole
// public repository, and each binaryTarget carries a `url:` + `checksum:` against
// an immutable per-version path. Here it points at local artefacts produced by
// `scripts/release.sh`, so the pipeline can be exercised end to end without a
// hosting decision or a signing identity. Swapping `path:` for `url:`/`checksum:`
// is a one-line change per target.
//
// **A binary target cannot declare dependencies.** SPM will not resolve
// TrackerCore → TrackerGeo on a host's behalf, so every product lists the full
// closure of targets the host has to link. Get this wrong and the host sees
// "no such module" at compile time, or a missing symbol at launch.
let package = Package(
    name: "Tracker",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "TrackerGeo",  targets: ["TrackerGeo"]),
        .library(name: "TrackerCore", targets: ["TrackerCore", "TrackerGeo"]),
        .library(name: "TrackerMaps", targets: ["TrackerMaps", "TrackerGeo"]),
        .library(name: "TrackerSnap", targets: ["TrackerSnap", "TrackerGeo"]),
        .library(name: "TrackerSync", targets: ["TrackerSync", "TrackerCore", "TrackerGeo"]),
    ],
    targets: [
        .binaryTarget(name: "TrackerGeo",  path: "Artifacts/TrackerGeo.xcframework"),
        .binaryTarget(name: "TrackerCore", path: "Artifacts/TrackerCore.xcframework"),
        .binaryTarget(name: "TrackerMaps", path: "Artifacts/TrackerMaps.xcframework"),
        .binaryTarget(name: "TrackerSnap", path: "Artifacts/TrackerSnap.xcframework"),
        .binaryTarget(name: "TrackerSync", path: "Artifacts/TrackerSync.xcframework"),
    ]
)
