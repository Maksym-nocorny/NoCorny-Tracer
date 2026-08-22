// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NoCornyTracer",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Local Whisper (Core ML). PINNED EXACT, and NOT to 1.x on purpose:
        // every 1.x tag declares two executable products (argmax-cli and
        // whisperkit-cli) pointing at the SAME ArgmaxCLI target, which makes a
        // multi-arch build fail with "duplicate key found: ID(moduleName:
        // "ArgmaxCLI", packageIdentity: whisperkit)". Single-arch builds are
        // fine, so the breakage only shows up when packaging a release.
        // 0.18.0 has one executable product, builds universal, and exposes the
        // same API surface we use (WhisperKit.download, ModelUtilities.loadTokenizer,
        // DecodingOptions.chunkingStrategy) plus the SpeakerKit diarization library.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
        // Speaker diarization (segmentation + embeddings, CoreML). PINNED EXACT:
        // 0.15.x introduces a binaryTarget plus a resource bundle, neither of which
        // scripts/build_dmg.sh knows how to copy into the .app, so the DMG would ship
        // an app that crashes on first diarization. 0.14.5 is a plain Swift+C target
        // set with no external dependencies and no bundle.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.5"),
    ],
    targets: [
        .executableTarget(
            name: "NoCornyTracer",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
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
        .testTarget(
            name: "NoCornyTracerTests",
            dependencies: ["NoCornyTracer"],
            path: "Tests/NoCornyTracerTests"
        ),
    ]
)
