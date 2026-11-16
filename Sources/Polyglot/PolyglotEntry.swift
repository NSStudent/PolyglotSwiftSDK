//
//  PolyglotEntry.swift
//  PolyglotSwiftSDK
//
//  One 16-byte record of a `.bin` book. All integers are big-endian:
//
//      key     UInt64
//      move    UInt16
//      weight  UInt16
//      learn   UInt32
//

import Foundation

/// One entry of a Polyglot book: a move in the position with `key`.
public struct PolyglotEntry: Hashable, Sendable {
    /// The size of an entry in a `.bin` file.
    public static let byteCount = 16

    public var key: UInt64
    public var move: PolyglotMove
    public var weight: UInt16
    /// Free for learning data; PolyGlot writes 0.
    public var learn: UInt32

    public init(key: UInt64, move: PolyglotMove, weight: UInt16, learn: UInt32 = 0) {
        self.key = key
        self.move = move
        self.weight = weight
        self.learn = learn
    }

    /// Decodes an entry from the first 16 bytes of `bytes`.
    public init<Bytes: Collection>(bytes: Bytes) where Bytes.Element == UInt8 {
        var iterator = bytes.makeIterator()
        func read<T: FixedWidthInteger>(_: T.Type) -> T {
            var value: T = 0
            for _ in 0..<MemoryLayout<T>.size {
                value = value << 8 | T(iterator.next() ?? 0)
            }
            return value
        }
        key = read(UInt64.self)
        move = PolyglotMove(rawValue: read(UInt16.self))
        weight = read(UInt16.self)
        learn = read(UInt32.self)
    }

    /// The 16 bytes of the entry.
    public var bytes: [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(Self.byteCount)
        func append<T: FixedWidthInteger>(_ value: T) {
            for shift in stride(from: (MemoryLayout<T>.size - 1) * 8, through: 0, by: -8) {
                result.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        append(key)
        append(move.rawValue)
        append(weight)
        append(learn)
        return result
    }

    /// The order of entries in a book: by key, then by weight (highest first), then by move.
    ///
    /// The format only requires the keys to be sorted; the rest makes the output deterministic and puts the main
    /// move of each position first, as PolyGlot does.
    public static func bookOrder(_ lhs: PolyglotEntry, _ rhs: PolyglotEntry) -> Bool {
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        return lhs.move.rawValue < rhs.move.rawValue
    }
}
