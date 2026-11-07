// swift-tools-version: 6.0
import PackageDescription

// The reusable signal core. The installable iOS application lives in the
// accompanying Xcode project; `swift build` alone does not produce an IPA.
let package = Package(
    name: "RheaRFSpanner",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RheaRFCore", targets: ["RheaRFCore"])
    ],
    targets: [
        .target(name: "RheaRFCore", path: "Sources/RheaRFCore"),
        .testTarget(
            name: "RheaRFCoreTests",
            dependencies: ["RheaRFCore"],
            path: "Tests/RheaRFCoreTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
