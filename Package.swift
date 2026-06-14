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
                // Embed Info.plist into the executable's __TEXT,__info_plist section.
                // NOTE: SwiftPM does NOT track this file as a build input, so editing
                // Info.plist does not invalidate the cached binary — an incremental
                // build can ship a STALE embedded plist (wrong CFBundleShortVersionString,
                // missing LSMinimumSystemVersion, etc.). Release builds therefore clean
                // the cached release binary before linking and assert the embedded
                // version matches the source (see scripts/build_dmg.sh, Step 1).
                // The path is relative to the package root; build scripts cd there first.
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
