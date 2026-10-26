import Foundation

@main struct TimelineTests {
    static func main() throws {
        let text = "欢迎使用👩🏽‍💻。Hello!"
        let cues = [SpeechCue(start: 0.1, end: 0.5, location: 0, length: 2),
                    SpeechCue(start: 0.6, end: 1.0, location: 2, length: 2),
                    SpeechCue(start: 1.2, end: 1.5, location: 4, length: "👩🏽‍💻".utf16.count)]
        let timeline = SpeechTimeline(text: text, cues: cues)
        try check(timeline.isValid(duration: 2), "valid measured word anchors")
        try check(try character(timeline, at: 0.11) == "欢", "first character")
        try check(try character(timeline, at: 0.31) == "迎", "second character within word")
        try check(try character(timeline, at: 0.57) == "迎", "hold last character through pause")
        try check(try character(timeline, at: 0.61) == "使", "resynchronize at next word")
        try check(try character(timeline, at: 0.9) == "用", "forward seek")
        try check(try character(timeline, at: 0.2) == "欢", "backward seek")
        try check(try character(timeline, at: 1.35) == "👩🏽‍💻", "complete emoji grapheme")
        try check(timeline.range(at: .nan) == nil, "invalid clock rejected")
        let broken = SpeechTimeline(text: text, cues: [.init(start: 0, end: 1, location: 4, length: 1)])
        try check(!broken.isValid(duration: 2), "partial surrogate or grapheme rejected")
        let overlap = SpeechTimeline(text: "测试", cues: [.init(start: 0, end: 0.6, location: 0, length: 1), .init(start: 0.4, end: 1, location: 1, length: 1)])
        try check(!overlap.isValid(duration: 2), "overlapping audio timings rejected")
        let estimated = SpeechTimeline.estimated(text: "你，好！", duration: 2)!
        try check(estimated.source == "estimated" && (try character(estimated, at: 1.5)) == "好", "legacy fallback is explicit and skips punctuation")
        let metadata = Data(#"{"Metadata":[{"Type":"WordBoundary","Data":{"Offset":1000000,"Duration":2000000,"text":{"Text":"你"}}},{"Type":"WordBoundary","Data":{"Offset":5000000,"Duration":2000000,"text":{"Text":"你"}}}]}"#.utf8)
        let mapped = SpeechTimeline.online(text: "你，你。", boundaries: SpeechTimeline.boundaries(from: metadata), duration: 1)!
        try check(mapped.cues.map(\.location) == [0, 2], "repeated word mapping keeps source order")
        try check(SpeechTimeline.online(text: "不匹配", boundaries: SpeechTimeline.boundaries(from: metadata), duration: 1) == nil, "mismatched metadata cannot highlight wrong text")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manting-timeline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("sample.mp3")
        try timeline.save(for: audio)
        try check(SpeechTimeline.load(for: audio, text: text, duration: 2) == timeline, "timings persist")
        try check(SpeechTimeline.load(for: audio, text: "另一篇文章", duration: 2) == nil, "stale text rejected")
        try check(SpeechTimeline.load(for: audio, text: text, duration: 0.3) == nil, "different audio rejected")
        print("PASS: single-character timing, word-boundary resync, pause and seek, Unicode graphemes, legacy labels, metadata mapping, persistent timing validation")
    }
    static func character(_ timeline: SpeechTimeline, at time: Double) throws -> String {
        guard let range = timeline.range(at: time) else { throw error("missing character") }
        return (timeline.text as NSString).substring(with: range)
    }
    static func check(_ value: Bool, _ reason: String) throws { if !value { throw error(reason) } }
    static func error(_ reason: String) -> NSError { NSError(domain: "TimelineTests", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
}
