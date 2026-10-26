import Foundation
import JavaScriptCore

struct AnnotatedCharacter: Equatable {
    let text: String
    let range: NSRange
    let pinyin: String?
}

/// Runs the bundled dictionary locally. Original UTF-16 ranges are retained so
/// annotations never alter the text used by speech, search, copying, or storage.
final class PinyinAnnotator {
    static let shared = PinyinAnnotator()
    private final class Entry: NSObject {
        let characters: [AnnotatedCharacter]
        init(_ characters: [AnnotatedCharacter]) { self.characters = characters }
    }
    private let cache = NSCache<NSString, Entry>()
    private let context: JSContext?
    private let convert: JSValue?
    let dictionaryAvailable: Bool

    init(scriptURL: URL? = Bundle.main.url(forResource: "pinyin-pro-3.29.4", withExtension: "js")) {
        cache.countLimit = 256
        let context = JSContext()
        if let scriptURL, let script = try? String(contentsOf: scriptURL, encoding: .utf8) {
            context?.evaluateScript(script, withSourceURL: scriptURL)
        }
        let function = context?.evaluateScript("""
            typeof pinyinPro === 'object' ? function (text) {
                return pinyinPro.pinyin(text, { type: 'array', toneSandhi: false });
            } : undefined
            """)
        self.context = context
        self.convert = function
        self.dictionaryAvailable = function != nil && function?.isUndefined == false && context?.exception == nil
    }

    func characters(in text: String) -> [AnnotatedCharacter] {
        if let entry = cache.object(forKey: text as NSString) { return entry.characters }
        let characters = Array(text).map(String.init)
        var syllables = [String?](repeating: nil, count: characters.count)
        var index = 0
        while index < characters.count {
            guard Self.isHan(characters[index]) else { index += 1; continue }
            let start = index
            while index < characters.count, Self.isHan(characters[index]) { index += 1 }
            // Ignore variation selectors when looking up a Han character, while
            // keeping its full grapheme and UTF-16 length in the source mapping.
            let lookup = characters[start..<index].map { String($0.unicodeScalars.first!) }
            context?.exception = nil
            let result = dictionaryAvailable ? convert?.call(withArguments: [lookup.joined()])?.toArray() as? [String] : nil
            if let result, result.count == lookup.count, context?.exception == nil {
                for (offset, value) in result.enumerated() {
                    syllables[start + offset] = Self.validSyllable(value, original: lookup[offset])
                }
            } else {
                for (offset, value) in lookup.enumerated() {
                    syllables[start + offset] = Self.validSyllable(value.applyingTransform(.mandarinToLatin, reverse: false), original: value)
                }
            }
            // The dictionary's default 地 is dì. These common adverbial
            // phrases use the neutral particle de; ordinary 土地 / 地球 and
            // a sentence-initial 地 retain their dictionary pronunciation.
            if lookup.count >= 3 {
                for offset in 2..<lookup.count where lookup[offset] == "地" {
                    let prefix = lookup[offset - 2] + lookup[offset - 1]
                    let nounSuffix = offset + 1 < lookup.count && ["球", "理", "图", "址", "震", "狱", "域", "貌"].contains(lookup[offset + 1])
                    if Self.adverbialPrefixes.contains(prefix), !nounSuffix { syllables[start + offset] = "de" }
                }
            }
        }
        var offset = 0
        let result = characters.enumerated().map { index, character in
            let range = NSRange(location: offset, length: character.utf16.count)
            offset += range.length
            return AnnotatedCharacter(text: character, range: range, pinyin: syllables[index])
        }
        cache.setObject(Entry(result), forKey: text as NSString)
        return result
    }

    static func isHan(_ value: String) -> Bool {
        guard let scalar = value.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2FA1F, 0x30000...0x323AF: return true
        default: return false
        }
    }

    private static let adverbialPrefixes: Set<String> = [
        "高兴", "开心", "快乐", "安静", "认真", "仔细", "轻轻", "慢慢", "静静", "渐渐", "悄悄", "偷偷",
        "默默", "紧紧", "牢牢", "深深", "重重", "狠狠", "清楚", "清晰", "大声", "小声", "轻声", "飞快",
        "迅速", "缓慢", "突然", "骄傲", "勇敢", "努力", "用力", "着急", "焦急", "激动", "兴奋", "耐心"
    ]

    private static func validSyllable(_ value: String?, original: String) -> String? {
        guard let value, value != original, !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              value.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }),
              !value.contains(where: { isHan(String($0)) }) else { return nil }
        return value
    }
}
