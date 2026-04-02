// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TopCorner",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "TopCorner",
            path: "Sources/TopCorner",
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
