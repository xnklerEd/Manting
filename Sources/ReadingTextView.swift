import SwiftUI
import AppKit
import Combine

/// Native text layout supports a background behind one grapheme, including when
/// it wraps lines. SwiftUI Text on the supported OS ignores that attribute.
struct ReadingTextView: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let showPinyin: Bool
    let enlargeReading: Bool
    let readingRange: NSRange?
    let playbackClock: PlaybackClock?
    let timeline: SpeechTimeline?
    let followsReading: Bool
    let searchRanges: [NSRange]
    let focusedSearchRange: NSRange?
    let focusCoordinator: FocusCoordinator
    let onClick: () -> Void

    final class FocusCoordinator: ObservableObject {
        weak var readingView: TextView?
        weak var searchView: TextView?
        func reveal(search: Bool) {
            if search { searchView?.revealCharacter(searchView?.focusedSearchRange) }
            else { readingView?.revealCharacter(readingView?.previousReading) }
        }
    }

    final class TextView: NSTextView {
        var onClick: (() -> Void)?
        var previousText: String?
        var previousAppearance: ReadingAppearance?
        var previousReading: NSRange?
        var previousSearch: [NSRange] = []
        var measuredSizes: [CGFloat: CGSize] = [:]
        weak var playbackClock: PlaybackClock?
        var timeline: SpeechTimeline?
        var clockSubscription: AnyCancellable?
        var followsReading = false
        var focusedSearchRange: NSRange?
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if selectedRange().length == 0, event.clickCount == 1 { onClick?() }
        }

        func drawHighlights(_ readingRange: NSRange?, force: Bool = false) {
            guard force || previousReading != readingRange else { return }
            let fullRange = NSRange(location: 0, length: textStorage?.length ?? 0)
            if let layout = layoutManager {
                let readerLayout = layout as? ReadingLayoutManager
                readerLayout?.readingRange = readingRange
                readerLayout?.searchRanges = previousSearch
                if let previousReading, NSMaxRange(previousReading) <= fullRange.length {
                    layout.invalidateDisplay(forCharacterRange: previousReading)
                }
                for key in [NSAttributedString.Key.backgroundColor, .foregroundColor, .underlineStyle] {
                    layout.removeTemporaryAttribute(key, forCharacterRange: fullRange)
                }
                for range in previousSearch where range.location >= 0 && NSMaxRange(range) <= fullRange.length {
                    layout.addTemporaryAttributes([.foregroundColor: NSColor.systemOrange,
                                                   .underlineStyle: NSUnderlineStyle.single.rawValue], forCharacterRange: range)
                }
                if let range = readingRange, range.location >= 0, range.length > 0, NSMaxRange(range) <= fullRange.length {
                    if readerLayout?.appearance.usesLearningLayout == true {
                        layout.invalidateDisplay(forCharacterRange: range)
                    } else {
                        layout.addTemporaryAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.85),
                                                       .foregroundColor: NSColor.black], forCharacterRange: range)
                    }
                }
            }
            previousReading = readingRange
            keepReadingVisible()
        }

        func keepReadingVisible() {
            guard followsReading else { return }
            revealCharacter(previousReading)
        }

        func revealCharacter(_ range: NSRange?) {
            guard window != nil, bounds.width > 0, bounds.height > 0, let range,
                  range.location >= 0, range.length > 0, NSMaxRange(range) <= (textStorage?.length ?? 0),
                  let layout = layoutManager, let container = textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
            let viewport = visibleRect
            guard !rect.isEmpty, !viewport.contains(rect) else { return }
            // Move only when a line leaves the viewport. NSView converts this
            // local rectangle through its ancestors to the enclosing clip view.
            _ = scrollToVisible(rect.insetBy(dx: 0, dy: -12))
        }
    }

    func makeNSView(context: Context) -> TextView {
        let view = TextView()
        view.textContainer?.replaceLayoutManager(ReadingLayoutManager())
        view.isEditable = false; view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        view.onClick = onClick
        view.followsReading = followsReading
        view.focusedSearchRange = focusedSearchRange
        if playbackClock != nil { focusCoordinator.readingView = view }
        else if focusCoordinator.readingView === view { focusCoordinator.readingView = nil }
        if focusedSearchRange != nil { focusCoordinator.searchView = view }
        else if focusCoordinator.searchView === view { focusCoordinator.searchView = nil }
        let appearance = ReadingAppearance(fontSize: fontSize, showPinyin: showPinyin, enlargeReading: enlargeReading)
        let clockChanged = view.playbackClock !== playbackClock
        guard view.previousText != text || view.previousAppearance != appearance || view.previousReading != readingRange || view.previousSearch != searchRanges
                || clockChanged || view.timeline != timeline else { return }
        if view.previousText != text || view.previousAppearance != appearance {
            let selected = view.selectedRange()
            let characters = appearance.usesLearningLayout ? PinyinAnnotator.shared.characters(in: text) : []
            if let layout = view.layoutManager as? ReadingLayoutManager {
                layout.appearance = appearance
                layout.characters = characters
            }
            view.textStorage?.setAttributedString(appearance.attributedText(text, characters: characters))
            view.measuredSizes.removeAll()
            if view.previousText == text, NSMaxRange(selected) <= text.utf16.count { view.setSelectedRange(selected) }
        }
        // Temporary drawing attributes leave glyphs, line breaks and intrinsic
        // size untouched. Replacing textStorage on every character forces a
        // fresh SwiftUI/AppKit layout of the whole long document.
        view.previousText = text; view.previousAppearance = appearance; view.previousSearch = searchRanges; view.timeline = timeline
        view.drawHighlights(readingRange, force: true)
        if clockChanged {
            view.clockSubscription = nil
            view.playbackClock = playbackClock
            view.clockSubscription = playbackClock?.$elapsed.dropFirst().sink { [weak view] seconds in
                guard let view else { return }
                // Repaint the single-character overlay directly, without a
                // SwiftUI state update or a document sizing pass.
                view.drawHighlights(view.timeline?.range(at: seconds))
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let storage = view.textStorage else { return nil }
        if let size = view.measuredSizes[width] { return size }
        // Measure independently: changing the live text container during a
        // SwiftUI sizing pass invalidates layout and can create a sizing loop.
        let size = ReadingAppearance.measuredSize(of: storage, width: width)
        if view.measuredSizes.count >= 8 { view.measuredSizes.removeAll() }
        view.measuredSizes[width] = size
        return size
    }
}
