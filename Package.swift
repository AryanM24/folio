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

let editors = ["FolioPDF", "FolioDocs", "FolioSheets", "FolioImage", "FolioCode", "FolioMedia"]

func editor(_ name: String, dependencies extra: [Target.Dependency] = []) -> Target {
    .target(
        name: name,
        dependencies: ["FolioKit"] + extra,
        swiftSettings: uiSettings
    )
}

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Folio", targets: ["Folio"])
    ],
    dependencies: [
        // Reading and writing .xlsx / .ods packages (zip containers).
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .executableTarget(
            name: "Folio",
            dependencies: ["FolioKit"] + editors.map { .target(name: $0) },
            swiftSettings: uiSettings
        ),
        .target(name: "FolioKit", swiftSettings: uiSettings),
        editor("FolioPDF"),
        editor("FolioDocs"),
        editor("FolioSheets", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        editor("FolioImage"),
        editor("FolioCode"),
        editor("FolioMedia"),
    ]
        + (["FolioKit"] + editors).map { name in
            .testTarget(name: "\(name)Tests", dependencies: [.target(name: name)], swiftSettings: uiSettings)
        }
)
