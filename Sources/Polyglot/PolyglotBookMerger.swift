//
//  PolyglotBookMerger.swift
//  PolyglotSwiftSDK
//
//  Merges two books into one, like PolyGlot's `merge-book`.
//

/// How ``PolyglotBook/merged(with:strategy:)`` combines two books.
public enum PolyglotMergeStrategy: Sendable, Equatable {
    /// A position found in the first book keeps only the first book's moves; the second book only adds positions the
    /// first one lacks. This is PolyGlot's `merge-book`.
    case preferFirst
    /// Every move of both books is kept. A move found in both books gets the sum of its weights (and the first
    /// book's learn value); when the weights of a position no longer fit in 16 bits they are scaled down together.
    case sumWeights
}

extension PolyglotBook {
    /// Merges this book with `other`.
    ///
    /// Both books are read in a single pass, so the cost is linear in their sizes.
    public func merged(with other: PolyglotBook, strategy: PolyglotMergeStrategy = .preferFirst) -> PolyglotBook {
        var result: [PolyglotEntry] = []
        result.reserveCapacity(count + other.count)
        var first = startIndex
        var second = other.startIndex
        while first < endIndex || second < other.endIndex {
            let firstKey = first < endIndex ? key(at: first) : nil
            let secondKey = second < other.endIndex ? other.key(at: second) : nil
            let key = [firstKey, secondKey].compactMap { $0 }.min()!
            let firstRange = firstKey == key ? range(startingAt: first, key: key) : first..<first
            let secondRange = secondKey == key ? other.range(startingAt: second, key: key) : second..<second
            let firstEntries = firstRange.map { self[$0] }
            let secondEntries = secondRange.map { other[$0] }
            switch strategy {
            case .preferFirst:
                result.append(contentsOf: firstEntries.isEmpty ? secondEntries : firstEntries)
            case .sumWeights:
                result.append(contentsOf: Self.sum(firstEntries, secondEntries))
            }
            first = firstRange.upperBound
            second = secondRange.upperBound
        }
        return PolyglotBook(entries: result)
    }

    /// The entries with `key` from `index`, which must be the first of them.
    private func range(startingAt index: Int, key: UInt64) -> Range<Int> {
        var upper = index
        while upper < endIndex, self.key(at: upper) == key {
            upper += 1
        }
        return index..<upper
    }

    /// The entries of one position from two books, with the weights of the same move added up.
    private static func sum(_ first: [PolyglotEntry], _ second: [PolyglotEntry]) -> [PolyglotEntry] {
        var order: [PolyglotMove] = []
        var totals: [PolyglotMove: (score: Int, learn: UInt32)] = [:]
        for entry in first + second {
            if let total = totals[entry.move] {
                totals[entry.move] = (total.score + Int(entry.weight), total.learn)
            } else {
                order.append(entry.move)
                totals[entry.move] = (Int(entry.weight), entry.learn)
            }
        }
        guard let key = (first.first ?? second.first)?.key else { return [] }
        let weights = PolyglotBookBuilder.fitWeights(order.map { totals[$0]!.score })
        return zip(order, weights).map { move, weight in
            PolyglotEntry(key: key, move: move, weight: weight, learn: totals[move]!.learn)
        }
    }
}
