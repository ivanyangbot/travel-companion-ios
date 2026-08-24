// swift-tools-version: 5.9
import PackageDescription

// Vendored from https://github.com/Jakubantalik/Libraries
// (packages/thinking-orbs/ports/ios/ThinkingOrbsKit, MIT licensed, see LICENSE).
// The upstream repo keeps Package.swift in a subdirectory, which SwiftPM
// cannot consume remotely, so the sources are mirrored here as a local package.
// Note: the package's minimum platform only needs to be <= the app's
// deployment target (iOS 26); declaring .iOS(.v26) here would require
// swift-tools-version 6.2 and is unnecessary.
let package = Package(
    name: "ThinkingOrbsKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ThinkingOrbsKit", targets: ["ThinkingOrbsKit"])
    ],
    targets: [
        .target(name: "ThinkingOrbsKit")
    ]
)
