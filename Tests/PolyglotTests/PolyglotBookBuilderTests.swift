//
//  PolyglotBookBuilderTests.swift
//  PolyglotSwiftSDK
//
//  `sample.pgn` has seven games: three from the start position (1-0, ½-½, 0-1), one with an invalid FEN, one in
//  Chess960, one without a result (`*`) and one that starts from a FEN and promotes to a knight.
//

import FischerCore
import Foundation
import Testing
@testable import Polyglot

struct PolyglotBookBuilderTests {
    static let sampleURL = Bundle.module.url(forResource: "sample", withExtension: "pgn", subdirectory: "Resources")!

    static func sample(_ options: PolyglotBookOptions) throws -> PolyglotBookBuilder {
        var builder = PolyglotBookBuilder(options: options)
        try builder.add(contentsOf: sampleURL)
        return builder
    }

    /// The book moves of a position as `uci: weight`.
    static func moves(_ book: PolyglotBook, _ game: Game) -> [String] {
        book.moves(for: game).map { "\($0.uci):\($0.weight)" }
    }

    @Test func roundTripGivesTheExpectedMovesAndWeights() throws {
        let builder = try Self.sample(PolyglotBookOptions(minGames: 1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("polyglot-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try builder.build().write(to: url)
        let book = try PolyglotBook(contentsOf: url)

        // 1. e4: 2 (1-0) + 1 (½-½) + 0 (0-1); 1. d4: 1 (`*` counts as a draw).
        #expect(Self.moves(book, Game()) == ["e2e4:3", "d2d4:1"])
        // Black's moves are scored for black: 1... c5 won, 1... e5 lost one game and drew another.
        #expect(Self.moves(book, try game("e2e4")) == ["c7c5:2", "e7e5:1"])
        #expect(Self.moves(book, try game("e2e4", "e7e5")) == ["g1f3:3"])
        // 2... Nc6 only lost: weight 0, dropped. The variation 2... d6 is not the main line.
        #expect(Self.moves(book, try game("e2e4", "e7e5", "g1f3")) == ["g8f6:1"])
        #expect(Self.moves(book, try game("e2e4", "c7c5")) == [])
        #expect(Self.moves(book, try game("e2e4", "c7c5", "g1f3")) == ["d7d6:2"])
        #expect(Self.moves(book, try game("d2d4")) == ["d7d5:1"])

        // Castling is stored king-takes-rook and read back as the king move.
        let beforeCastling = try game("e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5")
        let castling = try #require(book.moves(for: beforeCastling).first)
        #expect(castling.entry.move.uci == "e1h1")
        #expect(castling.uci == "e1g1")
        #expect(castling.weight == 2)

        // The promotion game starts from its FEN.
        let promotion = try Game(with: "1r2k3/P7/8/8/8/8/8/4K3 w - - 0 1")
        let knight = try #require(book.moves(for: promotion).first)
        #expect(knight.uci == "a7b8n")
        #expect(knight.move.promotion == .knight)
        #expect(knight.weight == 2)
    }

    @Test func unreadableGamesAreSkipped() throws {
        let builder = try Self.sample(PolyglotBookOptions(minGames: 1))
        #expect(builder.statistics.gamesAdded == 5)
        #expect(builder.statistics.gamesSkipped == 2)
        #expect(builder.statistics.gamesTruncated == 0)
        #expect(builder.failures.map(\.gameNumber) == [4, 5])
        #expect(builder.failures[1].reason.contains("Chess960"), "\(builder.failures)")
        #expect(builder.failures.allSatisfy { $0.byteOffset != nil })
    }

    @Test func movesBelowTheMinimumGameCountAreDropped() throws {
        let book = try Self.sample(PolyglotBookOptions(minGames: 2)).build()
        #expect(book.count == 3)
        #expect(Self.moves(book, Game()) == ["e2e4:3"])
        #expect(Self.moves(book, try game("e2e4")) == ["e7e5:1"])
        #expect(Self.moves(book, try game("e2e4", "e7e5")) == ["g1f3:3"])
    }

    @Test func maxPlyLimitsTheDepth() throws {
        let book = try Self.sample(PolyglotBookOptions(maxPly: 1, minGames: 1)).build()
        // The first move of each game: e4, d4 and the promotion.
        #expect(book.count == 3)
        #expect(Self.moves(book, try game("e2e4")) == [])
    }

    @Test func colorFilterKeepsOneSide() throws {
        let white = try Self.sample(PolyglotBookOptions(minGames: 1, colors: .white)).build()
        #expect(Self.moves(white, Game()) == ["e2e4:3", "d2d4:1"])
        #expect(Self.moves(white, try game("e2e4")) == [])

        let black = try Self.sample(PolyglotBookOptions(minGames: 1, colors: .black)).build()
        #expect(Self.moves(black, Game()) == [])
        #expect(Self.moves(black, try game("e2e4")) == ["c7c5:2", "e7e5:1"])
    }

    @Test func weightingOptions() throws {
        let popularity = try Self.sample(PolyglotBookOptions(minGames: 1, weighting: .popularity)).build()
        #expect(Self.moves(popularity, Game()) == ["e2e4:3", "d2d4:1"])
        #expect(Self.moves(popularity, try game("e2e4")) == ["e7e5:2", "c7c5:1"])
        // A losing move is kept when weights count games.
        #expect(Self.moves(popularity, try game("e2e4", "e7e5", "g1f3")) == ["b8c6:1", "g8f6:1"])

        let uniform = try Self.sample(PolyglotBookOptions(minGames: 1, weighting: .uniform)).build()
        #expect(uniform.count == 18)
        #expect(uniform.allSatisfy { $0.weight == 1 })

        let custom = try Self.sample(PolyglotBookOptions(minGames: 1, weighting: .results(win: 10, draw: 4, loss: 1))).build()
        #expect(Self.moves(custom, Game()) == ["e2e4:15", "d2d4:4"])

        let zeros = try Self.sample(PolyglotBookOptions(minGames: 1, keepsZeroWeights: true)).build()
        #expect(zeros.count == 18)
        #expect(zeros.filter { $0.weight == 0 }.count == 5)
    }

    @Test func streamingInSmallBlocksReadsTheSameGames() throws {
        var streamed = PolyglotBookBuilder(options: PolyglotBookOptions(minGames: 1))
        try streamed.add(contentsOf: Self.sampleURL, blockSize: 37)
        var whole = PolyglotBookBuilder(options: PolyglotBookOptions(minGames: 1))
        whole.add(pgn: try String(contentsOf: Self.sampleURL, encoding: .utf8))
        #expect(streamed.entries() == whole.entries())
        #expect(streamed.statistics == whole.statistics)
        #expect(streamed.failures.map(\.gameNumber) == whole.failures.map(\.gameNumber))
    }

    @Test func aRepeatedPositionCountsOncePerGame() throws {
        var builder = PolyglotBookBuilder(options: PolyglotBookOptions(minGames: 1, weighting: .popularity))
        builder.add(pgn: "1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 *")
        let book = builder.build()
        #expect(Self.moves(book, Game()) == ["g1f3:1"])
        #expect(builder.statistics.movesRecorded == 4)
    }

    @Test func gamesFromMovesStopAtAnIllegalMove() throws {
        var builder = PolyglotBookBuilder(options: PolyglotBookOptions(minGames: 1))
        let moves = try ["e2e4", "e2e4", "d2d4"].map { try #require(ResolvedMove(uci: $0)) }
        builder.add(moves: moves, result: .win)
        #expect(builder.entries().map(\.move.uci) == ["e2e4"])
    }

    @Test func gamesWithAnUnplayableMoveAreTruncated() throws {
        var builder = PolyglotBookBuilder(options: PolyglotBookOptions(minGames: 1))
        builder.add(pgn: "[Result \"1/2-1/2\"]\n\n1. e4 e5 2. Ke3 Nc6 1/2-1/2")
        #expect(builder.statistics.gamesTruncated == 1)
        #expect(builder.entries().count == 2)
    }

    @Test func largeWeightsAreScaledTogether() {
        #expect(PolyglotBookBuilder.fitWeights([3, 0, 65_535]) == [3, 0, 65_535])
        #expect(PolyglotBookBuilder.fitWeights([131_070, 65_535, 1, 0]) == [65_535, 32_768, 1, 0])
    }
}

struct PolyglotBookMergerTests {
    static func books() throws -> (PolyglotBook, PolyglotBook) {
        let start = Game()
        let afterE4 = try game("e2e4")
        let first = PolyglotBook(entries: [
            try entry(start, "e2e4", 10, learn: 1),
            try entry(start, "d2d4", 5),
        ])
        let second = PolyglotBook(entries: [
            try entry(start, "e2e4", 3, learn: 2),
            try entry(start, "c2c4", 2),
            try entry(afterE4, "e7e5", 7),
        ])
        return (first, second)
    }

    @Test func preferFirstKeepsTheFirstBooksPositions() throws {
        let (first, second) = try Self.books()
        let merged = first.merged(with: second, strategy: .preferFirst)
        #expect(PolyglotBookBuilderTests.moves(merged, Game()) == ["e2e4:10", "d2d4:5"])
        #expect(PolyglotBookBuilderTests.moves(merged, try game("e2e4")) == ["e7e5:7"])
        #expect(merged.count == 3)
    }

    @Test func sumWeightsAddsTheSameMoves() throws {
        let (first, second) = try Self.books()
        let merged = first.merged(with: second, strategy: .sumWeights)
        #expect(PolyglotBookBuilderTests.moves(merged, Game()) == ["e2e4:13", "d2d4:5", "c2c4:2"])
        #expect(merged.moves(for: Game()).first?.learn == 1)
        #expect(PolyglotBookBuilderTests.moves(merged, try game("e2e4")) == ["e7e5:7"])
        #expect(merged.count == 4)
    }

    @Test func summedWeightsAreScaledWhenTheyOverflow() throws {
        let start = Game()
        let first = PolyglotBook(entries: [try entry(start, "e2e4", 60_000)])
        let second = PolyglotBook(entries: [try entry(start, "e2e4", 60_000), try entry(start, "d2d4", 30_000)])
        let merged = first.merged(with: second, strategy: .sumWeights)
        #expect(PolyglotBookBuilderTests.moves(merged, start) == ["e2e4:65535", "d2d4:16384"])
    }

    @Test func mergingWithAnEmptyBookKeepsTheOther() throws {
        let (first, _) = try Self.books()
        let empty = PolyglotBook(entries: [])
        #expect(first.merged(with: empty).data == first.data)
        #expect(empty.merged(with: first, strategy: .sumWeights).data == first.data)
    }
}
