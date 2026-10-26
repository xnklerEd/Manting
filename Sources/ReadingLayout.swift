import AppKit

struct ReadingAppearance: Equatable {
    var fontSize: CGFloat
    var showPinyin: Bool
    var enlargeReading: Bool
    var usesLearningLayout: Bool { showPinyin || enlargeReading }
    var bodyFont: NSFont { .systemFont(ofSize: fontSize) }
    var readingFont: NSFont { .systemFont(ofSize: fontSize * (enlargeReading ? 2 : 1), weight: .semibold) }
    var pinyinFont: NSFont { .systemFont(ofSize: max(12, fontSize * 0.75), weight: .medium) }
    var readingPinyinFont: NSFont { .systemFont(ofSize: max(12, fontSize * (enlargeReading ? 1 : 0.75)), weight: .semibold) }
    var padding: CGFloat { max(3, fontSize * 0.12) }
    var pinyinHeight: CGFloat { ceil(readingPinyinFont.ascender - readingPinyinFont.descender) + padding }
    var bodyHeight: CGFloat { ceil(readingFont.ascender - readingFont.descender) }
    var lineHeight: CGFloat { pinyinHeight + bodyHeight + padding * 2 }

    static func measuredSize(of text: NSAttributedString, width: CGFloat) -> CGSize {
        // Use the same TextKit layout rules in a separate layout graph. The
        // general attributed-string boundingRect API differs for mixed scripts
        // and explicit line heights. Never resize the live text container here.
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height) + 2)
    }

    func attributedText(_ text: String, characters: [AnnotatedCharacter]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        if usesLearningLayout {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        } else {
            paragraph.lineSpacing = max(7, fontSize * 0.32)
        }
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: bodyFont, .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph, .ligature: usesLearningLayout ? 0 : 1
        ])
        guard usesLearningLayout else { return result }
        // Every character keeps the same advance for the whole playback. The
        // active glyph is painted at 2x inside this slot; no font/size mutation
        // reaches TextKit or SwiftUI when the reading position changes.
        for character in characters where !character.text.contains(where: \.isNewline) {
            let normalWidth = NSAttributedString(string: character.text, attributes: [.font: bodyFont]).size().width
            var width = NSAttributedString(string: character.text, attributes: [.font: readingFont]).size().width
            if let pinyin = character.pinyin {
                width = max(width, NSAttributedString(string: pinyin, attributes: [.font: readingPinyinFont]).size().width)
            }
            let gap = character.text.allSatisfy(\.isWhitespace) ? 0 : padding * 2
            result.addAttribute(.kern, value: max(0, width - normalWidth) + gap, range: character.range)
        }
        // Empty lines retain a modest paragraph gap instead of reserving a
        // second, unused 2x character row. Text and paragraph boundaries stay intact.
        let source = text as NSString
        var position = 0
        while position < source.length {
            let range = source.paragraphRange(for: NSRange(location: position, length: 0))
            if source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let gap = NSMutableParagraphStyle()
                gap.minimumLineHeight = max(8, fontSize * 0.45)
                gap.maximumLineHeight = gap.minimumLineHeight
                result.addAttribute(.paragraphStyle, value: gap, range: range)
            }
            position = NSMaxRange(range)
        }
        return result
    }
}

/// TextKit still owns line breaking, selection, copying, accessibility, and
/// hit-testing. Only the display of the already-laid-out glyph slots is custom.
final class ReadingLayoutManager: NSLayoutManager {
    var appearance = ReadingAppearance(fontSize: 32, showPinyin: false, enlargeReading: false)
    var characters: [AnnotatedCharacter] = []
    var readingRange: NSRange?
    var searchRanges: [NSRange] = []

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard appearance.usesLearningLayout,
              let container = textContainers.first else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let visibleCharacters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let selectedRange = container.textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        for character in characters where NSIntersectionRange(character.range, visibleCharacters).length > 0 {
            guard !character.text.allSatisfy(\.isWhitespace) else { continue }
            let glyphs = glyphRange(forCharacterRange: character.range, actualCharacterRange: nil)
            var slot = boundingRect(forGlyphRange: glyphs, in: container)
            let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            slot.origin.x += origin.x
            slot.origin.y = line.minY + origin.y
            slot.size.height = line.height
            let active = readingRange.map { NSIntersectionRange($0, character.range).length > 0 } ?? false
            let selected = NSIntersectionRange(selectedRange, character.range).length > 0
            let found = searchRanges.contains { NSIntersectionRange($0, character.range).length > 0 }
            if active && !selected {
                NSColor.systemYellow.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: slot.insetBy(dx: 1, dy: 1), xRadius: appearance.padding, yRadius: appearance.padding).fill()
            }
            let bodyFont = active ? appearance.readingFont : appearance.bodyFont
            let color: NSColor = selected ? .selectedTextColor : active ? .black : found ? .systemOrange : .labelColor
            let body = NSAttributedString(string: character.text, attributes: [.font: bodyFont, .foregroundColor: color])
            let bodySize = body.size()
            body.draw(at: NSPoint(x: slot.midX - bodySize.width / 2,
                                 y: slot.minY + appearance.padding + appearance.pinyinHeight + (appearance.bodyHeight - bodySize.height) / 2))
            if let pinyin = character.pinyin, appearance.showPinyin || active {
                let ruby = NSAttributedString(string: pinyin, attributes: [
                    .font: active ? appearance.readingPinyinFont : appearance.pinyinFont,
                    .foregroundColor: selected ? NSColor.selectedTextColor : active ? .black : .labelColor
                ])
                ruby.draw(at: NSPoint(x: slot.midX - ruby.size().width / 2, y: slot.minY + appearance.padding))
            }
            if found && !selected && !active {
                NSColor.systemOrange.setFill()
                NSRect(x: slot.midX - bodySize.width / 2, y: slot.maxY - appearance.padding, width: bodySize.width, height: 1).fill()
            }
        }
    }
}
