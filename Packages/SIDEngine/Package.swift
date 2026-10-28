// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SIDEngine",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SIDEngine", targets: ["SIDEngine"]),
        .library(name: "SIDLibrary", targets: ["SIDLibrary"]),
        .library(name: "SIDFX", targets: ["SIDFX"]),
    ],
    targets: [
        // libsidplayfp 3.1.2 + libresidfp 1.2.3, vendored unmodified apart from the hand-written config/version headers.
        .target(
            name: "CSIDPlayFP",
            exclude: [
                "libsidplayfp/COPYING", "libsidplayfp/AUTHORS.md", "libsidplayfp/README.md",
                "libsidplayfp/libs/hashlib/LICENSE", "libsidplayfp/libs/hashlib/README.md",
                "libsidplayfp/psiddrv.bin", "libsidplayfp/poweron.bin",
                "libsidplayfp/sidtune/sidplayer1.bin", "libsidplayfp/sidtune/sidplayer2.bin",
                "libresidfp/COPYING", "libresidfp/AUTHORS", "libresidfp/README.md",
            ],
            cxxSettings: [
                .headerSearchPath("libsidplayfp"),
                .headerSearchPath("libsidplayfp/sidtune"),
                .headerSearchPath("libsidplayfp/builders/residfp-builder"),
                .headerSearchPath("libresidfp"),
                .define("HAVE_CONFIG_H"),
                // The emulator is far too slow at -O0, so optimise it in Debug builds too.
                .unsafeFlags(["-O3", "-ffast-math", "-fno-unsafe-math-optimizations", "-Wno-everything"]),
            ]
        ),
        .target(name: "SIDEngine", dependencies: ["CSIDPlayFP"]),
        // Library data: PSID headers, Songlengths, STIL, the online catalogue index, zip archives, search.
        .target(name: "SIDLibrary"),
        // The audio quality modes and equalizer (port of the web app's fx.ts).
        .target(name: "SIDFX", swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
        .testTarget(name: "SIDEngineTests", dependencies: ["SIDEngine"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SIDLibraryTests", dependencies: ["SIDLibrary"]),
        .testTarget(name: "SIDFXTests", dependencies: ["SIDFX"]),
    ],
    cxxLanguageStandard: .gnucxx20
)
