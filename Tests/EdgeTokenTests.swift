import Foundation

@main struct EdgeTokenTests {
    static func main() throws {
        // Values produced by the reference implementation (edge_tts/drm.py).
        let tokenVectors: [(Double, String)] = [
            (0, "52BC7A17B50DFEC9-28C4394775C8751CD2F6859C030C06DB1489ACAB3B3A7651831FC26895177ED6"),
            (1, "52BC7A17B50DFEC9-28C4394775C8751CD2F6859C030C06DB1489ACAB3B3A7651831FC26895177ED6"),
            (299, "52BC7A17B50DFEC9-28C4394775C8751CD2F6859C030C06DB1489ACAB3B3A7651831FC26895177ED6"),
            (300, "F7535A20A262E331-28675BF85C7106BBF20035A78FCB0B6890813EAD5C3B983EF3424931B720BABB"),
            (1700000000.5, "2CD23A2CA0B2595A-F3C846C370E05F9CC83ACC5F995C5F5D87A4D0F14CE8936A0F902E64099E38A2"),
            (1735689600, "54404AFE67C9B44A-E72E51D8B4F5F75E9A96B7E20D7877227455BC310433BD30C817CD54A1D9313E"),
            (1786000000, "E4AD0E2F91F43177-2AB13D10348B1AD26285A210A565183FE800BCBCA94B19F44D2A46E44E995EBD"),
            (1799999999, "8DD724B1AF1AEBDA-7EAB32704E1EBDC4C7D8109CC130E2B31826441D7C07CA6E8118FBCE8902837E"),
            (1800000000, "99E54519B490BE5C-E162DB0977FBDCB9B86DD8148BF1BCDC3C0303176CE39852A42B415935C20654"),
            (1234567890.123, "BA405D1577B8E0CE-61F01E88539977A1A1E969572D82EECFA45FB1E5DEBD122D6ACBAF0054F959E5")
        ]
        for (timestamp, expected) in tokenVectors {
            try check(EdgeToken.secMsGec(unixTimestamp: timestamp) == expected, "reference token at \(timestamp)")
        }

        try check(EdgeToken.secMsGec(unixTimestamp: 1) == EdgeToken.secMsGec(unixTimestamp: 299),
                  "token stays stable inside one five minute window")
        try check(EdgeToken.secMsGec(unixTimestamp: 299) != EdgeToken.secMsGec(unixTimestamp: 300),
                  "token rolls over at the window edge")

        let token = EdgeToken.secMsGec(unixTimestamp: 1735689600)
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        try check(parts.count == 2 && parts[0].count == 16 && parts[1].count == 64,
                  "version 2 shape is 16 hex digits of CS64 plus 64 hex digits of digest")
        try check(token.allSatisfy { $0.isHexDigit || $0 == "-" }, "token is hex only")
        try check(token == token.uppercased(), "token is uppercase")

        let digestVectors: [(Data, String)] = [
            (Data("abcdefg".utf8), "97E9018412E7C939-4B2714C790880C814D9D2AD59C85751F4469AD8B55859F18668799E789F47791"),
            (Data("abcdefgh".utf8), "AC602DD93698412A-7234B3B78BF9B58DB0E895E5B5FD0B72F385497AE20404A1FAA1E20E3B2CFC95"),
            (Data("0000000000000000".utf8), "9B664C266E82BD30-DDB4A5D826D1CB654603EDECB8C0D0B31E6E8D181AEDB395FFCC567AB13FAB3B"),
            (Data("12345678901234567890".utf8), "23387A5E06FBE047-51AAA776BA631A282FA771D7B30CFCC91CD5C9D47693C6A589E885999EED9494"),
            (Data((0..<32).map { UInt8($0) }), "0D014A812E7D009C-192ECA64E7F9FB224CA600522CF25C598C84585419FA08902D304D5DDCB7F4D9"),
            (Data("1330000000000000006A5AA1D4EAFF4E9FB37E23D68491D6F4".utf8), "5BD0947A8162F1B3-DB68788A027F164C2A83875D4847D557278FA576018396943F1D28019433D6E7")
        ]
        for (input, expected) in digestVectors {
            try check(EdgeToken.tokenHash(input) == expected, "reference digest for \(input.count) bytes")
        }

        print("PASS: version 2 Sec-MS-GEC token matches upstream vectors, window rollover, token shape and salted digest")
    }

    static func check(_ value: Bool, _ reason: String) throws {
        if !value {
            throw NSError(domain: "EdgeTokenTests", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }
}
