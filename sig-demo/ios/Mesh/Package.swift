// swift-tools-version: 6.0
// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "SigDemoMesh",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "SigDemoMesh", targets: ["SigDemoMesh"])],
    dependencies: [.package(path: "../../../.sig-demo/ios/mesh-sdk-v0.78.1")],
    targets: [
        .target(
            name: "SigDemoMesh",
            dependencies: [.product(name: "MeshLLM", package: "mesh-sdk-v0.78.1")],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedLibrary("resolv"),
                // Both Rust static libraries contain their own standard library.
                // Normal dead stripping removes unused duplicate personalities.
                .unsafeFlags(["-Xlinker", "-dead_strip"]),
            ]
        ),
        .testTarget(name: "SigDemoMeshTests", dependencies: ["SigDemoMesh"]),
    ]
)
