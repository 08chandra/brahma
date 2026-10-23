import Foundation

/// FNV-1a 64 as 16 lowercase hex digits. Stable across runs and platforms, unlike `Hasher`.
public enum StableHash {
    public static func fnv1a64(_ text: String) -> String { fnv1a64(Data(text.utf8)) }

    public static func fnv1a64(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
