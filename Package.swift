// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NoCornyTracer",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "NoCornyTracer",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/NoCornyTracer",
            exclude: ["NoCornyTracer.entitlements", "Secrets.swift.template", "Info.plist"],
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/NoCornyTracer/Info.plist"
                ])
            ]
        ),
    ]
)
