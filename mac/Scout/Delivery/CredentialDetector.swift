import Foundation
import ScoutCore

nonisolated protocol CredentialDetector: Sendable {
    var id: String { get }
    func suggestions(for clip: URL, in range: TimeRange, frames: Int) async throws -> [RedactedRegion]
}

nonisolated enum CredentialDetectors {
    static let installed: [any CredentialDetector] = []

    static func suggestions(for clip: ExportedClip) async -> [RedactedRegion] {
        var found: [RedactedRegion] = []
        for detector in installed {
            let regions = (try? await detector.suggestions(for: clip.url, in: clip.range, frames: 12)) ?? []
            found += regions.map { region in
                var region = region
                region.origin = .detector(detector.id)
                return region
            }
        }
        return found
    }
}
