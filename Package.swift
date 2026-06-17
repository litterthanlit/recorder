// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RecorderCore",
    platforms: [.macOS(.v13)],
    products: [],
    targets: [
        .target(
            name: "RecorderCore",
            path: "Recorder",
            exclude: [
                "App",
                "Capture",
                "Export",
                "UI",
                "Models",
                "Assets.xcassets",
                "Info.plist",
                "Recorder.entitlements"
            ],
            sources: [
                "Zoom"
            ]
        ),
        .testTarget(
            name: "RecorderCoreTests",
            dependencies: ["RecorderCore"],
            path: "RecorderTests"
        )
    ]
)
