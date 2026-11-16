//
//  PolyglotBookBuilder.swift
//  PolyglotSwiftSDK
//
//  Builds a book from PGN games, like PolyGlot's `make-book`: every position of each game's main line (up to a
//  maximum ply) records the move played there, together with the number of games and a score for the side that
//  played it. Moves played in too few games are dropped and the score becomes the weight.
//

import FischerCore
import Foundation

/// The side whose moves enter the book.
public enum PolyglotColorFilter: Sendable, Equatable {
    /// Moves of both sides (PolyGlot's default).
    case both
    /// Only white's moves (PolyGlot's `-only-white`).
    case white
    /// Only black's moves (PolyGlot's `-only-black`).
    case black

    func includes(_ color: PlayerColor) -> Bool {
        switch self {
        case .both: true
        case .white: color == .white
        case .black: color == .black
        }
    }
}

/// How the weight of a move is computed from the games that played it.
public enum PolyglotWeighting: Sendable, Equatable {
    /// Each game adds points by its result for the side that played the move. Games without a result (`*`) count
    /// as draws, as in PolyGlot.
    case results(win: Int, draw: Int, loss: Int)
    /// Every move that is kept gets weight 1 (PolyGlot's `-uniform`).
    case uniform

    /// PolyGlot's weighting: 2 points for a win, 1 for a draw, 0 for a loss.
    public static let polyglot = PolyglotWeighting.results(win: 2, draw: 1, loss: 0)
    /// The number of games that played the move.
    public static let popularity = PolyglotWeighting.results(win: 1, draw: 1, loss: 1)
}

/// Options of ``PolyglotBookBuilder``. The defaults are PolyGlot's.
public struct PolyglotBookOptions: Sendable, Equatable {
    /// Only the first `maxPly` half-moves of each game enter the book.
    public var maxPly: Int
    /// Moves played in fewer games are left out.
    public var minGames: Int
    /// The side whose moves enter the book.
    public var colors: PolyglotColorFilter
    /// How the weight is computed.
    public var weighting: PolyglotWeighting
    /// Keeps moves whose weight is 0 (only losses, with ``PolyglotWeighting/polyglot``). PolyGlot drops them.
    public var keepsZeroWeights: Bool

    public init(
        maxPly: Int = 1024,
        minGames: Int = 3,
        colors: PolyglotColorFilter = .both,
        weighting: PolyglotWeighting = .polyglot,
        keepsZeroWeights: Bool = false
    ) {
        self.maxPly = maxPly
        self.minGames = minGames
        self.colors = colors
        self.weighting = weighting
        self.keepsZeroWeights = keepsZeroWeights
    }
}

/// A game that could not be used.
public struct PolyglotGameFailure: Equatable, Sendable, CustomStringConvertible {
    /// The game's number among all the games given to the builder, from 1.
    public var gameNumber: Int
    /// Where the game starts in its PGN input, when it was read from PGN.
    public var byteOffset: Int64?
    public var reason: String

    public init(gameNumber: Int, byteOffset: Int64?, reason: String) {
        self.gameNumber = gameNumber
        self.byteOffset = byteOffset
        self.reason = reason
    }

    public var description: String {
        let place = byteOffset.map { " (byte \($0))" } ?? ""
        return "game \(gameNumber)\(place): \(reason)"
    }
}

/// Counts of what the builder has read.
public struct PolyglotBuildStatistics: Equatable, Sendable {
    /// Games whose moves were added.
    public var gamesAdded = 0
    /// Games added only up to a move that could not be played.
    public var gamesTruncated = 0
    /// Games that could not be read or use an unsupported variant. They are listed in
    /// ``PolyglotBookBuilder/failures``.
    public var gamesSkipped = 0
    /// Moves recorded, before filtering.
    public var movesRecorded = 0

    public init() {}
}

/// Builds a Polyglot book from games.
///
/// ```swift
/// var builder = PolyglotBookBuilder(options: .init(maxPly: 20, minGames: 2))
/// try builder.add(contentsOf: pgnURL)
/// try builder.build().write(to: bookURL)
/// ```
public struct PolyglotBookBuilder: Sendable {
    public var options: PolyglotBookOptions
    public private(set) var statistics = PolyglotBuildStatistics()
    /// The games that were skipped, in input order.
    public private(set) var failures: [PolyglotGameFailure] = []

    private struct Slot: Hashable {
        var key: UInt64
        var move: PolyglotMove
    }

    private struct Tally {
        var games = 0
        var score = 0
    }

    private var tallies: [Slot: Tally] = [:]
    private var gameCount = 0

    public init(options: PolyglotBookOptions = PolyglotBookOptions()) {
        self.options = options
    }

    // MARK: Adding games

    /// Adds the main line of `moves`, played from `start`, with the game's `result`.
    ///
    /// Moves after the first one that is not legal are ignored. A position and move repeated within the same game
    /// count once for that game.
    public mutating func add(moves: [ResolvedMove], from start: Game = Game(), result: PGNOutcome) {
        gameCount += 1
        record(moves: moves, from: start, result: result)
    }

    /// Adds the main line of a game read with FischerCore.
    public mutating func add(_ game: AnnotatedPGNGame) {
        gameCount += 1
        add(game, number: gameCount, byteOffset: nil)
    }

    /// Adds every game of a PGN text. Games that cannot be read are skipped and listed in ``failures``.
    public mutating func add(pgn text: String) {
        add(pgnData: Data(text.utf8))
    }

    /// Adds every game of PGN bytes (UTF-8, or Latin-1 line by line).
    public mutating func add(pgnData: Data) {
        var chunker = PGNByteChunker()
        add(chunker.consume(pgnData))
        add(chunker.finish())
    }

    /// Adds every game of a PGN file, reading it in blocks of `blockSize` bytes.
    ///
    /// Memory use depends on the book being built, not on the size of the file.
    public mutating func add(contentsOf url: URL, blockSize: Int = 1 << 20) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var chunker = PGNByteChunker()
        while let block = try handle.read(upToCount: blockSize), !block.isEmpty {
            add(chunker.consume(block))
        }
        add(chunker.finish())
    }

    private mutating func add(_ chunks: [PGNGameChunk]) {
        for chunk in chunks {
            gameCount += 1
            do {
                let game = try chunk.annotatedGame()
                add(game, number: gameCount, byteOffset: chunk.startByteOffset)
            } catch {
                // A variant start position (Shredder-FEN castling, for instance) fails to parse; name the variant.
                var reason = String(describing: error)
                if let variant = (try? chunk.basicGame())?[.variant], !Self.isStandard(variant: variant) {
                    reason = "unsupported variant \(variant)"
                }
                skip(gameCount, byteOffset: chunk.startByteOffset, reason: reason)
            }
        }
    }

    private mutating func add(_ game: AnnotatedPGNGame, number: Int, byteOffset: Int64?) {
        if let variant = game.tags[.variant], !Self.isStandard(variant: variant) {
            skip(number, byteOffset: byteOffset, reason: "unsupported variant \(variant)")
            return
        }
        let start: Game
        do {
            start = game.tree.startsFromStandardPosition ? Game() : try Game(with: game.tree.initialFEN)
        } catch {
            skip(number, byteOffset: byteOffset, reason: "invalid start position \(game.tree.initialFEN)")
            return
        }
        var moves: [ResolvedMove] = []
        var node = game.tree.children.first
        while let current = node, moves.count < options.maxPly {
            moves.append(current.move)
            node = current.children.first
        }
        if !game.issues.isEmpty {
            statistics.gamesTruncated += 1
        }
        record(moves: moves, from: start, result: game.result)
    }

    private mutating func skip(_ number: Int, byteOffset: Int64?, reason: String) {
        statistics.gamesSkipped += 1
        failures.append(PolyglotGameFailure(gameNumber: number, byteOffset: byteOffset, reason: reason))
    }

    private mutating func record(moves: [ResolvedMove], from start: Game, result: PGNOutcome) {
        statistics.gamesAdded += 1
        var game = start
        var seen: Set<Slot> = []
        for move in moves.prefix(options.maxPly) {
            guard game.isLegal(move: move.move, considerHalfmoves: false) else { break }
            let position = game.position
            if options.colors.includes(position.playerTurn) {
                let slot = Slot(key: PolyglotKey.key(for: position), move: PolyglotMove(move, in: position))
                if seen.insert(slot).inserted {
                    var tally = tallies[slot, default: Tally()]
                    tally.games += 1
                    tally.score += points(for: result, mover: position.playerTurn)
                    tallies[slot] = tally
                    statistics.movesRecorded += 1
                }
            }
            do {
                try game.execute(resolvedMove: move, considerHalfmoves: false)
            } catch {
                break
            }
        }
    }

    private func points(for result: PGNOutcome, mover: PlayerColor) -> Int {
        guard case let .results(win, draw, loss) = options.weighting else { return 1 }
        switch result {
        case .win: return mover == .white ? win : loss
        case .loss: return mover == .black ? win : loss
        case .draw, .undefined: return draw
        }
    }

    private static func isStandard(variant: String) -> Bool {
        let name = variant.trimmingCharacters(in: .whitespaces).lowercased()
        return ["", "standard", "chess", "normal", "from position"].contains(name)
    }

    // MARK: Building

    /// The entries of the book, in book order.
    ///
    /// Moves played in fewer than ``PolyglotBookOptions/minGames`` games are dropped, and so are moves with weight 0
    /// unless ``PolyglotBookOptions/keepsZeroWeights`` is set. When the weights of a position do not fit in 16 bits,
    /// they are scaled down together so their ratios are kept.
    public func entries() -> [PolyglotEntry] {
        var byKey: [UInt64: [(move: PolyglotMove, score: Int)]] = [:]
        for (slot, tally) in tallies where tally.games >= options.minGames {
            let score = options.weighting == .uniform ? 1 : tally.score
            guard score > 0 || options.keepsZeroWeights else { continue }
            byKey[slot.key, default: []].append((slot.move, score))
        }
        var result: [PolyglotEntry] = []
        result.reserveCapacity(byKey.values.reduce(0) { $0 + $1.count })
        for (key, moves) in byKey {
            let weights = Self.fitWeights(moves.map(\.score))
            for (move, weight) in zip(moves, weights) {
                result.append(PolyglotEntry(key: key, move: move.move, weight: weight))
            }
        }
        return result.sorted(by: PolyglotEntry.bookOrder)
    }

    /// The finished book.
    public func build() -> PolyglotBook {
        PolyglotBook(entries: entries())
    }

    /// Scales scores so the largest fits in a `UInt16`. A positive score never becomes 0.
    static func fitWeights(_ scores: [Int]) -> [UInt16] {
        let limit = Int(UInt16.max)
        let largest = scores.max() ?? 0
        guard largest > limit else { return scores.map { UInt16($0) } }
        return scores.map { score in
            guard score > 0 else { return 0 }
            return UInt16(max(1, Int((Double(score) * Double(limit) / Double(largest)).rounded())))
        }
    }
}
