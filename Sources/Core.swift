import Foundation

struct AudioChunk: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    /// A filename relative to this document's audio directory.
    var audioFile: String?
    var duration: Double?

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.audioFile = nil
        self.duration = nil
    }
}

struct ReadingDocument: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var rawText: String
    var chunks: [AudioChunk]
    var voiceID: String
    var createdAt: Date
    var chunkIndex: Int
    var offset: Double
    var playbackRate: Double

    init(text: String, voiceID: String) {
        self.id = UUID()
        self.rawText = text
        let prepared = TextPreparation.spokenText(text)
        let firstLine = prepared.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "未命名文本"
        self.title = String(firstLine.prefix(32)) + (firstLine.count > 32 ? "…" : "")
        self.chunks = TextPreparation.chunks(text).map(AudioChunk.init)
        self.voiceID = voiceID
        self.createdAt = Date()
        self.chunkIndex = 0
        self.offset = 0
        self.playbackRate = 1
    }
}

struct LibrarySnapshot: Codable {
    var version: Int = 1
    var documents: [ReadingDocument]
    var selectedID: UUID?

    init(documents: [ReadingDocument], selectedID: UUID?) {
        self.documents = documents
        self.selectedID = selectedID
    }
}

enum LibraryStoreError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidData(String)
    case damagedLibrary(URL, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "阅读库版本 \(version) 不受此版本慢听支持。"
        case .invalidData(let reason):
            return "阅读库内容无效：\(reason)"
        case .damagedLibrary(let url, let reason):
            return "无法读取阅读库 \(url.lastPathComponent)：\(reason)。原文件已保留，未覆盖；可检查同目录的 library.backup.json。"
        }
    }
}

/// Called on the app's main actor. Writes preserve a validated previous snapshot.
final class LibraryStore {
    let root: URL
    private let fileManager = FileManager.default
    private var libraryURL: URL { root.appendingPathComponent("library.json") }
    var backupURL: URL { root.appendingPathComponent("library.backup.json") }

    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Manting", isDirectory: true)
        try fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func load() throws -> LibrarySnapshot {
        guard fileManager.fileExists(atPath: libraryURL.path) else {
            return LibrarySnapshot(documents: [], selectedID: nil)
        }
        return try readSnapshot(at: libraryURL)
    }

    func save(_ snapshot: LibrarySnapshot) throws {
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)

        if fileManager.fileExists(atPath: libraryURL.path) {
            // Never turn a load failure followed by an empty UI into lost user data.
            let previousData = try Data(contentsOf: libraryURL)
            _ = try decode(previousData, at: libraryURL)
            // The backup itself is atomically replaced before the primary is touched.
            try previousData.write(to: backupURL, options: [.atomic])
        }
        // Foundation writes a sibling temporary file and replaces the destination.
        // An interrupted write leaves either the previous or the complete next file.
        try data.write(to: libraryURL, options: [.atomic])
    }

    func audioDirectory(for documentID: UUID) throws -> URL {
        let url = root.appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Explicit recovery inspection; it never modifies the damaged primary file.
    func loadBackup() throws -> LibrarySnapshot {
        try readSnapshot(at: backupURL)
    }

    private func readSnapshot(at url: URL) throws -> LibrarySnapshot {
        do { return try decode(Data(contentsOf: url), at: url) }
        catch let error as LibraryStoreError { throw error }
        catch { throw LibraryStoreError.damagedLibrary(url, error.localizedDescription) }
    }

    private func decode(_ data: Data, at url: URL) throws -> LibrarySnapshot {
        do {
            let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
            try validate(snapshot)
            return snapshot
        } catch {
            throw LibraryStoreError.damagedLibrary(url, error.localizedDescription)
        }
    }

    private func validate(_ snapshot: LibrarySnapshot) throws {
        guard snapshot.version == 1 else { throw LibraryStoreError.unsupportedVersion(snapshot.version) }
        let ids = snapshot.documents.map(\.id)
        guard Set(ids).count == ids.count else { throw LibraryStoreError.invalidData("文章标识重复") }
        if let selectedID = snapshot.selectedID, !ids.contains(selectedID) {
            throw LibraryStoreError.invalidData("所选文章不存在")
        }
        for document in snapshot.documents {
            guard (0...document.chunks.count).contains(document.chunkIndex),
                  document.offset.isFinite, document.offset >= 0,
                  document.playbackRate.isFinite, document.playbackRate > 0 else {
                throw LibraryStoreError.invalidData("文章播放位置或速度无效")
            }
            guard Set(document.chunks.map(\.id)).count == document.chunks.count else {
                throw LibraryStoreError.invalidData("音频段落标识重复")
            }
            for chunk in document.chunks {
                if let duration = chunk.duration, !duration.isFinite || duration < 0 {
                    throw LibraryStoreError.invalidData("音频时长无效")
                }
                if let filename = chunk.audioFile,
                   filename.isEmpty || filename == "." || filename == ".." || filename.contains("/") || filename.contains("\\") {
                    throw LibraryStoreError.invalidData("音频文件名必须位于当前文章目录内")
                }
            }
        }
    }
}

enum TextPreparation {
    /// Removes display-only Markdown syntax. Code contents and link labels remain.
    static func spokenText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = replacing(#"(?m)^\s{0,3}(?:`{3,}|~{3,})[^\n]*$"#, in: text, with: "")
        text = replacing(#"!?\[([^\]]+)\]\((?:[^()\n]|\([^()\n]*\))*\)"#, in: text, with: "$1")
        text = replacing(#"<((?:https?://|mailto:)[^>]+)>"#, in: text, with: "$1")
        text = replacing(#"(?m)^ {0,3}#{1,6}[ \t]+(.+?)(?:[ \t]+#+)?$"#, in: text, with: "$1")
        text = replacing(#"(?m)^ {0,3}>[ \t]?"#, in: text, with: "")
        text = replacing(#"(?m)^\s*[-+*][ \t]+(?:\[[ xX]\][ \t]*)?"#, in: text, with: "")
        text = replacing(#"(?m)^ {0,3}\d{1,3}[.)][ \t]+"#, in: text, with: "")
        text = replacing(#"(?m)^ {0,3}(?:[-*_][ \t]*){3,}$"#, in: text, with: "")
        text = replacing(#"\*\*([^*\n]+)\*\*"#, in: text, with: "$1")
        text = replacing(#"__([^_\n]+)__"#, in: text, with: "$1")
        text = replacing(#"~~([^~\n]+)~~"#, in: text, with: "$1")
        text = replacing(#"\*([^*\s](?:[^*\n]*[^*\s])?)\*"#, in: text, with: "$1")
        text = replacing(#"(?<!\w)_([^_\n]+)_(?!\w)"#, in: text, with: "$1")
        text = replacing(#"`([^`\n]+)`"#, in: text, with: "$1")
        text = replacing(#"[ \t]+"#, in: text, with: " ")
        text = replacing(#"[ \t]+\n"#, in: text, with: "\n")
        text = replacing(#"\n{3,}"#, in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first chunk is short for a quick start. Later chunks use more context.
    /// Joining the returned chunks reproduces spokenText exactly, including spaces.
    static func chunks(_ raw: String) -> [String] {
        let characters = Array(spokenText(raw))
        guard !characters.isEmpty else { return [] }
        var result: [String] = []
        var start = 0
        while start < characters.count {
            let limit = result.isEmpty ? 100 : 260
            let end = min(start + limit, characters.count)
            var split = end
            if end < characters.count {
                var sentenceBoundary: Int?
                var wordBoundary: Int?
                for i in start..<end {
                    let character = characters[i]
                    if "。！？!?；;\n".contains(character) {
                        sentenceBoundary = i + 1
                    } else if character == "." {
                        // Keep decimal numbers and domain-like tokens together.
                        if i + 1 == characters.count || characters[i + 1].isWhitespace {
                            sentenceBoundary = i + 1
                        }
                    }
                    if character.isWhitespace && i - start >= limit / 2 { wordBoundary = i + 1 }
                }
                if let boundary = sentenceBoundary,
                   !String(characters[start..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    split = boundary
                } else if let boundary = wordBoundary {
                    split = boundary
                }
            }
            let piece = String(characters[start..<split])
            // A boundary can leave only whitespace at the end; fold it into the
            // preceding piece to avoid asking a voice engine to synthesize silence.
            if piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !result.isEmpty {
                result[result.count - 1] += piece
            } else {
                result.append(piece)
            }
            start = split
        }
        return result
    }

    private static func replacing(_ pattern: String, in string: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return string }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return expression.stringByReplacingMatches(in: string, range: range, withTemplate: replacement)
    }
}
