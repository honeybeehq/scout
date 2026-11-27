// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScoutKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ScoutCore", targets: ["ScoutCore"]),
        .library(name: "ScoutSegmenter", targets: ["ScoutSegmenter"]),
        .library(name: "ScoutRanking", targets: ["ScoutRanking"]),
        .executable(name: "scout-segment", targets: ["scout-segment"]),
    ],
    targets: [
        .target(name: "ScoutCore"),
        .target(name: "ScoutSegmenter", dependencies: ["ScoutCore"]),
        .executableTarget(name: "scout-segment", dependencies: ["ScoutCore", "ScoutSegmenter"]),
        .target(name: "ScoutRanking"),
        .executableTarget(name: "scout-rank-eval", dependencies: ["ScoutRanking"], path: "Eval/Sources/scout-rank-eval"),
    ]
)
