// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "screc",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "screc", targets: ["screc"])
    ],
    targets: [
        // Writes the recording to an .mp4 file. Everything that touches AVAssetWriter/AVAssetReader lives here.
        .target(
            name: "ScrecMedia",
            swiftSettings: [
                // Those APIs are deprecated in macOS 27, but their replacements do not exist on macOS 15-26.
                // The warnings are silenced for this small target only, so they cannot hide real problems elsewhere.
                .unsafeFlags(["-suppress-warnings"])
            ]
        ),
        // Command-line options, capture control and the GUI.
        .target(
            name: "ScrecKit",
            dependencies: ["ScrecMedia"]
        ),
        // A one-line entry point, so everything else can be imported by the tests.
        .executableTarget(
            name: "screc",
            dependencies: ["ScrecKit"]
        ),
        .testTarget(
            name: "ScrecKitTests",
            dependencies: ["ScrecKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
