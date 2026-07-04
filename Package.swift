// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "FirefoxBlocklist",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "FirefoxBlocklist", path: "Sources/FirefoxBlocklist")
    ]
)
