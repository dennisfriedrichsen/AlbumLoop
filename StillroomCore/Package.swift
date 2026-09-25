// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral playback core for Stillroom. It has no UIKit or PhotoKit
// dependency so its logic can be tested on macOS (`swift test`) and on the
// tvOS simulator with a fake image provider.
let package = Package(
    name: "StillroomCore",
    platforms: [.tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "StillroomCore", targets: ["StillroomCore"]),
    ],
    targets: [
        .target(name: "StillroomCore"),
        .testTarget(name: "StillroomCoreTests", dependencies: ["StillroomCore"]),
    ],
    swiftLanguageModes: [.v6]
)
