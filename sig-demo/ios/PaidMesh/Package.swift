// swift-tools-version: 6.0
// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "SigDemoPaidMesh",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "SigDemoPaidMesh", targets: ["SigDemoPaidMesh"])],
    dependencies: [.package(path: "../Mesh")],
    targets: [
        .binaryTarget(name: "SigDemoPaidMeshFFI", path: "Artifacts/SigDemoPaidMeshFFI.xcframework"),
        .target(
            name: "SigDemoPaidMesh",
            dependencies: ["SigDemoPaidMeshFFI", .product(name: "SigDemoMesh", package: "Mesh")],
            linkerSettings: [
                .linkedFramework("Network"), .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedLibrary("resolv"),
                .unsafeFlags(["-Xlinker", "-dead_strip"]),
            ]
        ),
        .testTarget(name: "SigDemoPaidMeshTests", dependencies: ["SigDemoPaidMesh", "SigDemoPaidMeshFFI"]),
    ]
)
