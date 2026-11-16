//
//  PolyglotBook.swift
//  PolyglotSwiftSDK
//
//  A Polyglot opening book (`.bin`): 16-byte entries sorted by key. Files are memory mapped and looked up by binary
//  search, so nothing is read up front and books of hundreds of megabytes open at once.
//

import FischerCore
import Foundation

/// Errors raised when opening a book.
public enum PolyglotBookError: Error, Equatable, Sendable {
    /// The size is not a whole number of 16-byte entries.
    case badSize(byteCount: Int)
    /// The key of the entry at `index` is smaller than the one before it: the data is not a Polyglot book (or is a
    /// damaged one).
    case unsorted(index: Int)
}

/// A read-only Polyglot book. It is a random-access collection of its entries in file order.
public struct PolyglotBook: RandomAccessCollection, Sendable {
    /// The raw bytes of the book.
    public let data: Data

    /// Wraps the bytes of a book.
    ///
    /// - Parameter validatesOrder: Checks that every key is in order, which binary search needs. The check reads the
    ///   whole book; pass `false` to open a large trusted book without touching every page.
    public init(data: Data, validatesOrder: Bool = true) throws(PolyglotBookError) {
        guard data.count % PolyglotEntry.byteCount == 0 else {
            throw .badSize(byteCount: data.count)
        }
        self.data = data
        if validatesOrder, let index = firstUnsortedIndex() {
            throw .unsorted(index: index)
        }
    }

    /// Opens a `.bin` file, memory mapped when possible.
    public init(contentsOf url: URL, validatesOrder: Bool = true) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: data, validatesOrder: validatesOrder)
    }

    /// A book made of `entries`, sorted into book order (key, then weight from highest).
    public init<Entries: Sequence>(entries: Entries) where Entries.Element == PolyglotEntry {
        let sorted = entries.sorted(by: PolyglotEntry.bookOrder)
        var data = Data(capacity: sorted.count * PolyglotEntry.byteCount)
        for entry in sorted {
            data.append(contentsOf: entry.bytes)
        }
        self.data = data
    }

    /// Writes the book to `url`.
    public func write(to url: URL, options: Data.WritingOptions = .atomic) throws {
        try data.write(to: url, options: options)
    }

    // MARK: Collection

    public var startIndex: Int { 0 }
    public var endIndex: Int { data.count / PolyglotEntry.byteCount }

    public subscript(position: Int) -> PolyglotEntry {
        precondition(indices.contains(position), "Entry index out of range")
        return data.withUnsafeBytes { buffer in
            let offset = position * PolyglotEntry.byteCount
            return PolyglotEntry(bytes: UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + PolyglotEntry.byteCount)]))
        }
    }

    /// The key of the entry at `index`, read without decoding the rest of the entry.
    public func key(at index: Int) -> UInt64 {
        data.withUnsafeBytes { buffer in
            UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: index * PolyglotEntry.byteCount, as: UInt64.self))
        }
    }

    // MARK: Lookup

    /// The indices of the entries with `key`, found by binary search.
    public func range(for key: UInt64) -> Range<Int> {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if self.key(at: middle) < key { low = middle + 1 } else { high = middle }
        }
        var upper = low
        while upper < endIndex, self.key(at: upper) == key {
            upper += 1
        }
        return low..<upper
    }

    /// The entries with `key`, in file order. Null moves are left out.
    public func entries(for key: UInt64) -> [PolyglotEntry] {
        range(for: key).map { self[$0] }.filter { !$0.move.isNull }
    }

    /// The entries of `position`, in file order. Null moves are left out.
    public func entries(for position: Position) -> [PolyglotEntry] {
        entries(for: PolyglotKey.key(for: position))
    }

    /// Whether the book has any entry for `position`.
    public func contains(_ position: Position) -> Bool {
        !range(for: PolyglotKey.key(for: position)).isEmpty
    }

    /// The book moves of the current position of `game`, decoded into legal FischerCore moves, in file order.
    ///
    /// Entries whose move is not legal in the position (a key collision, or a damaged book) are left out.
    public func moves(for game: Game) -> [PolyglotBookMove] {
        let entries = entries(for: PolyglotKey.key(for: game.position))
        let total = entries.reduce(0) { $0 + Int($1.weight) }
        return entries.compactMap { entry in
            guard let move = entry.move.resolved(in: game) else { return nil }
            let share = total > 0 ? Double(entry.weight) / Double(total) : 0
            return PolyglotBookMove(entry: entry, move: move, share: share)
        }
    }

    /// The book moves of `position`. See ``moves(for:)-(Game)``.
    public func moves(for position: Position) -> [PolyglotBookMove] {
        guard let game = try? Game(position: position) else { return [] }
        return moves(for: game)
    }

    // MARK: Picking a move

    /// Picks a book move for the current position of `game`.
    ///
    /// Moves with weight 0 are never picked (some books use weight 0 for moves to avoid). Returns `nil` when the
    /// position is not in the book or has no move with a positive weight.
    public func pick<Generator: RandomNumberGenerator>(
        _ strategy: PolyglotPickStrategy = .weighted,
        for game: Game,
        using generator: inout Generator
    ) -> PolyglotBookMove? {
        let candidates = moves(for: game).filter { $0.weight > 0 }
        guard !candidates.isEmpty else { return nil }
        switch strategy {
        case .best:
            // `max(by:)` returns the first of equal elements, so a tie goes to the first move in the book.
            return candidates.max { $0.weight < $1.weight }
        case .uniform:
            return candidates.randomElement(using: &generator)
        case .weighted:
            let total = candidates.reduce(0) { $0 + Int($1.weight) }
            var roll = Int.random(in: 0..<total, using: &generator)
            for candidate in candidates {
                roll -= Int(candidate.weight)
                if roll < 0 { return candidate }
            }
            return candidates.last
        }
    }

    /// Picks a book move with the system random number generator.
    public func pick(_ strategy: PolyglotPickStrategy = .weighted, for game: Game) -> PolyglotBookMove? {
        var generator = SystemRandomNumberGenerator()
        return pick(strategy, for: game, using: &generator)
    }

    // MARK: Validation

    private func firstUnsortedIndex() -> Int? {
        guard count > 1 else { return nil }
        var previous = key(at: 0)
        for index in 1..<count {
            let current = key(at: index)
            if current < previous { return index }
            previous = current
        }
        return nil
    }
}

/// How ``PolyglotBook/pick(_:for:using:)`` chooses among the book moves of a position.
public enum PolyglotPickStrategy: Sendable, Equatable {
    /// The move with the highest weight (the first one in the book on a tie).
    case best
    /// A random move with probability proportional to its weight, as PolyGlot plays.
    case weighted
    /// A random move, every move with a positive weight equally likely.
    case uniform
}

/// A book move decoded for a position.
public struct PolyglotBookMove: Hashable, Sendable {
    /// The entry as stored in the book.
    public var entry: PolyglotEntry
    /// The legal move, with castling as a king move (`e1g1`).
    public var move: ResolvedMove
    /// The entry's weight divided by the total weight of the position (0 when every weight is 0).
    public var share: Double

    public init(entry: PolyglotEntry, move: ResolvedMove, share: Double) {
        self.entry = entry
        self.move = move
        self.share = share
    }

    public var weight: UInt16 { entry.weight }
    public var learn: UInt32 { entry.learn }
    /// The move in standard UCI (`e1g1` for castling, `e7e8q` for a promotion).
    public var uci: String { move.uci }
}
