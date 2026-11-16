//
//  PolyglotBookTests.swift
//  PolyglotSwiftSDK
//

import FischerCore
import Foundation
import Testing
@testable import Polyglot

/// A seeded generator, so random picks are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func game(_ moves: String...) throws -> Game {
    var game = Game()
    for uci in moves {
        try game.execute(uci: uci)
    }
    return game
}

func entry(_ game: Game, _ uci: String, _ weight: UInt16, learn: UInt32 = 0) throws -> PolyglotEntry {
    let resolved = try #require(game.resolvedMove(uci: uci))
    return PolyglotEntry(
        key: PolyglotKey.key(for: game),
        move: PolyglotMove(resolved, in: game.position),
        weight: weight,
        learn: learn
    )
}

struct PolyglotBookTests {
    @Test func entriesAreSixteenBigEndianBytes() {
        let entry = PolyglotEntry(
            key: 0x0102_0304_0506_0708,
            move: PolyglotMove(rawValue: 0x090A),
            weight: 0x0B0C,
            learn: 0x0D0E_0F10
        )
        #expect(entry.bytes == Array(1...16))
        #expect(PolyglotEntry(bytes: entry.bytes) == entry)
    }

    @Test func badDataIsRejected() throws {
        #expect(throws: PolyglotBookError.badSize(byteCount: 15)) {
            try PolyglotBook(data: Data(count: 15))
        }
        let high = PolyglotEntry(key: 2, move: PolyglotMove(rawValue: 1), weight: 1)
        let low = PolyglotEntry(key: 1, move: PolyglotMove(rawValue: 1), weight: 1)
        let unsorted = Data(high.bytes + low.bytes)
        #expect(throws: PolyglotBookError.unsorted(index: 1)) {
            try PolyglotBook(data: unsorted)
        }
        #expect(try PolyglotBook(data: unsorted, validatesOrder: false).count == 2)
        #expect(try PolyglotBook(data: Data()).isEmpty)
    }

    @Test func entriesAreFoundByKey() throws {
        let start = Game()
        let afterE4 = try game("e2e4")
        let book = PolyglotBook(entries: [
            try entry(afterE4, "e7e5", 5),
            try entry(start, "d2d4", 4),
            try entry(start, "e2e4", 9),
            try entry(afterE4, "c7c5", 7),
            PolyglotEntry(key: PolyglotKey.key(for: start), move: .null, weight: 100),
        ])
        #expect(book.count == 5)
        #expect(book.range(for: PolyglotKey.key(for: start)).count == 3)
        #expect(book.entries(for: start.position).map(\.move.uci) == ["e2e4", "d2d4"])
        #expect(book.moves(for: afterE4).map(\.uci) == ["c7c5", "e7e5"])
        #expect(book.moves(for: afterE4).map(\.share) == [7.0 / 12.0, 5.0 / 12.0])
        #expect(book.entries(for: 0x1234).isEmpty)
        #expect(book.contains(afterE4.position))
        #expect(!book.contains(try game("d2d4").position))
        // The keys are in order whatever order the entries came in.
        #expect(zip(book.dropLast(), book.dropFirst()).allSatisfy { $0.key <= $1.key })
    }

    @Test func movesThatAreNotLegalAreLeftOut() throws {
        let start = Game()
        let book = PolyglotBook(entries: [
            try entry(start, "e2e4", 3),
            PolyglotEntry(key: PolyglotKey.key(for: start), move: try #require(PolyglotMove(uci: "e2e5")), weight: 9),
        ])
        #expect(book.moves(for: start).map(\.uci) == ["e2e4"])
    }

    @Test func picksFollowTheStrategy() throws {
        let start = Game()
        let book = PolyglotBook(entries: [
            try entry(start, "e2e4", 6),
            try entry(start, "d2d4", 3),
            try entry(start, "c2c4", 1),
            try entry(start, "a2a4", 0),
        ])
        var generator = SplitMix64(state: 42)
        #expect(book.pick(.best, for: start, using: &generator)?.uci == "e2e4")

        var weighted: [String: Int] = [:]
        var uniform: [String: Int] = [:]
        for _ in 0..<20_000 {
            weighted[book.pick(.weighted, for: start, using: &generator)!.uci, default: 0] += 1
            uniform[book.pick(.uniform, for: start, using: &generator)!.uci, default: 0] += 1
        }
        // Weight 0 is never picked.
        #expect(weighted["a2a4"] == nil)
        #expect(uniform["a2a4"] == nil)
        // 60%, 30%, 10% and a third each, give or take.
        #expect(abs(Double(weighted["e2e4"]!) / 20_000 - 0.6) < 0.02)
        #expect(abs(Double(weighted["d2d4"]!) / 20_000 - 0.3) < 0.02)
        #expect(abs(Double(weighted["c2c4"]!) / 20_000 - 0.1) < 0.02)
        for move in ["e2e4", "d2d4", "c2c4"] {
            #expect(abs(Double(uniform[move]!) / 20_000 - 1.0 / 3.0) < 0.02)
        }
        #expect(book.pick(.weighted, for: try game("e2e4")) == nil)
    }

    @Test func bestPickKeepsTheFirstMoveOnATie() throws {
        let start = Game()
        let data = Data(try entry(start, "d2d4", 5).bytes + entry(start, "e2e4", 5).bytes)
        let book = try PolyglotBook(data: data)
        #expect(book.pick(.best, for: start)?.uci == "d2d4")
    }

    @Test func positionsWithOnlyZeroWeightsHaveNoPick() throws {
        let start = Game()
        let book = PolyglotBook(entries: [try entry(start, "e2e4", 0)])
        #expect(book.moves(for: start).map(\.share) == [0])
        #expect(book.pick(.best, for: start) == nil)
    }

    @Test func booksAreWrittenAndReadBack() throws {
        let start = Game()
        let book = PolyglotBook(entries: [try entry(start, "e2e4", 2, learn: 77), try entry(start, "g1f3", 1)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("polyglot-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try book.write(to: url)
        let read = try PolyglotBook(contentsOf: url)
        #expect(read.data == book.data)
        #expect(read.moves(for: start).map(\.uci) == ["e2e4", "g1f3"])
        #expect(read.moves(for: start).first?.learn == 77)
    }
}
