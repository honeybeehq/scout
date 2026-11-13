// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "scout-transcribe-eval",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "scout-transcribe-eval", swiftSettings: [.unsafeFlags(["-parse-as-library"])])
    ]
)
