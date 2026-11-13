// swift-tools-version: 6.2
import Foundation
import PackageDescription

let whisperKit: Package.Dependency = {
    if let path = ProcessInfo.processInfo.environment["SCOUT_EVAL_WHISPERKIT_PATH"] {
        return .package(path: path)
    }
    return .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.1")
}()

let package = Package(
    name: "scout-whisper-eval",
    platforms: [.macOS(.v26)],
    dependencies: [whisperKit, .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.7.0")],
    targets: [
        .executableTarget(
            name: "scout-whisper-eval",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
