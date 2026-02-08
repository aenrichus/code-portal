// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodePortal",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.10.0")
    ],
    targets: [
        .executableTarget(
            name: "CodePortal",
            dependencies: ["SwiftTerm"],
            path: "Sources",
            exclude: [
                "Resources/Info.plist",
                "Resources/CodePortal.entitlements",
                "Resources/AppIcon.icns"
            ]
        ),
        .testTarget(
            name: "CodePortalTests",
            dependencies: ["CodePortal"],
            path: "Tests"
        )
    ]
)
