// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnookerMenuBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SnookerMenuBar",
            path: "Sources/SnookerMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SpriteKit"),
                // Embed Info.plist so LSUIElement (no Dock icon) works
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        )
    ]
)
