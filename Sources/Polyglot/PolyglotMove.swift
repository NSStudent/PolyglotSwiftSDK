//
//  PolyglotMove.swift
//  PolyglotSwiftSDK
//
//  The 16-bit move of a book entry:
//
//      bits  0–2   to file        bits  6–8   from file      bits 12–14  promotion piece
//      bits  3–5   to row         bits  9–11  from row                   (none 0, n 1, b 2, r 3, q 4)
//
//  Castling is written as the king taking its own rook (`e1h1`, `e1a1`, `e8h8`, `e8a8`), and the move 0 (`a1a1`)
//  means "no move" and is ignored.
//

import FischerCore

/// A move as stored in a Polyglot book.
public struct PolyglotMove: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Encodes the squares and promotion piece as they are, without any castling conversion.
    public init(from: Square, to: Square, promotion: PromotionPiece? = nil) {
        let code: UInt16
        switch promotion {
        case nil: code = 0
        case .knight: code = 1
        case .bishop: code = 2
        case .rook: code = 3
        case .queen: code = 4
        }
        rawValue = code << 12 | UInt16(from.rawValue) << 6 | UInt16(to.rawValue)
    }

    /// Parses a move written in UCI (`e2e4`, `e7e8q`), as the book would store it: castling must already be written
    /// king-takes-rook. Returns `nil` for malformed text.
    public init?(uci: String) {
        let text = uci.lowercased()
        guard text.count == 4 || text.count == 5,
              let from = Square(String(text.prefix(2))),
              let to = Square(String(text.dropFirst(2).prefix(2)))
        else { return nil }
        var promotion: PromotionPiece?
        if text.count == 5 {
            switch text.last {
            case "n": promotion = .knight
            case "b": promotion = .bishop
            case "r": promotion = .rook
            case "q": promotion = .queen
            default: return nil
            }
        }
        self.init(from: from, to: to, promotion: promotion)
    }

    /// The null move (`a1a1`), which readers ignore.
    public static let null = PolyglotMove(rawValue: 0)

    /// Whether the origin and destination are the same square, which covers the null move `a1a1`.
    public var isNull: Bool { from == to }

    public var from: Square { Square(rawValue: Int(rawValue >> 6 & 0x3F))! }

    public var to: Square { Square(rawValue: Int(rawValue & 0x3F))! }

    /// The promotion piece, or `nil` when the code is 0. Codes 5–7 are not defined and also read as `nil`.
    public var promotion: PromotionPiece? {
        switch rawValue >> 12 & 0x7 {
        case 1: .knight
        case 2: .bishop
        case 3: .rook
        case 4: .queen
        default: nil
        }
    }

    /// The move in UCI exactly as stored (castling stays king-takes-rook, e.g. `e1h1`).
    public var uci: String {
        "\(from)\(to)\(promotion?.uciValue ?? "")"
    }

    public var description: String { uci }
}

// MARK: - Converting to and from FischerCore moves

extension PolyglotMove {
    /// Encodes a legal FischerCore move played in `position`.
    ///
    /// Castling (the king moving two squares from its starting square) becomes the king taking its own rook.
    public init(_ move: ResolvedMove, in position: Position) {
        var to = move.move.end
        let start = move.move.start
        if let piece = position.board[start], piece.kind == .king,
           start.file == .e, start.rank == Rank(startFor: piece.color), start.rank == to.rank {
            if to.file == .g {
                to = Square(file: .h, rank: to.rank)
            } else if to.file == .c {
                to = Square(file: .a, rank: to.rank)
            }
        }
        self.init(from: start, to: to, promotion: move.promotion)
    }

    /// Decodes the move for the side to move in `game`.
    ///
    /// The king taking its own rook from its starting square becomes the castling move. Returns `nil` for the null
    /// move, a promotion without a valid promotion piece (or a promotion code on a non-promoting move), and any move
    /// that is not legal in the position.
    public func resolved(in game: Game) -> ResolvedMove? {
        guard !isNull else { return nil }
        let board = game.position.board
        let color = game.playerTurn
        var end = to
        if board[from] == Piece(king: color), board[to] == Piece(rook: color),
           from.file == .e, from.rank == Rank(startFor: color), to.rank == from.rank,
           to.file == .h || to.file == .a {
            end = Square(file: to.file == .h ? .g : .c, rank: from.rank)
        }
        let move = from >>> end
        guard game.isLegal(move: move, considerHalfmoves: false) else { return nil }
        if game.requiresPromotion(move: move) {
            guard let promotion else { return nil }
            return ResolvedMove(move: move, promotion: promotion)
        }
        guard rawValue >> 12 == 0 else { return nil }
        return ResolvedMove(move: move)
    }

    /// Decodes the move in `position`. See ``resolved(in:)-(Game)``.
    public func resolved(in position: Position) -> ResolvedMove? {
        guard let game = try? Game(position: position) else { return nil }
        return resolved(in: game)
    }
}
