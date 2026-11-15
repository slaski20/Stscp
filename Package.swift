// swift-tools-version: 6.0

// Copyright 2026 slaski20
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "Stscp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Stscp", targets: ["Stscp"])
    ],
    targets: [
        .executableTarget(
            name: "Stscp",
            path: "Sources/Stscp"
        ),
        .testTarget(name: "StscpTests", dependencies: ["Stscp"])
    ]
)
