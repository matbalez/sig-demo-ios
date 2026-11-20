// swift-tools-version: 6.0
// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "SigDemoKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "SigDemoKit", targets: ["SigDemoKit"])],
    targets: [
        .target(name: "SigDemoKit", resources: [.copy("Resources/ApprovedRelay.txt")]),
        .testTarget(name: "SigDemoKitTests", dependencies: ["SigDemoKit"]),
    ]
)
