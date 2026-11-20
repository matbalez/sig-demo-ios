// swift-tools-version: 6.0
// Copyright 2026 sig demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "SigDemoAgent",
    platforms: [.iOS(.v16)],
    products: [.library(name: "SigDemoAgent", targets: ["SigDemoAgent"])],
    targets: [
        .binaryTarget(name: "sig_demo_agentFFI", path: "Artifacts/SigDemoAgentFFI.xcframework"),
        .target(
            name: "SigDemoAgent",
            dependencies: ["sig_demo_agentFFI"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("c++"),
                .linkedLibrary("compression"),
                .linkedLibrary("resolv"),
            ]
        ),
    ]
)
