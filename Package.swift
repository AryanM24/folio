// swift-tools-version: 6.2
//
// Folio — a native macOS editor for the files you actually use.
//
// The package is split into one module per editor so each can be built,
// tested and reasoned about on its own. `Folio` is the thin app target that
// composes them into document scenes. See docs/ARCHITECTURE.md.

import PackageDescription

/// UI modules run on the main actor by default (SE-0466); pure logic opts out with `nonisolated`.
let uiSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

/// The conversion engine and the agent layer have no UI, so nothing there defaults to the main actor.
let engineSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let editors = ["FolioPDF", "FolioDocs", "FolioSheets", "FolioImage", "FolioCode", "FolioMedia", "FolioArchive", "FolioPreview"]

func editor(_ name: String, dependencies extra: [Target.Dependency] = []) -> Target {
    .target(
        name: name,
        dependencies: ["FolioKit"] + extra,
        swiftSettings: uiSettings
    )
}

/// One suite per module, plus `FolioTests` for the app target's pure logic (workspace
/// sorting, search, naming), which `@testable import Folio` reaches.
let testTargets: [Target] =
    (["FolioKit"] + editors + ["Folio"]).map { name in
        .testTarget(
            name: "\(name)Tests", dependencies: [.target(name: name)] + (name == "FolioArchive" ? ["CArchive"] : []),
            swiftSettings: uiSettings)
    }
    + ["FolioConvert", "FolioAgent"].map { name in
        .testTarget(name: "\(name)Tests", dependencies: [.target(name: name)], swiftSettings: engineSettings)
    }

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Folio", targets: ["Folio"]),
        // Bundled as Folio.app/Contents/Helpers/folio (a different name from `Folio`,
        // since the Mac's file system ignores case).
        .executable(name: "folio-cli", targets: ["FolioCLI"]),
    ],
    dependencies: [
        // Reading and writing .xlsx / .ods packages (zip containers).
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .executableTarget(
            name: "Folio",
            dependencies: ["FolioKit", "FolioConvert", "FolioAgent"] + editors.map { .target(name: $0) },
            swiftSettings: uiSettings
        ),
        // `folio`: the command-line tool and local MCP server. One binary, both jobs.
        .executableTarget(name: "FolioCLI", dependencies: ["FolioAgent"], swiftSettings: engineSettings),
        .target(
            name: "FolioAgent",
            dependencies: ["FolioConvert", "FolioKit"] + editors.map { .target(name: $0) },
            swiftSettings: engineSettings
        ),
        .target(
            name: "FolioConvert",
            dependencies: ["FolioKit", "FolioDocs", "FolioSheets", "FolioCode", "FolioImage", "CArchive"],
            swiftSettings: engineSettings
        ),
        .target(name: "FolioKit", swiftSettings: uiSettings),
        editor("FolioPDF"),
        editor("FolioDocs"),
        editor("FolioSheets", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        editor("FolioImage"),
        editor("FolioCode"),
        editor("FolioMedia", dependencies: ["FolioConvert"]),
        editor("FolioArchive", dependencies: ["CArchive"]),
        editor("FolioPreview", dependencies: ["FolioConvert"]),
        // The system libarchive (/usr/lib/libarchive.2.dylib). The SDK ships no headers, so
        // `shim.h` declares only the functions Folio calls.
        .systemLibrary(name: "CArchive"),
    ]
        + testTargets
)
