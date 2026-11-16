# PolyglotSwiftSDK

A Swift package (SPM) for **Polyglot opening books** (`.bin`): the Polyglot Zobrist key, a book reader with binary search and weighted picks, and a book builder that turns PGN games into a book, like PolyGlot's `make-book`. It uses [fischer-core](https://github.com/NSStudent/fischer-core) for positions, moves and PGN.

The format follows the description at [hgm.nubati.net/book_format.html](http://hgm.nubati.net/book_format.html).

## Installation

```swift
.package(url: "https://github.com/NSStudent/PolyglotSwiftSDK.git", from: "0.1.0")
```

Then add `.product(name: "Polyglot", package: "PolyglotSwiftSDK")` to your target's dependencies. Requires Swift 6.0 or later, macOS 13 or iOS 16.

## Products

| Product | Kind | Description |
|---|---|---|
| `Polyglot` | library | Zobrist key, book reader, builder and merge |

## The Polyglot key

`PolyglotKey` is a standalone API, so other modules (a position search index, for instance) can index positions with the same key as the books.

```swift
import FischerCore
import Polyglot

PolyglotKey.key(for: Game())                 // 0x463B96181691FC9C
PolyglotKey.key(for: position)               // any FischerCore Position
PolyglotKey.key(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")  // 0x823C9B50FD114196
```

- `PolyglotRandom.values` holds the 781 `Random64` numbers, with `pieceOffset`, `castlingOffset`, `enPassantOffset` and `turnOffset`.
- `PolyglotKey.pieceIndex(for:)` gives Polyglot's `kind_of_piece` (black pawn 0 … white king 11). FischerCore orders its piece kinds differently, so the mapping is explicit.
- `PolyglotKey.enPassantFile(in:)` implements the Polyglot en passant rule: the file only counts when a pawn of the side to move stands next to the pawn that has just moved two squares. Unlike FEN, the target square alone is not enough. Whether the capture would be legal does not matter.

## Reading books

```swift
let book = try PolyglotBook(contentsOf: bookURL)    // memory mapped

for move in book.moves(for: game) {                 // decoded, legal moves in file order
    print(move.uci, move.weight, move.share)        // "e1g1" 120 0.4
}

let best = book.pick(.best, for: game)              // highest weight
let played = book.pick(.weighted, for: game)        // random, proportional to weight (PolyGlot's way)
let any = book.pick(.uniform, for: game, using: &generator)
```

- Entries are 16-byte big-endian records (`key`, `move`, `weight`, `learn`). `PolyglotBook` is a random-access collection of `PolyglotEntry` values, and lookups use binary search (`range(for:)`, `entries(for:)`).
- Opening a book checks that the size is a whole number of entries and that the keys are in order. Pass `validatesOrder: false` to skip the order check on a large trusted book.
- Moves are decoded into FischerCore `ResolvedMove`s. Castling is stored as the king taking its own rook (`e1h1`) and decoded as the king move (`e1g1`); promotions carry their piece (`a7b8n`). Null moves (`a1a1`) and moves that are not legal in the position are left out.
- Picks never choose a move with weight 0 (some books mark moves to avoid that way).
- `PolyglotMove(_:in:)` encodes a FischerCore move the Polyglot way, and `PolyglotMove.resolved(in:)` decodes one.

## Building books

```swift
var builder = PolyglotBookBuilder(options: PolyglotBookOptions(
    maxPly: 30,              // only the first 30 half-moves of each game
    minGames: 3,             // drop moves played in fewer than 3 games
    colors: .both,           // or .white / .black: only that side's moves
    weighting: .polyglot     // win 2, draw 1, loss 0 for the side that moved
))
try builder.add(contentsOf: pgnURL)    // streamed with PGNByteChunker
try builder.build().write(to: bookURL)

print(builder.statistics)              // games added, truncated and skipped
print(builder.failures)                // skipped games: number, byte offset and reason
```

- PGN is read one game at a time with fischer-core's `PGNByteChunker`, so memory use depends on the book, not on the size of the file. `add(pgn:)`, `add(pgnData:)`, `add(_: AnnotatedPGNGame)` and `add(moves:from:result:)` take other inputs.
- Only the main line is used. Games that cannot be read, and games in a variant other than standard chess (`[Variant "Chess960"]`), are skipped and listed in `failures`. A game with an illegal move is used up to that move and counted in `statistics.gamesTruncated`. Games may start from a `FEN` tag.
- Weighting: `.polyglot` (2/1/0), `.popularity` (the number of games), `.results(win:draw:loss:)` for custom points, or `.uniform` (every move weight 1, PolyGlot's `-uniform`). Games without a result (`*`) count as draws, as in PolyGlot.
- Moves with weight 0 are dropped, as in PolyGlot, unless `keepsZeroWeights` is set.
- When the weights of a position do not fit in 16 bits, they are scaled down together, so their ratios are kept and no positive weight becomes 0.
- Entries are sorted by key, then by weight (highest first), then by move, so builds are deterministic.

The defaults (`maxPly` 1024, `minGames` 3, both colours, 2/1/0 weights) are PolyGlot's. One difference: a position and move repeated within the same game count once for that game, so `minGames` really counts games.

## Merging books

```swift
let merged = first.merged(with: second)                           // PolyGlot's merge-book
let summed = first.merged(with: second, strategy: .sumWeights)
```

- `.preferFirst`: a position in the first book keeps only the first book's moves; the second book only adds positions the first lacks. This is what PolyGlot's `merge-book` does.
- `.sumWeights`: every move of both books is kept, and a move in both books gets the sum of its weights (scaled down when a position overflows 16 bits).

Both books are read in a single pass.

## Implementation status

**Supported**

- Polyglot Zobrist key with the 781 `Random64` values and the Polyglot en passant rule. It matches all nine test keys of the format description, from FEN and from played moves.
- Reading `.bin` books: memory mapping, validation, binary search, decoding moves (castling as king-takes-rook, promotions, null moves) into legal FischerCore moves, best, weighted and uniform picks with any `RandomNumberGenerator`.
- Writing books: entry encoding, sorting and `write(to:)`.
- Building books from PGN with maximum ply, minimum game count, colour filter, result-based, popularity or uniform weights, streaming input and skipping unreadable games.
- Merging two books (PolyGlot's priority to the first book, or summed weights).

Checked against real books: walking five ECO opening books 12 plies deep from the start position decodes every entry found (over 70,000 book moves, including castling) with no failures.

**Not yet implemented**

- The Chess960 extension of the format (castling as king-takes-rook in any start position). Chess960 games are skipped when building, and decoding only handles standard castling.
- The `learn` field is read and written but nothing computes it; built books write 0, as PolyGlot does.
- No command-line tool yet.
- Build speed: each game is read with fischer-core's annotated PGN reader, which takes most of the build time (a few milliseconds per game). A lighter main-line reader would make large databases faster.

## Development

```bash
swift build
swift test
```

## License

MIT. See [LICENSE](LICENSE).

The one exception is data, not code: the 781 `Random64` numbers in `Sources/Polyglot/PolyglotRandom.swift` come from the [Polyglot format description](http://hgm.nubati.net/book_format.html), which takes them from the GPL source code of PolyGlot. The description states that the table is not believed to be covered by copyright and that the format may be implemented freely, including in closed-source programs. The table is included only so that keys match existing books, and the MIT license does not claim any rights over it. No PolyGlot code is included. See the note at the end of [LICENSE](LICENSE).
