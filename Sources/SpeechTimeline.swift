import Foundation

/// Word anchors in audio seconds. A multi-character word is interpolated only
/// within its own measured interval; the UI labels this precision explicitly.
struct SpeechCue: Codable, Equatable {
    var start: Double
    var end: Double
    var location: Int
    var length: Int
    var range: NSRange { NSRange(location: location, length: length) }
}

struct SpeechTimeline: Codable, Equatable {
    var text: String
    var cues: [SpeechCue]
    var source: String = "onlineWords"

    func range(at seconds: Double) -> NSRange? {
        guard seconds.isFinite, !cues.isEmpty else { return nil }
        guard let cue = cues.last(where: { $0.start <= seconds }) ?? cues.first else { return nil }
        let substring = (text as NSString).substring(with: cue.range)
        var characters: [NSRange] = []
        var offset = cue.location
        for c in substring {
            let length = String(c).utf16.count
            if Self.isSpoken(c) { characters.append(NSRange(location: offset, length: length)) }
            offset += length
        }
        guard !characters.isEmpty else { return nil }
        let fraction = min(1, max(0, (seconds - cue.start) / max(0.001, cue.end - cue.start)))
        return characters[min(characters.count - 1, Int(fraction * Double(characters.count)))]
    }

    static func isSpoken(_ c: Character) -> Bool {
        !c.isWhitespace && !c.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    static func estimated(text: String, duration: Double) -> Self? {
        guard duration > 0, text.contains(where: isSpoken) else { return nil }
        // Legacy caches remain usable immediately, without regenerating them.
        // This fallback is clearly marked as estimated in the reader.
        return Self(text: text, cues: [SpeechCue(start: 0, end: duration, location: 0, length: text.utf16.count)], source: "estimated")
    }

    struct SystemEvent: Codable { var location: Int; var length: Int; var byteOffset: UInt64 }

    static func system(text: String, events: [SystemEvent], dataOffset: UInt64, bytesPerSecond: Double, duration: Double) -> Self? {
        guard bytesPerSecond > 0 else { return nil }
        let source = text as NSString
        var cues: [SpeechCue] = []
        for (i, event) in events.enumerated() {
            let range = NSRange(location: event.location, length: event.length)
            guard event.location >= 0, event.length > 0, NSMaxRange(range) <= source.length else { return nil }
            let start = min(duration, Double(event.byteOffset > dataOffset ? event.byteOffset - dataOffset : 0) / bytesPerSecond)
            let next = i + 1 < events.count ? events[i + 1].byteOffset : dataOffset + UInt64(duration * bytesPerSecond)
            let end = min(duration, Double(next > dataOffset ? next - dataOffset : 0) / bytesPerSecond)
            guard source.substring(with: range).contains(where: isSpoken), end > start else { continue }
            cues.append(SpeechCue(start: start, end: end, location: event.location, length: event.length))
        }
        let result = Self(text: text, cues: cues, source: "systemWords")
        return result.isValid(duration: duration) ? result : nil
    }

    func isValid(duration: Double) -> Bool {
        guard duration.isFinite, duration > 0, !cues.isEmpty else { return false }
        let source = text as NSString
        var previousEnd = 0
        var previousTime = -Double.infinity
        for cue in cues {
            guard cue.location >= previousEnd, cue.length > 0, cue.location <= source.length,
                  cue.length <= source.length - cue.location,
                  cue.start.isFinite, cue.end.isFinite, cue.start >= 0,
                  cue.start >= previousTime, cue.end > cue.start, cue.end <= duration + 0.15,
                  source.rangeOfComposedCharacterSequences(for: cue.range) == cue.range else { return false }
            previousEnd = NSMaxRange(cue.range); previousTime = cue.end
        }
        return true
    }

    static func metadataURL(for audio: URL) -> URL { audio.appendingPathExtension("timing.json") }

    func save(for audio: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.metadataURL(for: audio), options: .atomic)
    }

    static func load(for audio: URL, text: String, duration: Double) -> SpeechTimeline? {
        guard let data = try? Data(contentsOf: metadataURL(for: audio)), data.count < 2_000_000,
              let timeline = try? JSONDecoder().decode(Self.self, from: data), timeline.text == text,
              timeline.isValid(duration: duration) else { return nil }
        return timeline
    }

    struct Boundary: Decodable {
        let Offset: Double
        let Duration: Double
        let text: BoundaryText
    }
    struct BoundaryText: Decodable { let Text: String }
    private struct Entry: Decodable { let `Type`: String; let Data: Boundary? }
    private struct Envelope: Decodable { let Metadata: [Entry] }

    static func boundaries(from data: Data) -> [Boundary] {
        guard let message = try? JSONDecoder().decode(Envelope.self, from: data) else { return [] }
        return message.Metadata.filter { $0.Type == "WordBoundary" }.compactMap(\.Data)
    }

    static func online(text: String, boundaries: [Boundary], duration: Double) -> SpeechTimeline? {
        let source = text as NSString
        var cursor = 0
        var cues: [SpeechCue] = []
        for boundary in boundaries {
            let spoken = unescapeXML(boundary.text.Text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { continue }
            var found = source.range(of: spoken, options: .literal, range: NSRange(location: cursor, length: source.length - cursor))
            if found.location == NSNotFound {
                // The service can collapse whitespace inside a sentence.
                var normalized = "", mapping: [NSRange] = []
                var offset = cursor
                for c in source.substring(from: cursor) {
                    let size = String(c).utf16.count
                    if !c.isWhitespace {
                        normalized += String(c)
                        mapping += Array(repeating: NSRange(location: offset, length: size), count: size)
                    }
                    offset += size
                }
                let needle = String(spoken.filter { !$0.isWhitespace })
                let match = (normalized as NSString).range(of: needle, options: .literal)
                guard match.location != NSNotFound, match.length > 0 else { return nil }
                let first = mapping[match.location], last = mapping[NSMaxRange(match) - 1]
                found = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            }
            found = source.rangeOfComposedCharacterSequences(for: found)
            let start = boundary.Offset / 10_000_000
            let end = min(duration, (boundary.Offset + boundary.Duration) / 10_000_000)
            cues.append(SpeechCue(start: start, end: end, location: found.location, length: found.length))
            cursor = NSMaxRange(found)
        }
        let timeline = Self(text: text, cues: cues)
        return timeline.isValid(duration: duration) ? timeline : nil
    }

    private static func unescapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
