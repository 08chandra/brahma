import Foundation

/// SHA-1, incremental, pure Swift (Linux-portable; no CryptoKit): git's object id in a SHA-1 repository, computed in the engine
/// for a worktree file so an unchanged file never leaves the engine (`SafeGit.worktreeDiff`). Not for security: git's own
/// naming, nothing more.
public struct SHA1 {
    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0)
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        length &+= UInt64(bytes.count)
        var offset = 0
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[0..<take]))
            offset = take
            guard buffer.count == 64 else { return }
            buffer.withUnsafeBytes { compress($0.baseAddress!) }
            buffer.removeAll(keepingCapacity: true)
        }
        while bytes.count - offset >= 64 {
            compress(UnsafeRawPointer(base + offset))
            offset += 64
        }
        if offset < bytes.count { buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[offset...])) }
    }

    public mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }

    public mutating func finalize() -> [UInt8] {
        var tail = buffer + [0x80]
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8((bits >> UInt64(shift)) & 0xFF)) }
        tail.withUnsafeBytes { p in
            var offset = 0
            while offset < tail.count { compress(p.baseAddress! + offset); offset += 64 }
        }
        buffer = []
        var out: [UInt8] = []
        for word in [h.0, h.1, h.2, h.3, h.4] { for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8((word >> UInt32(shift)) & 0xFF)) } }
        return out
    }

    public static func hex(digest: [UInt8]) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private mutating func compress(_ block: UnsafeRawPointer) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 80) { w in
            for i in 0..<16 { w[i] = UInt32(bigEndian: block.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self)) }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = x << 1 | x >> 31
            }
            var (a, b, c, d, e) = h
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let t = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = b << 30 | b >> 2; b = a; a = t
            }
            h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
        }
    }
}
