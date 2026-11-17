#!/bin/zsh
# usage: make-offline-overlay.sh <verified FluidAudio clone> <overlay-dir>
# Builds a SwiftPM package named FluidAudio whose targets are symlinks to the verified clone's own sources,
# with no binary target, so SwiftPM never tries to download NemoTextProcessing. With `traits: []` the clone's
# manifest compiles the same sources with the same defines; only the manifest differs.
set -euo pipefail
clone="${1:A}"; overlay="${2:A}"
[[ "$(git -C "$clone" rev-parse HEAD)" == "c8b41f98eae668794dd0083bbe028fe7e6585051" ]] || { echo "clone HEAD is not the pinned FluidAudio v0.18.3 commit"; exit 1; }
mkdir -p "$overlay/Sources"
for t in FluidAudio FastClusterWrapper MachTaskSelfWrapper; do ln -sfn "$clone/Sources/$t" "$overlay/Sources/$t"; done
cat > "$overlay/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FluidAudio",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v2), .tvOS(.v17)],
    products: [.library(name: "FluidAudio", targets: ["FluidAudio"])],
    targets: [
        .target(
            name: "FluidAudio",
            dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper"],
            path: "Sources/FluidAudio",
            exclude: ["ASR/Parakeet/Unified/benchmark.md"]
        ),
        .target(name: "FastClusterWrapper", path: "Sources/FastClusterWrapper", publicHeadersPath: "include"),
        .target(name: "MachTaskSelfWrapper", path: "Sources/MachTaskSelfWrapper", publicHeadersPath: "include"),
    ],
    cxxLanguageStandard: .cxx17
)
MANIFEST
echo "overlay at $overlay -> $clone"
