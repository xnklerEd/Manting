import Foundation

struct TextSearchMatch: Identifiable, Equatable {
    /// Stable within this text: the match's UTF-16 offset in joined chunk text.
    let id: Int
    let range: NSRange
    let sentenceStart: Int
    let snippet: String
    let chunkIndex: Int
    let startChunkIndex: Int
    let startOffset: Int

    // Audio generation may update cache metadata while results are displayed.
    // Text and chunk identities must still agree before applying a result.
    fileprivate let sourceText: String
    fileprivate let sourceChunkIDs: [UUID]
}

enum TextSearch {
    /// Local UTF-16 ranges suitable for attributed display. Search may return
    /// overlapping matches or match one scalar inside a composed emoji; display
    /// complete grapheme clusters once so neither text nor cursor moves backward.
    static func highlightRanges(in text: String, chunkStart: Int, matches: [TextSearchMatch]) -> [NSRange] {
        let source = text as NSString
        guard source.length > 0, chunkStart >= 0, chunkStart <= Int.max - source.length else { return [] }
        let chunkRange = NSRange(location: chunkStart, length: source.length)
        let expanded = matches.compactMap { match -> NSRange? in
            let intersection = NSIntersectionRange(chunkRange, match.range)
            guard intersection.length > 0 else { return nil }
            let local = NSRange(location: intersection.location - chunkStart, length: intersection.length)
            return source.rangeOfComposedCharacterSequences(for: local)
        }.sorted { $0.location < $1.location || ($0.location == $1.location && $0.length < $1.length) }
        var merged: [NSRange] = []
        for range in expanded {
            if let previous = merged.last, range.location <= NSMaxRange(previous) {
                merged[merged.count - 1] = NSRange(location: previous.location,
                                                 length: max(NSMaxRange(previous), NSMaxRange(range)) - previous.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func matches(query: String, chunks: [AudioChunk]) -> [TextSearchMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !chunks.isEmpty else { return [] }
        let text = chunks.map(\.text).joined()
        let source = text as NSString
        guard source.length > 0 else { return [] }

        let characters = Array(text)
        let offsets = characterOffsets(characters)
        let chunkOffsets = cumulativeOffsets(chunks)
        let starts = sentenceStarts(characters: characters, offsets: offsets)
        let ids = chunks.map(\.id)
        var result: [TextSearchMatch] = []
        var searchOffset = 0
        while searchOffset < source.length {
            let found = source.range(of: needle, options: [.literal, .caseInsensitive, .widthInsensitive],
                                     range: NSRange(location: searchOffset, length: source.length - searchOffset))
            guard found.location != NSNotFound, found.length > 0 else { break }
            let start = starts[max(0, upperBound(starts, found.location) - 1)]
            let chunkIndex = upperBound(chunkOffsets, found.location) - 1
            let startChunkIndex = upperBound(chunkOffsets, start) - 1
            result.append(TextSearchMatch(
                id: found.location, range: found, sentenceStart: start,
                snippet: snippet(characters: characters, offsets: offsets, range: found),
                chunkIndex: chunkIndex, startChunkIndex: startChunkIndex,
                startOffset: start - chunkOffsets[startChunkIndex],
                sourceText: text, sourceChunkIDs: ids
            ))
            // Include overlapping literal occurrences, such as both "哈哈" in
            // "哈哈哈". NSString ranges are UTF-16; snippet/split boundaries below
            // are separately aligned to complete extended grapheme clusters.
            searchOffset = found.location + 1
        }
        return result
    }

    /// Splits only the sentence-start chunk. New pieces receive fresh IDs and no
    /// cache metadata, so playback cannot reuse audio for the old, longer text.
    static func split(chunks: [AudioChunk], at match: TextSearchMatch) -> (chunks: [AudioChunk], startIndex: Int)? {
        guard !chunks.isEmpty,
              chunks.map(\.id) == match.sourceChunkIDs,
              chunks.map(\.text).joined() == match.sourceText,
              match.id == match.range.location,
              match.range.location >= 0, match.range.length > 0,
              match.range.location < match.sourceText.utf16.count,
              match.range.length <= match.sourceText.utf16.count - match.range.location,
              match.sentenceStart >= 0, match.sentenceStart <= match.range.location,
              chunks.indices.contains(match.chunkIndex),
              chunks.indices.contains(match.startChunkIndex) else { return nil }

        let offsets = cumulativeOffsets(chunks)
        guard upperBound(offsets, match.range.location) - 1 == match.chunkIndex,
              upperBound(offsets, match.sentenceStart) - 1 == match.startChunkIndex,
              match.startOffset == match.sentenceStart - offsets[match.startChunkIndex] else { return nil }
        let original = chunks[match.startChunkIndex]
        let characters = Array(original.text)
        let boundaries = characterOffsets(characters)
        guard match.startOffset >= 0, match.startOffset < original.text.utf16.count,
              let boundary = boundaries.firstIndex(of: match.startOffset) else { return nil }
        if boundary == 0 { return (chunks, match.startChunkIndex) }

        let prefix = String(characters[..<boundary])
        let suffix = String(characters[boundary...])
        guard !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Keeping a silent prefix in the original chunk preserves exact text and
        // avoids generating a standalone whitespace-only audio request.
        if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (chunks, match.startChunkIndex)
        }
        var updated = chunks
        updated.replaceSubrange(match.startChunkIndex...match.startChunkIndex,
                                with: [AudioChunk(text: prefix), AudioChunk(text: suffix)])
        return (updated, match.startChunkIndex + 1)
    }

    private static func characterOffsets(_ characters: [Character]) -> [Int] {
        var result = [0]
        result.reserveCapacity(characters.count + 1)
        for character in characters { result.append(result.last! + String(character).utf16.count) }
        return result
    }

    private static func cumulativeOffsets(_ chunks: [AudioChunk]) -> [Int] {
        var result = [0]
        result.reserveCapacity(chunks.count + 1)
        for chunk in chunks { result.append(result.last! + chunk.text.utf16.count) }
        return result
    }

    /// Returns the first index whose value is strictly greater than the target.
    private static func upperBound(_ sorted: [Int], _ target: Int) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = low + (high - low) / 2
            if sorted[middle] <= target { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func sentenceStarts(characters: [Character], offsets: [Int]) -> [Int] {
        guard !characters.isEmpty else { return [0] }
        var first = 0
        while first < characters.count, characters[first].isWhitespace { first += 1 }
        var result = [offsets[first]]
        let closers = "\"'”’」』）》〉】〕〗〙〛"
        for index in characters.indices {
            let character = characters[index]
            var after = index + 1
            while after < characters.count, closers.contains(characters[after]) { after += 1 }
            let isPeriodBoundary = character == "." && (after == characters.count || characters[after].isWhitespace)
            guard "。！？!?；;\n\r".contains(character) || isPeriodBoundary else { continue }
            while after < characters.count, characters[after].isWhitespace { after += 1 }
            if after < characters.count, offsets[after] > result.last! { result.append(offsets[after]) }
        }
        return result
    }

    private static func snippet(characters: [Character], offsets: [Int], range: NSRange) -> String {
        let matchStart = max(0, upperBound(offsets, range.location) - 1)
        let matchEnd = min(characters.count, upperBound(offsets, range.location + range.length - 1))
        let contextBefore = min(20, max(0, (60 - (matchEnd - matchStart)) / 2))
        var start = max(0, matchStart - contextBefore)
        let end = min(characters.count, start + 60)
        start = max(0, end - 60)
        let excerpt = String(characters[start..<end]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > 0 ? "…" : "") + excerpt + (end < characters.count ? "…" : "")
    }
}
