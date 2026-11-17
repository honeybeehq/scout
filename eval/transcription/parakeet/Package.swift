// swift-tools-version: 6.2
import Foundation
import PackageDescription

let fluidAudio: Package.Dependency = {
    if let path = ProcessInfo.processInfo.environment["SCOUT_EVAL_FLUIDAUDIO_PATH"] {
        return .package(path: path)
    }
    return .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.3", traits: [])
}()

let package = Package(
    name: "scout-parakeet-eval",
    platforms: [.macOS(.v26)],
    dependencies: [fluidAudio],
    targets: [
        .executableTarget(
            name: "scout-parakeet-eval",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
