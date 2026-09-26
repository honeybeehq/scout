import Foundation
import ScoutCore

public struct PausePoint: Codable, Hashable, Sendable {
    public var seconds: Double
    public var weight: Double

    public init(seconds: Double, weight: Double) {
        self.seconds = seconds
        self.weight = weight
    }
}

public struct WeightedPhrase: Codable, Hashable, Sendable {
    public var phrase: String
    public var weight: Double

    public init(_ phrase: String, weight: Double) {
        self.phrase = phrase
        self.weight = weight
    }
}

public struct SegmenterConfiguration: Codable, Hashable, Sendable {
    public var threshold: Double = 0.6

    public var pauseCurve: [PausePoint] = [
        PausePoint(seconds: 0, weight: 0),
        PausePoint(seconds: 0.4, weight: 0.05),
        PausePoint(seconds: 1.2, weight: 0.3),
        PausePoint(seconds: 2.5, weight: 0.55),
        PausePoint(seconds: 5, weight: 0.8),
    ]

    public var cuePhrases: [WeightedPhrase] = SegmenterConfiguration.strongCues.map { WeightedPhrase($0, weight: 0.35) }
        + SegmenterConfiguration.weakCues.map { WeightedPhrase($0, weight: 0.2) }
    public var taskPhrases: [String] = [
        "new task", "next task", "another task", "separate task",
        "new issue", "next issue", "separate issue",
        "new note", "next note", "new ticket", "next ticket",
        "new bug", "next bug", "new item", "next item", "next thing",
    ]
    public var taskPhraseWeight: Double = 1
    public var closingPhrases: [String] = [
        "that's it", "that's all", "that is it", "that is all", "that's about it", "that's everything",
        "fix that", "fix this", "done with that", "done with this", "so yeah", "anyway",
    ]
    public var closingWeight: Double = 0.25
    public var continuationPhrases: [String] = [
        "it", "it's", "its", "they", "they're", "it also", "also it", "then it", "now it", "but it",
        "this one also", "that one also", "this one too", "the same", "same", "same thing", "same with", "same for",
        "which", "because", "cause", "that's because", "that's why", "plus", "especially", "except", "unless",
        "for example", "for instance", "like when", "wait", "no wait", "sorry", "i mean", "or rather",
    ]
    public var continuationWeight: Double = -0.3
    public var leadOpeners: [String] = [
        "um", "umm", "uh", "uhh", "er", "erm", "hmm", "hm", "mm", "mhm", "ah", "eh",
        "and", "so", "okay", "ok", "alright", "all", "right", "well", "oh", "yeah", "actually",
    ]
    public var fillerWords: [String] = [
        "um", "umm", "uh", "uhh", "er", "erm", "hmm", "hm", "mm", "mhm", "ah", "eh", "oh",
        "okay", "ok", "alright", "all", "right", "yeah", "yep", "so", "well", "wait", "sorry", "like",
        "hold", "on", "let", "me", "let's", "see", "just", "a", "sec", "second", "where", "was", "i", "no",
    ]
    public var leadSearchDepth: Int = 4
    public var closingSearchDepth: Int = 6

    public var leadWindow: Double = 1.5
    public var appChangeWeight: Double = 0.45
    public var locationChangeWeight: Double = 0.35
    public var windowChangeWeight: Double = 0.25

    public var targetChangeWeight: Double = 0.25
    public var pinnedTargetChangeWeight: Double = 0.35
    public var targetContinuityWeight: Double = -0.3
    public var markDwellEquivalent: Double = 3
    public var targetHalfLife: Double = 20
    public var minimumTargetWeight: Double = 0.5

    public var topicShiftWeight: Double = 0.2
    public var topicContinuityWeight: Double = -0.2
    public var lowSimilarity: Double = 0.05
    public var highSimilarity: Double = 0.25
    public var cohesionWindow: Int = 4

    public var visualChangeWeight: Double = 0.2

    public var minimumSpeechDuration: Double = 4
    public var minimumLengthWeight: Double = -0.35
    public var softMaximumDuration: Double = 90
    public var maximumLengthWeight: Double = 0.2

    public var silenceTimeout: Double = 8
    public var silenceGrace: Double = 4
    public var reorderTolerance: Double = 1.5
    public var discardGrace: Double = 10

    public init() {}

    public static let `default` = SegmenterConfiguration()

    public func pauseWeight(for gap: Double) -> Double {
        guard let first = pauseCurve.first, let last = pauseCurve.last else { return 0 }
        if gap <= first.seconds { return first.weight }
        if gap >= last.seconds { return last.weight }
        for (lower, upper) in zip(pauseCurve, pauseCurve.dropFirst()) where gap <= upper.seconds {
            let fraction = (gap - lower.seconds) / (upper.seconds - lower.seconds)
            return lower.weight + fraction * (upper.weight - lower.weight)
        }
        return last.weight
    }

    static let strongCues = [
        "next", "next up", "also", "another thing", "another issue", "another one", "another bug",
        "one more", "one other thing", "the other thing", "something else", "moving on", "let's move on",
        "okay so", "ok so", "alright so", "all right so", "right so", "okay next", "okay now",
        "second", "secondly", "third", "thirdly", "lastly", "finally", "last thing", "separately", "unrelated",
        "on this page", "on this screen", "over here", "over on", "over in", "back in", "back on", "back to",
        "switching to", "let's look at", "let's go to", "if we go to", "if i go to",
    ]

    static let weakCues = ["then", "now", "oh and"]
}
