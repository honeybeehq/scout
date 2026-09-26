import Observation
import SwiftUI

@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case access
        case voice
        case point
        case connect
        case ready

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .access: "Access"
            case .voice: "Voice"
            case .point: "Point"
            case .connect: "Agents"
            case .ready: "Ready"
            }
        }

        var glow: Color {
            switch self {
            case .welcome, .ready: Palette.flare
            case .access: Palette.beam
            case .voice: Palette.mint
            case .point: Palette.beam
            case .connect: Palette.flareSoft
            }
        }
    }

    private(set) var step: Step
    private(set) var movingForward = true
    private(set) var isComplete: Bool

    private static let stepKey = "onboarding.step"
    private static let completeKey = "onboarding.complete"

    init() {
        let defaults = UserDefaults.standard
        step = Step(rawValue: defaults.integer(forKey: Self.stepKey)) ?? .welcome
        isComplete = defaults.bool(forKey: Self.completeKey)
        if ProcessInfo.processInfo.arguments.contains("--reset-onboarding") {
            step = .welcome
            isComplete = false
        }
        if let requested = Self.requestedStep() {
            step = requested
            isComplete = false
        }
    }

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        go(to: following)
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    func go(to target: Step) {
        movingForward = target.rawValue >= step.rawValue
        withAnimation(Motion.step) { step = target }
        UserDefaults.standard.set(target.rawValue, forKey: Self.stepKey)
    }

    func finish() {
        isComplete = true
        UserDefaults.standard.set(true, forKey: Self.completeKey)
        UserDefaults.standard.set(Step.welcome.rawValue, forKey: Self.stepKey)
    }

    func restart() {
        isComplete = false
        UserDefaults.standard.set(false, forKey: Self.completeKey)
        go(to: .welcome)
    }

    private static func requestedStep() -> Step? {
        let prefix = "--onboarding-step="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let name = argument.dropFirst(prefix.count).lowercased()
        return Step.allCases.first { $0.title.lowercased() == name }
    }
}
