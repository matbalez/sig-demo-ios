// swift-tools-version: 6.0
// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription
let package = Package(
    name: "SigDemoLocalModel", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "SigDemoLocalModel", targets: ["SigDemoLocalModel"])],
    dependencies: [.package(path: "../NativeAgent")],
    targets: [
        .target(name: "SigDemoLocalModel", dependencies: [.product(name: "SigDemoAgent", package: "NativeAgent")],
            exclude: ["LocalModelNativeTransport.swift", "LocalModelHostTransport.swift"]),
        .testTarget(name: "SigDemoLocalModelTests", dependencies: ["SigDemoLocalModel"]),
    ])
