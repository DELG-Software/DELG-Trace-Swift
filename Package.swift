// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DELG-Trace",
    platforms: [
        .iOS(.v13),
        .macOS(.v12)
    ],
    products: [
        .library(name: "DELGTrace", targets: ["DELGTrace"])
    ],
    targets: [
        .target(name: "DELGTrace", path: "Sources/DELGTrace")
    ]
)
