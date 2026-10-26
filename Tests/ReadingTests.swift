import AppKit
import Foundation

@main struct ReadingTests {
    static func main() throws {
        let script = URL(fileURLWithPath: CommandLine.arguments[1])
        let annotator = PinyinAnnotator(scriptURL: script)
        try check(annotator.dictionaryAvailable, "bundled pinyin dictionary loads")
        for (text, expected) in [
            ("银行行长", "yín háng háng zhǎng"),
            ("喜欢音乐", "xǐ huan yīn yuè"),
            ("重庆重新开始", "chóng qìng chóng xīn kāi shǐ"),
            ("快乐地长大", "kuài lè de zhǎng dà"),
            ("安静地看书", "ān jìng de kàn shū"),
            ("轻轻地走来", "qīng qīng de zǒu lái"),
            ("美丽的土地", "měi lì de tǔ dì"),
            ("地很干燥", "dì hěn gān zào"),
            ("重要的重量", "zhòng yào de zhòng liàng"),
            ("睡着了", "shuì zháo le"),
            ("你好世界", "nǐ hǎo shì jiè")
        ] {
            let actual = annotator.characters(in: text).compactMap(\.pinyin).joined(separator: " ")
            try check(actual == expected, "\(text): expected \(expected), got \(actual)")
        }
        let mixed = "A👨‍👩‍👧‍👦银行e\u{301}𠀀一\n二3!"
        let mapped = annotator.characters(in: mixed)
        try check(mapped.map(\.text).joined() == mixed, "annotation preserves original text exactly")
        try check(mapped.last.map { NSMaxRange($0.range) } == mixed.utf16.count, "complete UTF-16 coverage")
        for character in mapped {
            try check((mixed as NSString).substring(with: character.range) == character.text, "range maps to the original grapheme")
            if !PinyinAnnotator.isHan(character.text) {
                try check(character.pinyin == nil, "non-Han text never receives fabricated pinyin")
            }
        }
        let text = "银行行长喜欢音乐，林克拿起盾牌。\n\n重新开始的冒险。Hello 👩🏽‍💻!"
        let characters = annotator.characters(in: text)
        for size: CGFloat in [16, 32, 64] {
            for (pinyin, enlarged) in [(true, true), (true, false), (false, true), (false, false)] {
                let appearance = ReadingAppearance(fontSize: size, showPinyin: pinyin, enlargeReading: enlarged)
                let attributed = appearance.attributedText(text, characters: characters)
                try check(attributed.string == text, "display styling leaves search and copied text unchanged")
                let storage = NSTextStorage(attributedString: attributed)
                let layout = ReadingLayoutManager()
                layout.appearance = appearance; layout.characters = characters
                storage.addLayoutManager(layout)
                let container = NSTextContainer(containerSize: NSSize(width: 360, height: 100_000))
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                layout.ensureLayout(for: container)
                let baseline = layout.usedRect(for: container)
                let measured = ReadingAppearance.measuredSize(of: attributed, width: 360)
                try check(measured.height == ceil(baseline.height) + 2, "independent height measurement agrees with live layout at \(size) / \(pinyin) / \(enlarged)")
                _ = ReadingAppearance.measuredSize(of: attributed, width: 190)
                _ = ReadingAppearance.measuredSize(of: attributed, width: 720)
                try check(container.containerSize.width == 360 && layout.usedRect(for: container) == baseline, "alternate sizing proposals cannot mutate the live text layout")
                let slots = characters.map { layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: $0.range, actualCharacterRange: nil), in: container) }
                for character in characters {
                    layout.readingRange = character.range
                    layout.invalidateDisplay(forCharacterRange: character.range)
                    try check(layout.usedRect(for: container) == baseline, "active character never changes paragraph height")
                }
                let afterSlots = characters.map { layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: $0.range, actualCharacterRange: nil), in: container) }
                try check(slots == afterSlots, "active character never moves neighboring glyphs or line breaks")
                if appearance.usesLearningLayout {
                    for (character, slot) in zip(characters, slots) where PinyinAnnotator.isHan(character.text) {
                        let enlargedSize = NSAttributedString(string: character.text, attributes: [.font: appearance.readingFont]).size()
                        try check(enlargedSize.width <= slot.width + 0.5, "enlarged character fits reserved width")
                        try check(enlargedSize.height + appearance.pinyinHeight <= slot.height + 0.5, "character and pinyin fit the row")
                        if let pinyin = character.pinyin {
                            let width = NSAttributedString(string: pinyin, attributes: [.font: appearance.readingPinyinFont]).size().width
                            try check(width <= slot.width + 0.5, "pinyin fits without touching its neighbor")
                        }
                    }
                }
            }
        }
        let paragraph = String(repeating: "银行行长重新听着音乐，林克准备出发。", count: 30)
        let started = Date()
        let first = annotator.characters(in: paragraph)
        let coldMs = Date().timeIntervalSince(started) * 1000
        let cachedAt = Date()
        for _ in 0..<100 { try check(annotator.characters(in: paragraph) == first, "cached results remain stable") }
        print(String(format: "Pinyin: %.1f ms initial / %.1f ms for 100 cached reads", coldMs, Date().timeIntervalSince(cachedAt) * 1000))
        print("PASS: common polyphonic words, Unicode/source ranges, all display modes at 16/32/64, fixed layout under moving highlight, glyph and pinyin bounds")
    }
    static func check(_ value: Bool, _ reason: String) throws {
        if !value { throw NSError(domain: "ReadingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }
}
