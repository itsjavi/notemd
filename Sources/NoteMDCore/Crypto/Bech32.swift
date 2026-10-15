import Foundation

/// BIP-173 Bech32 as age uses it for keys: no 90-character limit, mixed case rejected.
enum Bech32 {
    enum Error: Swift.Error, Equatable {
        case mixedCase, invalidSeparator, invalidCharacter, invalidChecksum, invalidPadding
    }

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    private static let generator: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]

    /// Encodes `data` under `hrp`, which must be printable ASCII in a single case. The result takes the case of `hrp`.
    static func encode(hrp: String, data: Data) -> String {
        precondition(hrp == hrp.lowercased() || hrp == hrp.uppercased(), "mixed-case Bech32 prefix")
        let lowerHRP = hrp.lowercased()
        let values = toFiveBit(data)
        let checksum = checksum(hrp: Array(lowerHRP.utf8), values: values)
        let encoded = lowerHRP + "1" + String(decoding: (values + checksum).map { charset[Int($0)] }, as: UTF8.self)
        return hrp == lowerHRP ? encoded : encoded.uppercased()
    }

    /// Decodes a Bech32 string. The returned prefix keeps the string's case.
    static func decode(_ string: String) throws -> (hrp: String, data: Data) {
        guard string == string.lowercased() || string == string.uppercased() else { throw Error.mixedCase }
        let bytes = Array(string.utf8)
        guard let separator = bytes.lastIndex(of: UInt8(ascii: "1")), separator >= 1, separator + 7 <= bytes.count else {
            throw Error.invalidSeparator
        }
        let hrp = bytes[..<separator]
        guard hrp.allSatisfy({ (33...126).contains($0) }) else { throw Error.invalidCharacter }
        var values: [UInt8] = []
        for byte in bytes[(separator + 1)...] {
            guard let value = charset.firstIndex(of: lowercased(byte)) else { throw Error.invalidCharacter }
            values.append(UInt8(value))
        }
        guard polymod(expand(hrp.map(lowercased)) + values) == 1 else { throw Error.invalidChecksum }
        guard let data = fromFiveBit(values.dropLast(6)) else { throw Error.invalidPadding }
        return (String(decoding: hrp, as: UTF8.self), Data(data))
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static func expand(_ hrp: [UInt8]) -> [UInt8] {
        hrp.map { $0 >> 5 } + [0] + hrp.map { $0 & 31 }
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var checksum: UInt32 = 1
        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ff_ffff) << 5) ^ UInt32(value)
            for i in 0..<5 where (top >> i) & 1 == 1 { checksum ^= generator[i] }
        }
        return checksum
    }

    private static func checksum(hrp: [UInt8], values: [UInt8]) -> [UInt8] {
        let mod = polymod(expand(hrp) + values + [0, 0, 0, 0, 0, 0]) ^ 1
        return (0..<6).map { UInt8((mod >> (5 * (5 - UInt32($0)))) & 31) }
    }

    private static func toFiveBit(_ data: Data) -> [UInt8] {
        var values: [UInt8] = []
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in data {
            accumulator = ((accumulator << 8) | UInt32(byte)) & 0xfff
            bits += 8
            while bits >= 5 {
                bits -= 5
                values.append(UInt8((accumulator >> UInt32(bits)) & 31))
            }
        }
        if bits > 0 { values.append(UInt8((accumulator << UInt32(5 - bits)) & 31)) }
        return values
    }

    private static func fromFiveBit(_ values: some Sequence<UInt8>) -> [UInt8]? {
        var bytes: [UInt8] = []
        var accumulator: UInt32 = 0
        var bits = 0
        for value in values {
            accumulator = ((accumulator << 5) | UInt32(value)) & 0xfff
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> UInt32(bits)) & 0xff))
            }
        }
        // What's left is padding: fewer than 5 bits, all zero.
        guard bits < 5, accumulator & ((1 << UInt32(bits)) - 1) == 0 else { return nil }
        return bytes
    }
}
