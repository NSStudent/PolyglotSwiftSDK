//
//  PolyglotMoveTests.swift
//  PolyglotSwiftSDK
//

import FischerCore
import Testing
@testable import Polyglot

struct PolyglotMoveTests {
    @Test func bitsFollowTheSpecification() throws {
        // e2e4: from row 1 file 4 (12), to row 3 file 4 (28).
        let move = try #require(PolyglotMove(uci: "e2e4"))
        #expect(move.rawValue == 12 << 6 | 28)
        #expect(move.from == .e2)
        #expect(move.to == .e4)
        #expect(move.promotion == nil)
        #expect(move.uci == "e2e4")
        // h7h8 promoting to a queen: code 4 in bits 12–14.
        let promotion = try #require(PolyglotMove(uci: "h7h8q"))
        #expect(promotion.rawValue == 4 << 12 | 55 << 6 | 63)
        #expect(PolyglotMove(rawValue: promotion.rawValue).promotion == .queen)
        #expect(PolyglotMove(rawValue: 1 << 12 | 55 << 6 | 63).uci == "h7h8n")
        #expect(PolyglotMove(rawValue: 2 << 12 | 55 << 6 | 63).uci == "h7h8b")
        #expect(PolyglotMove(rawValue: 3 << 12 | 55 << 6 | 63).uci == "h7h8r")
    }

    @Test func malformedUCIIsRejected() {
        #expect(PolyglotMove(uci: "e2") == nil)
        #expect(PolyglotMove(uci: "e2e9") == nil)
        #expect(PolyglotMove(uci: "e7e8k") == nil)
    }

    @Test func nullMoveIsIgnored() {
        #expect(PolyglotMove.null.isNull)
        #expect(PolyglotMove.null.uci == "a1a1")
        #expect(PolyglotMove.null.resolved(in: Game()) == nil)
    }

    // MARK: Castling

    static let castlingFEN = "r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R3K2R w KQkq - 0 1"

    @Test(arguments: [
        ("w", "e1h1", "e1g1"),
        ("w", "e1a1", "e1c1"),
        ("b", "e8h8", "e8g8"),
        ("b", "e8a8", "e8c8"),
    ])
    func castlingIsDecodedFromKingTakesRook(side: String, stored: String, played: String) throws {
        let fen = Self.castlingFEN.replacingOccurrences(of: " w ", with: " \(side) ")
        let game = try Game(with: fen)
        let move = try #require(PolyglotMove(uci: stored))
        let resolved = try #require(move.resolved(in: game))
        #expect(resolved.uci == played)
        #expect(resolved.move.isCastle())
        // And back: the castling move is stored king-takes-rook.
        #expect(PolyglotMove(resolved, in: game.position) == move)
    }

    @Test func castlingWithoutTheRightIsNotDecoded() throws {
        let game = try Game(with: "r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R3K2R w Qkq - 0 1")
        #expect(try #require(PolyglotMove(uci: "e1h1")).resolved(in: game) == nil)
        #expect(try #require(PolyglotMove(uci: "e1a1")).resolved(in: game)?.uci == "e1c1")
    }

    @Test func kingMovesNextToTheRookAreNotCastling() throws {
        // Without a rook on h1, e1h1 is just an illegal king move.
        let game = try Game(with: "4k3/8/8/8/8/8/8/R3K3 w Q - 0 1")
        #expect(try #require(PolyglotMove(uci: "e1h1")).resolved(in: game) == nil)
        // A one-square king move is encoded as it is.
        let step = try #require(game.resolvedMove(uci: "e1f1"))
        #expect(PolyglotMove(step, in: game.position).uci == "e1f1")
    }

    // MARK: Promotions

    @Test(arguments: [("q", PromotionPiece.queen), ("r", .rook), ("b", .bishop), ("n", .knight)])
    func promotionsAreDecoded(letter: String, piece: PromotionPiece) throws {
        let game = try Game(with: "1r2k3/P7/8/8/8/8/8/4K3 w - - 0 1")
        let push = try #require(PolyglotMove(uci: "a7a8\(letter)")).resolved(in: game)
        #expect(push?.uci == "a7a8\(letter)")
        #expect(push?.promotion == piece)
        let capture = try #require(PolyglotMove(uci: "a7b8\(letter)")).resolved(in: game)
        #expect(capture?.promotion == piece)
        // And back.
        let resolved = try #require(capture)
        #expect(PolyglotMove(resolved, in: game.position).uci == "a7b8\(letter)")
    }

    @Test func blackPromotionsAreDecoded() throws {
        let game = try Game(with: "4k3/8/8/8/8/8/p7/4K3 b - - 0 1")
        let move = try #require(PolyglotMove(uci: "a2a1n")).resolved(in: game)
        #expect(move?.uci == "a2a1n")
    }

    @Test func promotionCodesMustMatchTheMove() throws {
        let game = try Game(with: "1r2k3/P7/8/8/8/8/8/4K3 w - - 0 1")
        // A pawn reaching the last rank without a promotion piece is not a valid book move.
        #expect(PolyglotMove(rawValue: 48 << 6 | 56).resolved(in: game) == nil)
        // A promotion code on a move that does not promote is not either.
        #expect(PolyglotMove(rawValue: 4 << 12 | 4 << 6 | 12).resolved(in: game) == nil)
    }

    @Test func illegalMovesAreNotDecoded() throws {
        #expect(try #require(PolyglotMove(uci: "e2e5")).resolved(in: Game()) == nil)
        #expect(try #require(PolyglotMove(uci: "e7e5")).resolved(in: Game()) == nil)
        let position = try #require(Position(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"))
        #expect(try #require(PolyglotMove(uci: "e7e5")).resolved(in: position)?.uci == "e7e5")
    }
}
