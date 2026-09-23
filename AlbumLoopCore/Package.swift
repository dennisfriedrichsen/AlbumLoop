// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral playback core for AlbumLoop. It has no UIKit or PhotoKit
// dependency so its logic can be tested on macOS (`swift test`) and on the
// tvOS simulator with a fake image provider.
let package = Package(
    name: "AlbumLoopCore",
    platforms: [.tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AlbumLoopCore", targets: ["AlbumLoopCore"]),
    ],
    targets: [
        .target(name: "AlbumLoopCore"),
        .testTarget(name: "AlbumLoopCoreTests", dependencies: ["AlbumLoopCore"]),
    ],
    swiftLanguageModes: [.v6]
)
