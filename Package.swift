// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PrintGlance",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PrintGlance", targets: ["PrintGlance"]),
    ],
    targets: [
        .executableTarget(name: "PrintGlance"),
        .testTarget(
            name: "PrintGlanceTests",
            dependencies: ["PrintGlance"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
