// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plaintexter",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Plaintexter", targets: ["Plaintexter"])],
    targets: [
        .target(name: "ClipboardCore"),
        .target(name: "AppSupport"),
        .executableTarget(name: "Plaintexter", dependencies: ["ClipboardCore", "AppSupport"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
        .testTarget(name: "AppSupportTests", dependencies: ["AppSupport"])
    ]
)
