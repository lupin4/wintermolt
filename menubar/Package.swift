// swift-tools-version:5.9
// Copyright The Fantastic Planet - By David Clabaugh

import PackageDescription

let package = Package(
    name: "wintermolt-menubar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "wintermolt-menubar",
            path: "Sources"
        ),
    ]
)
