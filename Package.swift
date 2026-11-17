// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SetlineData",
    platforms: [.macOS(.v13), .iOS(.v17)],
    targets: [
        .target(name: "SetlineData", path: "ios/Setline/Data"),
        .testTarget(name: "SetlineDataTests", dependencies: ["SetlineData"], path: "ios/Tests")
    ]
)
