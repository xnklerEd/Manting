import Foundation

enum SearchTestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case .assertion(let message): return message } }
}

@main
struct TextSearchTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SearchTestFailure.assertion(message) }
    }

    static func main() throws {
        try testLiteralSearch()
        try testUnicodeAndSnippets()
        try testHighlightRanges()
        try testSentenceBoundaries()
        try testCrossChunkSearch()
        try testSplitAndCaches()
        try testStaleMatches()
        print("PASS: literal/overlapping search, case/width folding, UTF-16 Unicode positions, merged/grapheme-safe highlights, sentence starts, cross-chunk search, exact splits, cache isolation, stale result rejection")
    }

    static func testLiteralSearch() throws {
        let chunks = [AudioChunk(text: "你好，关键词。再次关键词；最后关键词。 Swift UI、ＳＷＩＦＴ ui、swift UI。 [a.*] 哈哈哈")]
        let repeated = TextSearch.matches(query: " 关键词\n", chunks: chunks)
        try require(repeated.count == 3, "Repeated keyword occurrences were lost")
        try require(Set(repeated.map(\.id)).count == 3, "Match IDs are not unique")
        try require(TextSearch.matches(query: "swift ui", chunks: chunks).count == 3, "Case, width, or multi-word matching failed")
        try require(TextSearch.matches(query: "a.*", chunks: chunks).count == 1, "Query was interpreted as a regular expression")
        try require(TextSearch.matches(query: "哈哈", chunks: chunks).count == 2, "Overlapping matches were lost")
        try require(TextSearch.matches(query: "  \n\t", chunks: chunks).isEmpty, "Blank query returned matches")
        try require(TextSearch.matches(query: "不存在", chunks: chunks).isEmpty, "Unmatched query returned results")
        try require(TextSearch.matches(query: "关键词", chunks: []).isEmpty, "Empty document returned matches")
    }

    static func testUnicodeAndSnippets() throws {
        let text = "前文👩🏽‍💻。\n\n👨‍👩‍👧‍👦 关键词 e\u{301}，好好听。"
        let matches = TextSearch.matches(query: "关键词", chunks: [AudioChunk(text: text)])
        let match = matches[0]
        try require(match.range == (text as NSString).range(of: "关键词"), "Match offsets are not UTF-16")
        try require(match.sentenceStart == (text as NSString).range(of: "👨‍👩‍👧‍👦").location, "Unicode sentence start is wrong")
        try require(match.snippet.contains("👩🏽‍💻") && match.snippet.contains("👨‍👩‍👧‍👦"), "Snippet split an emoji cluster")
        try require(!match.snippet.contains("\n"), "Snippet is not a single line")

        let long = String(repeating: "👩🏽‍💻", count: 90) + "关键词" + String(repeating: "e\u{301}", count: 90)
        let excerpt = TextSearch.matches(query: "关键词", chunks: [AudioChunk(text: long)])[0].snippet
        try require(excerpt.contains("关键词") && excerpt.count <= 62, "Snippet is missing the keyword or too long")
        for character in excerpt {
            try require(["👩🏽‍💻", "关", "键", "词", "e\u{301}", "…"].contains(String(character)), "Snippet cut a composed character")
        }
    }

    static func testSentenceBoundaries() throws {
        let text = "开头。 Price is 3.14 at example.com and key one. Next key two!\n最后 key three；新句 key four。"
        let chunks = [AudioChunk(text: text)]
        let found = TextSearch.matches(query: "key", chunks: chunks)
        let nsText = text as NSString
        let expected = ["Price", "Next", "最后", "新句"].map { nsText.range(of: $0).location }
        try require(found.map(\.sentenceStart) == expected, "Decimal/domain or sentence punctuation produced incorrect starts")
        let quoted = "他说：“你好！” 然后关键词。 \"Hello.\" Next keyword."
        let quotedChunks = [AudioChunk(text: quoted)]
        try require(TextSearch.matches(query: "关键词", chunks: quotedChunks)[0].sentenceStart == (quoted as NSString).range(of: "然后").location, "Closing quote became next sentence start")
        try require(TextSearch.matches(query: "keyword", chunks: quotedChunks)[0].sentenceStart == (quoted as NSString).range(of: "Next").location, "Quoted English sentence ending was not detected")
    }

    static func testHighlightRanges() throws {
        let overlapping = [AudioChunk(text: "哈哈哈")]
        let hits = TextSearch.matches(query: "哈哈", chunks: overlapping)
        try require(hits.count == 2, "Overlap fixture does not contain overlapping matches")
        let overlapRanges = TextSearch.highlightRanges(in: overlapping[0].text, chunkStart: 0, matches: hits)
        try require(overlapRanges == [NSRange(location: 0, length: 3)], "Overlapping highlights were not merged")
        let adjacent = TextSearch.matches(query: "哈", chunks: overlapping)
        try require(TextSearch.highlightRanges(in: overlapping[0].text, chunkStart: 0, matches: adjacent) == overlapRanges, "Adjacent highlights were not merged")

        let text = "前👩🏽‍💻后👨‍👩‍👧‍👦末 e\u{301}"
        let chunks = [AudioChunk(text: text)]
        let emojiHits = TextSearch.matches(query: "👩", chunks: chunks)
        let emojiRanges = TextSearch.highlightRanges(in: text, chunkStart: 0, matches: emojiHits)
        try require(emojiRanges == ["👩🏽‍💻", "👨‍👩‍👧‍👦"].map { (text as NSString).range(of: $0) }, "Partial emoji query did not highlight complete graphemes")
        let combiningHits = TextSearch.matches(query: "e", chunks: chunks)
        let combiningRanges = TextSearch.highlightRanges(in: text, chunkStart: 0, matches: combiningHits)
        try require(combiningRanges == [(text as NSString).range(of: "e\u{301}")], "Combining character was split by highlight boundary")
        var cursor = 0
        var rebuilt = ""
        let source = text as NSString
        for range in emojiRanges {
            try require(range.location >= cursor, "Highlight cursor could have a negative-length prefix")
            rebuilt += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            rebuilt += source.substring(with: range)
            cursor = NSMaxRange(range)
        }
        rebuilt += source.substring(from: cursor)
        try require(rebuilt == text, "Highlight rendering lost or duplicated text")

        let crossChunks = [AudioChunk(text: "开跨"), AudioChunk(text: "段关"), AudioChunk(text: "键结束")]
        let crossHits = TextSearch.matches(query: "跨段关键", chunks: crossChunks)
        let expected = [NSRange(location: 1, length: 1), NSRange(location: 0, length: 2), NSRange(location: 0, length: 1)]
        var start = 0
        for (index, chunk) in crossChunks.enumerated() {
            try require(TextSearch.highlightRanges(in: chunk.text, chunkStart: start, matches: crossHits) == [expected[index]], "Cross-chunk highlight uses incorrect local offsets")
            start += chunk.text.utf16.count
        }
        try require(TextSearch.highlightRanges(in: "", chunkStart: 0, matches: hits).isEmpty, "Empty chunk returned a highlight")
        try require(TextSearch.highlightRanges(in: "正文", chunkStart: Int.max, matches: hits).isEmpty, "Invalid chunk offset was accepted")
    }

    static func testCrossChunkSearch() throws {
        let chunks = [AudioChunk(text: "第一句。第二句有一个跨"), AudioChunk(text: "段关键词，我们继续。末句。")]
        let match = TextSearch.matches(query: "跨段关键词", chunks: chunks)[0]
        try require(match.chunkIndex == 0 && match.startChunkIndex == 0 && match.startOffset == 4, "Cross-chunk keyword mapping is wrong")
        let later = TextSearch.matches(query: "我们继续", chunks: chunks)[0]
        try require(later.chunkIndex == 1 && later.startChunkIndex == 0 && later.startOffset == 4, "Sentence start did not backtrack across chunk boundary")
        let split = TextSearch.split(chunks: chunks, at: later)!
        try require(split.startIndex == 1 && split.chunks[1].text.hasPrefix("第二句"), "Cross-chunk playback begins in the middle of a sentence")
        try require(split.chunks.map(\.text).joined() == chunks.map(\.text).joined(), "Cross-chunk split changed text")
    }

    static func testSplitAndCaches() throws {
        var chunks = [AudioChunk(text: "前一段。"), AudioChunk(text: "旧句👩🏽‍💻。 \n关键词所在的新句。尾句。"), AudioChunk(text: "后一段。")]
        for index in chunks.indices { chunks[index].audioFile = "cached-\(index).mp3"; chunks[index].duration = Double(index + 10) }
        let original = chunks.map(\.text).joined()
        let match = TextSearch.matches(query: "关键词", chunks: chunks)[0]
        let result = TextSearch.split(chunks: chunks, at: match)!
        try require(result.startIndex == 2, "Wrong playback start after split")
        try require(result.chunks.count == 4 && result.chunks.map(\.text).joined() == original, "Split lost, trimmed, or duplicated text")
        try require(result.chunks[0] == chunks[0] && result.chunks[3] == chunks[2], "Split modified unrelated chunk caches")
        try require(result.chunks[1].text == "旧句👩🏽‍💻。 \n" && result.chunks[2].text == "关键词所在的新句。尾句。", "Split is not at the exact sentence boundary")
        for piece in result.chunks[1...2] {
            try require(piece.id != chunks[1].id && piece.audioFile == nil && piece.duration == nil, "Split reused stale audio metadata")
            try require(!piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Split created a whitespace-only chunk")
        }
        try require(result.chunks[1].id != result.chunks[2].id, "New pieces share a chunk ID")

        let atBoundary = TextSearch.matches(query: "后一段", chunks: chunks)[0]
        let unchanged = TextSearch.split(chunks: chunks, at: atBoundary)!
        try require(unchanged.chunks == chunks && unchanged.startIndex == 2, "Sentence at chunk boundary unnecessarily invalidated caches")
        let leadingSpaces = [AudioChunk(text: " \n\t关键词正文。")]
        let whitespaceResult = TextSearch.split(chunks: leadingSpaces, at: TextSearch.matches(query: "关键词", chunks: leadingSpaces)[0])!
        try require(whitespaceResult.chunks == leadingSpaces && whitespaceResult.startIndex == 0, "Leading whitespace became an audio-only chunk or was lost")
    }

    static func testStaleMatches() throws {
        var chunks = [AudioChunk(text: "旧句。关键词新句。")]
        let match = TextSearch.matches(query: "关键词", chunks: chunks)[0]
        chunks[0].audioFile = "new-cache.mp3"
        chunks[0].duration = 12
        try require(TextSearch.split(chunks: chunks, at: match) != nil, "Audio generation incorrectly invalidated search results")
        var changed = chunks
        changed[0].text = "更"
        try require(TextSearch.split(chunks: changed, at: match) == nil, "Out-of-range stale result was accepted")
        changed[0].text = "新句。不同的新句。"
        try require(TextSearch.split(chunks: changed, at: match) == nil, "Changed source text accepted stale search result")
        changed = chunks
        changed[0].id = UUID()
        try require(TextSearch.split(chunks: changed, at: match) == nil, "Replaced chunk accepted stale search result")
        try require(TextSearch.split(chunks: [], at: match) == nil, "Deleted document accepted stale result")
        let firstSplit = TextSearch.split(chunks: chunks, at: match)!
        try require(TextSearch.split(chunks: firstSplit.chunks, at: match) == nil, "An already applied split accepted its stale result")
    }
}
