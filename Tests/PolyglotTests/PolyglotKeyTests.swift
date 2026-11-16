//
//  PolyglotKeyTests.swift
//  PolyglotSwiftSDK
//
//  The test keys of the format description (http://hgm.nubati.net/book_format.html, "Test data"), computed with
//  Toga II. They cover castling rights, an en passant target that counts and one that does not.
//

import FischerCore
import Testing
@testable import Polyglot

struct PolyglotKeyTests {
    static let specification: [(fen: String, key: UInt64)] = [
        ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 0x463B96181691FC9C),
        ("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1", 0x823C9B50FD114196),
        ("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2", 0x0756B94461C50FB0),
        ("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2", 0x662FAFB965DB29D4),
        ("rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3", 0x22A48B5A8E47FF78),
        ("rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPPKPPP/RNBQ1BNR b kq - 0 3", 0x652A607CA3F242C1),
        ("rnbq1bnr/ppp1pkpp/8/3pPp2/8/8/PPPPKPPP/RNBQ1BNR w - - 0 4", 0x00FDD303C946BDD9),
        ("rnbqkbnr/p1pppppp/8/8/PpP4P/8/1P1PPPP1/RNBQKBNR b KQkq c3 0 3", 0x3C8123EA7B067637),
        ("rnbqkbnr/p1pppppp/8/8/P6P/R1p5/1P1PPPP1/1NBQKBNR b Kkq - 0 4", 0x5C3F9B829B279560),
    ]

    @Test(arguments: specification.indices)
    func keyMatchesTheSpecification(_ index: Int) throws {
        let sample = Self.specification[index]
        let position = try #require(Position(fen: sample.fen))
        #expect(PolyglotKey.key(for: position) == sample.key)
        #expect(PolyglotKey.key(fen: sample.fen) == sample.key)
    }

    @Test func randomTableHasEveryValue() {
        #expect(PolyglotRandom.values.count == 781)
        #expect(PolyglotRandom.values.first == 0x9D39247E33776D41)
        #expect(PolyglotRandom.values[PolyglotRandom.castlingOffset] == 0x31D71DCE64B2C310)
        #expect(PolyglotRandom.values[PolyglotRandom.enPassantOffset] == 0x70CC73D90BC26E24)
        #expect(PolyglotRandom.values.last == 0xF8D626AAAF278509)
        #expect(Set(PolyglotRandom.values).count == 781)
    }

    /// The move sequences the specification gives for its test positions, played with FischerCore. FischerCore sets
    /// an en passant target after every double push; the key must ignore it unless a pawn can capture.
    @Test func playedMovesGiveTheSpecificationKeys() throws {
        let lines: [(moves: [String], key: UInt64)] = [
            ([], 0x463B96181691FC9C),
            (["e2e4"], 0x823C9B50FD114196),
            (["e2e4", "d7d5"], 0x0756B94461C50FB0),
            (["e2e4", "d7d5", "e4e5"], 0x662FAFB965DB29D4),
            (["e2e4", "d7d5", "e4e5", "f7f5"], 0x22A48B5A8E47FF78),
            (["e2e4", "d7d5", "e4e5", "f7f5", "e1e2"], 0x652A607CA3F242C1),
            (["e2e4", "d7d5", "e4e5", "f7f5", "e1e2", "e8f7"], 0x00FDD303C946BDD9),
            (["a2a4", "b7b5", "h2h4", "b5b4", "c2c4"], 0x3C8123EA7B067637),
            (["a2a4", "b7b5", "h2h4", "b5b4", "c2c4", "b4c3", "a1a3"], 0x5C3F9B829B279560),
        ]
        for line in lines {
            var game = Game()
            for uci in line.moves {
                try game.execute(uci: uci)
            }
            #expect(PolyglotKey.key(for: game) == line.key, "after \(line.moves)")
        }
    }

    @Test func enPassantCountsOnlyWithACapturingPawn() throws {
        let canCapture = try #require(Position(fen: "rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3"))
        #expect(PolyglotKey.enPassantFile(in: canCapture) == 5)
        let blackCaptures = try #require(Position(fen: "rnbqkbnr/p1pppppp/8/8/PpP4P/8/1P1PPPP1/RNBQKBNR b KQkq c3 0 3"))
        #expect(PolyglotKey.enPassantFile(in: blackCaptures) == 2)
        let nobodyNext = try #require(Position(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"))
        #expect(PolyglotKey.enPassantFile(in: nobodyNext) == nil)
        // A pawn next to the pushed one that belongs to the side that pushed does not count.
        let ownPawn = try #require(Position(fen: "4k3/8/8/8/3PP3/8/8/4K3 b - e3 0 1"))
        #expect(PolyglotKey.enPassantFile(in: ownPawn) == nil)
        // Still counts when the capture would be illegal (here it would expose the black king to the rook on h4).
        let pinned = try #require(Position(fen: "4K3/8/8/8/k2pP2R/8/8/8 b - e3 0 1"))
        #expect(PolyglotKey.enPassantFile(in: pinned) == 4)
    }

    @Test func pieceIndexFollowsTheSpecification() {
        let expected: [(Piece, Int)] = [
            (Piece(pawn: .black), 0), (Piece(pawn: .white), 1),
            (Piece(knight: .black), 2), (Piece(knight: .white), 3),
            (Piece(bishop: .black), 4), (Piece(bishop: .white), 5),
            (Piece(rook: .black), 6), (Piece(rook: .white), 7),
            (Piece(queen: .black), 8), (Piece(queen: .white), 9),
            (Piece(king: .black), 10), (Piece(king: .white), 11),
        ]
        for (piece, index) in expected {
            #expect(PolyglotKey.pieceIndex(for: piece) == index)
        }
    }

    @Test func invalidFENHasNoKey() {
        #expect(PolyglotKey.key(fen: "not a position") == nil)
    }
}
