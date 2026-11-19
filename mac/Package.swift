// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HerdrVoice",
    platforms: [.macOS("15.0")],
    dependencies: [
        // On-device speech: Parakeet (speech-to-text) and Kokoro (text-to-speech). Models download on first use.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3")
    ],
    targets: [
        .executableTarget(
            name: "HerdrVoice",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/HerdrVoice"
        )
    ]
)
