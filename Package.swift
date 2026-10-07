// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DustPan",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DustPan", targets: ["DustPan"])
    ],
    targets: [
        .executableTarget(name: "DustPan"),
        .testTarget(name: "DustPanTests", dependencies: ["DustPan"])
    ]
)
