// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowPin",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WindowPin",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "WindowPinTests",
            dependencies: ["WindowPin"],
            path: "Tests/WindowPinTests"
        ),
    ]
)
