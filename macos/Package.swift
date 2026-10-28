// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BooxSidecar",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "BooxSidecar", targets: ["BooxSidecar"])],
    targets: [
        .target(name: "VirtualDisplayKit", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]),
        .executableTarget(name: "BooxSidecar", dependencies: ["VirtualDisplayKit"])
    ]
)
