import Foundation

/// Microsoft Edge Read Aloud protocol token (Sec-MS-GEC), version 2.
///
/// The online voices authenticate the WebSocket handshake with a token derived from the
/// current five minute window. Microsoft replaced the original single SHA-256 digest with a
/// CS64 + digest pair, so the previous value is now rejected with HTTP 403.
///
/// This is a faithful port of the reference implementation shipped with
/// https://github.com/rany2/edge-tts (edge_tts/drm.py, generate_sec_ms_gec_v2).
/// The digest is deliberately not standard SHA-256: seven salt bytes seed the initial
/// state, round 14 uses an adjusted constant and the padded length is offset by 57 bytes.
enum EdgeToken {
    /// Constant tables transcribed from edge-tts edge_tts/drm.py.
    private static let sha256Initial: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]

    private static let sha256State: [UInt32] = [
        0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A, 0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2
    ]

    private static let sha256Schedule: [UInt32] = [
        0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA, 0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6, 0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33, 0xD258B060, 0x72766564
    ]

    private static let sha256RoundConstants: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1,
        0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
        0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786,
        0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147,
        0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
        0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B,
        0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A,
        0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
        0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
    ]

    /// Round 14 uses an adjusted constant, so the token block differs from SHA-256.
    private static let sha256BlockConstants: [UInt32] = {
        var values = sha256RoundConstants
        values[14] = 0xC9DC06A7
        return values
    }()

    private static let sha256Adjustment: UInt32 = 0xC9DC06A7
    private static let sha256Sigma0Adjustment: UInt32 = 0x059C0B80
    private static let sha256Sigma1Adjustment: UInt32 = 0x000B92C0

    private static let cs64Coefficients: [UInt32] = [
        0xE82E91B1, 0x44DE24C6, 0x3BEB65BC, 0xC89C5933, 0x8D1EC211, 0x314EF5D5, 0xE92491B1, 0xF0A5B9D5, 0x06064CF3, 0xDA79FA60, 0xBED20560, 0x89F9C9F8, 0x35FA38C6, 0xCB49E3C6
    ]

    private static let cs64Offsets: [UInt32] = [
        0xB32700D0, 0x88DFF51D, 0x29514038, 0xB328CBDF, 0xD405B4D5, 0x26E55F3C, 0x607801C6, 0x82B2C1FB, 0xFA51A3DA, 0x207CC464, 0x3C3C74F3, 0xD2D14B61, 0xBB04A2C1, 0xC5626167
    ]

    private static let cs64Factor: UInt32 = 0x82893933
    private static let cs64Adjustment0: UInt32 = 0xF2F90B1A
    private static let cs64Adjustment1: UInt32 = 0x0B1A0000

    // MARK: - Token

    /// Public read-aloud protocol salt, not a user credential.
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let windowsEpochOffset: Double = 11_644_473_600
    private static let tokenWindow: Double = 300
    private static let ticksPerSecond: Double = 10_000_000

    /// Sec-MS-GEC for the current time.
    static func secMsGec(now: Date = Date()) -> String {
        secMsGec(unixTimestamp: now.timeIntervalSince1970)
    }

    /// Sec-MS-GEC for a fixed time, so the value stays testable.
    static func secMsGec(unixTimestamp: Double) -> String {
        var ticks = unixTimestamp + windowsEpochOffset
        ticks -= ticks.truncatingRemainder(dividingBy: tokenWindow)
        ticks *= ticksPerSecond
        let salt = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), ticks) + trustedClientToken
        return tokenHash(Data(salt.utf8))
    }

    /// Version 2 token: 16 hex digits of CS64, a hyphen, then 64 hex digits of digest.
    static func tokenHash(_ data: Data) -> String {
        let digest = tokenDigest(data)
        return cs64(data, digest: digest) + "-" + hex(digest)
    }

    // MARK: - Token digest

    /// Salted digest; mirrors _sha256_digest in the reference implementation.
    private static func tokenDigest(_ data: Data) -> Data {
        let length = 57 + data.count
        var padded = Data(data.dropFirst(7))
        padded.append(0x80)
        padded.append(contentsOf: repeatElement(0, count: ((55 - length) % 64 + 64) % 64))
        let bitLength = UInt64(length) * 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }
        var state = initialWords(salt: data.prefix(7))
        for offset in stride(from: 0, to: padded.count, by: 64) {
            var words = (0..<16).map { index in
                bigEndianWord(padded[(offset + index * 4)..<(offset + index * 4 + 4)])
            }
            expandSchedule(&words, from: 16)
            state = zip(state, compress(state: state, words: words, firstRound: 0)).map(&+)
        }
        var output = Data()
        for word in state {
            for shift in stride(from: 24, through: 0, by: -8) {
                output.append(UInt8((word >> UInt32(shift)) & 0xFF))
            }
        }
        return output
    }

    /// Seeds the digest state from the first seven salt bytes instead of the SHA-256 IV.
    private static func initialWords(salt: Data) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 14)
        words.append(bigEndianWord(salt.prefix(3)))
        words.append(bigEndianWord(salt.dropFirst(3).prefix(4)))
        for index in 16..<30 {
            var value = sha256Schedule[index - 16]
            if index - 2 >= 14 {
                let mixed = sigma1(words[index - 2])
                value = value &+ (index == 16 ? mixed ^ sha256Sigma1Adjustment : mixed)
            }
            if index - 7 >= 14 {
                value = value &+ words[index - 7]
            }
            if index - 15 >= 14 {
                let mixed = sigma0(words[index - 15])
                value = value &+ (index == 29 ? mixed ^ sha256Sigma0Adjustment : mixed)
            }
            words.append(value)
        }
        words.append(sigma1(words[28]) &+ words[23] &+ sigma0(words[15]) &+ words[14]
            &+ sha256Adjustment &- sha256RoundConstants[14])
        expandSchedule(&words, from: 31)
        let working = compress(state: sha256State, words: words, firstRound: 14)
        return zip(sha256Initial, working).map(&+)
    }

    /// SHA-256 rounds. Round 14 uses an adjusted constant, and the caller may resume there.
    private static func compress(state: [UInt32], words: [UInt32], firstRound: Int) -> [UInt32] {
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        let constants = firstRound == 14 ? sha256BlockConstants : sha256RoundConstants
        for index in firstRound..<64 {
            let sum1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let choose = g ^ (e & (f ^ g))
            let temp1 = h &+ sum1 &+ choose &+ constants[index] &+ words[index]
            let sum0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let majority = (a & b) | (c & (a | b))
            let temp2 = sum0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        return [a, b, c, d, e, f, g, h]
    }

    private static func expandSchedule(_ words: inout [UInt32], from first: Int) {
        for index in first..<64 {
            let x = words[index - 2], y = words[index - 15]
            let mixed1 = (x >> 17) ^ (x << 15) ^ (x >> 19) ^ (x << 13) ^ (x >> 10)
            let mixed0 = (y >> 7) ^ (y << 25) ^ (y >> 18) ^ (y << 14) ^ (y >> 3)
            words.append(mixed1 &+ words[index - 7] &+ mixed0 &+ words[index - 16])
        }
    }

    private static func sigma0(_ value: UInt32) -> UInt32 {
        (value >> 7) ^ (value << 25) ^ (value >> 18) ^ (value << 14) ^ (value >> 3)
    }

    private static func sigma1(_ value: UInt32) -> UInt32 {
        (value >> 17) ^ (value << 15) ^ (value >> 19) ^ (value << 13) ^ (value >> 10)
    }

    // MARK: - CS64

    /// CS64 digest of the salt, keyed by the first eight digest bytes.
    private static func cs64(_ data: Data, digest: Data) -> String {
        let pair = cs64Words(data, digest: digest)
        var output = ""
        for word in [pair.0, pair.1] {
            for shift in stride(from: 0, through: 24, by: 8) {
                output += String(format: "%02X", (word >> UInt32(shift)) & 0xFF)
            }
        }
        return output
    }

    private static func cs64Words(_ data: Data, digest: Data) -> (UInt32, UInt32) {
        let keyA = readLittleEndian(digest, 0) | 1
        let keyB = readLittleEndian(digest, 4) | 1
        let factors = (keyA &* cs64Factor, keyB &* cs64Factor)
        var terms = cs64Coefficients.enumerated().map { index, coefficient in
            coefficient &* (index % 2 == 0 ? factors.0 : factors.1)
        }
        var offsets = cs64Offsets
        for (index, word) in littleEndianWords(Data([0]) + data).enumerated() {
            var term = word &* (index % 2 == 0 ? keyA : keyB)
            var offset = rotate16(word) &* (index % 2 == 0 ? 0xEF0569FB : 0xC31713DB)
            if index == 0 {
                term = term &+ cs64Adjustment0 &* factors.0
                offset = offset &+ cs64Adjustment1
            }
            terms.append(term)
            offsets.append(offset)
        }
        var swapAccumulator: UInt32 = 0, swapLast: UInt32 = 0, state: UInt32 = 0, accumulator: UInt32 = 0
        for index in stride(from: 0, to: terms.count, by: 2) {
            let x = terms[index], y = terms[index + 1]
            var mixed = rotate16(offsets[index] &+ x)
            var product = mixed &* 0x76F50F34
            swapAccumulator = swapAccumulator &+ (rotate16(product) &* 0xC3EFEA97 &+ product)
            mixed = rotate16(offsets[index + 1] &+ y)
            product = mixed &* 0x1881CE3C
            swapLast = rotate16(product) &* 0x35BD1EC9 &+ product
            swapAccumulator = swapAccumulator &+ swapLast

            state = state &* keyA &+ x
            state = rotate16(state) &* 0xCF98B111
            state = rotate16(state) &* 0x87085B9F
            state = rotate16(state) &* 0x12CEB96D
            state = rotate16(state) &* 0x257E1D83
            accumulator = accumulator &+ state
            var second = state &* keyB &+ y
            second = rotate16(second) &* 0xA27416F5
            second = rotate16(second) &* 0xD38396FF
            state = rotate16(rotate16(second) &* 0x7C932B89) &* 0xBFA49F69
            accumulator = accumulator &+ state
        }
        return (swapLast ^ state, swapAccumulator ^ accumulator)
    }

    // MARK: - Byte helpers

    private static func littleEndianWords(_ data: Data) -> [UInt32] {
        var padded = data
        let remainder = padded.count % 4
        if remainder != 0 {
            padded.append(contentsOf: repeatElement(0, count: 4 - remainder))
        }
        if padded.isEmpty { return [] }
        var words = stride(from: 0, to: padded.count, by: 4).map { readLittleEndian(padded, $0) }
        if words.count % 2 != 0 { words.append(0) }
        return words
    }

    private static func readLittleEndian(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }

    private static func bigEndianWord(_ bytes: Data) -> UInt32 {
        var value: UInt32 = 0
        for byte in bytes { value = value << 8 | UInt32(byte) }
        return value
    }

    private static func rotate16(_ value: UInt32) -> UInt32 {
        value << 16 | value >> 16
    }

    private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        value >> amount | value << (32 - amount)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
