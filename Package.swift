// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RecorderCore",
    platforms: [.macOS(.v14)],
    products: [],
    targets: [
        .target(
            name: "RecorderCore",
            path: "Recorder",
            exclude: [
                "App",
                "Capture",
                "Export",
                "Editor/ProjectEditor.swift",
                "UI",
                "Assets.xcassets",
                "Info.plist",
                "Recorder.entitlements"
            ],
            sources: [
                "Zoom",
                "Editor/ZoomKeyframeEditor.swift",
                "Editor/EditHistory.swift",
                "Composition",
                "Models"
            ]
        ),
        .testTarget(
            name: "RecorderCoreTests",
            dependencies: ["RecorderCore"],
            path: "RecorderTests"
        )
    ]
)
