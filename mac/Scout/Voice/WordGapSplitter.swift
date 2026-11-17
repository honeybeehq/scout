import ScoutCore

nonisolated enum WordGapSplitter {
    static let pause: Double = 1.0

    static func groups(_ words: [Word], pause: Double = pause) -> [[Word]] {
        var groups: [[Word]] = []
        for word in words {
            if let last = groups.last?.last, word.range.start - last.range.end >= pause {
                groups.append([word])
            } else if groups.isEmpty {
                groups.append([word])
            } else {
                groups[groups.count - 1].append(word)
            }
        }
        return groups
    }
}
