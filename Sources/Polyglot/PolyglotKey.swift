//
//  PolyglotKey.swift
//  PolyglotSwiftSDK
//
//  The 64-bit Zobrist key that Polyglot books are sorted by
//  (http://hgm.nubati.net/book_format.html):
//
//      key = piece ^ castle ^ enpassant ^ turn
//
//  FischerCore orders its piece kinds pawn, knight, bishop, queen, rook, king; Polyglot uses pawn, knight, bishop,
//  rook, queen, king and puts black before white, so the mapping is explicit. The key is a standalone API so that
//  other modules (a position search index, for instance) can share it with the books.
//

import FischerCore

/// Computes Polyglot keys.
public enum PolyglotKey {
    /// The Polyglot key of `position`.
    public static func key(for position: Position) -> UInt64 {
        PolyglotRandom.values.withUnsafeBufferPointer { random in
            var key: UInt64 = 0
            let board = position.board
            for color in [PlayerColor.white, .black] {
                for kind in Piece.Kind.allCases {
                    let piece = Piece(kind: kind, color: color)
                    let base = PolyglotRandom.pieceOffset + 64 * pieceIndex(for: piece)
                    for square in board.bitboard(for: piece) {
                        key ^= random[base + square.rawValue]
                    }
                }
            }
            let rights = position.castlingRights
            if rights.contains(.whiteKingside) { key ^= random[PolyglotRandom.castlingOffset] }
            if rights.contains(.whiteQueenside) { key ^= random[PolyglotRandom.castlingOffset + 1] }
            if rights.contains(.blackKingside) { key ^= random[PolyglotRandom.castlingOffset + 2] }
            if rights.contains(.blackQueenside) { key ^= random[PolyglotRandom.castlingOffset + 3] }
            if let file = enPassantFile(in: position) {
                key ^= random[PolyglotRandom.enPassantOffset + file]
            }
            if position.playerTurn == .white {
                key ^= random[PolyglotRandom.turnOffset]
            }
            return key
        }
    }

    /// The Polyglot key of the current position of `game`.
    public static func key(for game: Game) -> UInt64 {
        key(for: game.position)
    }

    /// The Polyglot key of the position described by `fen`, or `nil` when the FEN is not valid.
    public static func key(fen: String) -> UInt64? {
        Position(fen: fen).map { key(for: $0) }
    }

    /// Polyglot's `kind_of_piece`: black pawn 0, white pawn 1, black knight 2, … white king 11.
    public static func pieceIndex(for piece: Piece) -> Int {
        let type: Int
        switch piece.kind {
        case .pawn: type = 0
        case .knight: type = 1
        case .bishop: type = 2
        case .rook: type = 3
        case .queen: type = 4
        case .king: type = 5
        }
        return 2 * type + (piece.color == .white ? 1 : 0)
    }

    /// The file (0 = a … 7 = h) that enters the key for en passant, if any.
    ///
    /// Polyglot only counts en passant when the opponent has just pushed a pawn two squares and a pawn of the side to
    /// move stands next to it. Unlike FEN, the target square alone is not enough. Whether the capture would be legal
    /// (a pinned capturer, for instance) does not matter.
    public static func enPassantFile(in position: Position) -> Int? {
        guard let target = position.enPassantTarget else { return nil }
        let file = target.rawValue & 7
        // The pawn that moved two squares stands on the 5th rank (index 4) when white is to move, on the 4th
        // otherwise; a capturing pawn has to stand on the same rank next to it.
        let rank = position.playerTurn == .white ? 4 : 3
        let capturer = Piece(kind: .pawn, color: position.playerTurn)
        for neighbour in [file - 1, file + 1] where (0..<8).contains(neighbour) {
            guard let square = Square(rawValue: rank * 8 + neighbour) else { continue }
            if position.board[square] == capturer {
                return file
            }
        }
        return nil
    }
}
