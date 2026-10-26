import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case .assertion(let message): return message } }
}

@main
struct CoreTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure.assertion(message) }
    }

    static func mustThrow(_ message: String, _ block: () throws -> Void) throws {
        do { try block() } catch { return }
        throw TestFailure.assertion(message)
    }

    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write-loop" {
            try runWriteLoop(URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manting-core-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try testTextPreparation()
        try testRoundtrip(root.appendingPathComponent("roundtrip"))
        try testDamageBoundaries(root.appendingPathComponent("damage"))
        try testInterruptedFile(root.appendingPathComponent("interrupted"))
        try testTerminatedWriter(root.appendingPathComponent("terminated"))
        print("PASS: Markdown preservation, Unicode segmentation, progress roundtrip, previous-version backup, corrupt-file protection, interrupted-write boundaries, terminated writer recovery")
    }

    static func testTextPreparation() throws {
        let markdown = """
        # 阅读示例

        **加粗**与*斜体*，还有`代码`。
        - [x] 保留[链接文字](https://example.com/a_(b))。
        > 这是引用。
        ```swift
        let price = 3.14
        print(price)
        ```
        """
        let spoken = TextPreparation.spokenText(markdown)
        for expected in ["阅读示例", "加粗与斜体", "代码", "保留链接文字", "这是引用", "let price = 3.14", "print(price)"] {
            try require(spoken.contains(expected), "Markdown lost semantic content: \(expected)")
        }
        try require(!spoken.contains("https://"), "Link destination should not replace display text")
        try require(TextPreparation.chunks(" \n\t ").isEmpty, "Empty text generated chunks")
        try require(TextPreparation.spokenText("2026. 今天的 3 * 4 = 12，file_name 保持原样").contains("2026. 今天的 3 * 4 = 12，file_name 保持原样"), "Literal numbers or operators were stripped")

        let cases = [
            String(repeating: "这是一段中文测试。", count: 140),
            String(repeating: "中", count: 912),
            String(repeating: "SwiftUI supports macOS. Price is 3.14, not 314! ", count: 60),
            String(repeating: "👩🏽‍💻家庭👨‍👩‍👧‍👦，你好！\n\n", count: 65),
            String(repeating: "a", count: 99) + "。\n" + String(repeating: "b", count: 700),
            markdown
        ]
        for raw in cases {
            let chunks = TextPreparation.chunks(raw)
            try require(chunks.joined() == TextPreparation.spokenText(raw), "Segmentation changed or lost text")
            try require((chunks.first?.count ?? 0) <= 100, "First chunk exceeds fast-start limit")
            try require(chunks.dropFirst().allSatisfy { $0.count <= 260 }, "Later chunk exceeds size limit")
            try require(chunks.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "Whitespace-only chunk")
        }
    }

    static func testRoundtrip(_ root: URL) throws {
        let store = try LibraryStore(root: root)
        try require(try store.load().documents.isEmpty, "A new library is not empty")
        var document = ReadingDocument(text: String(repeating: "这是一篇会保存收听进度的长文。", count: 40), voiceID: "zh-CN-XiaoxiaoNeural")
        document.chunks[0].audioFile = "opening.mp3"
        document.chunks[0].duration = 21.123
        document.chunkIndex = 1
        document.offset = 7.321
        document.playbackRate = 1.25
        let snapshot = LibrarySnapshot(documents: [document], selectedID: document.id)
        try store.save(snapshot)
        let reloaded = try LibraryStore(root: root).load()
        try require(reloaded.documents == snapshot.documents, "Roundtrip did not preserve progress, IDs, audio metadata, or raw text")
        try require(reloaded.selectedID == document.id, "Selection was not saved")
        let audio = try store.audioDirectory(for: document.id)
        try require(audio.path == root.appendingPathComponent("Audio/\(document.id.uuidString)").path, "Audio directory is not isolated per document")

        document.offset = 12.5
        try store.save(LibrarySnapshot(documents: [document], selectedID: document.id))
        try require(try store.loadBackup().documents == snapshot.documents, "Backup is not the previous complete state")
        try require(try store.load().documents[0].offset == 12.5, "New progress was not committed")

        var invalid = document
        invalid.chunks[0].audioFile = "../other.mp3"
        try mustThrow("A path traversal audio filename was accepted") { try store.save(LibrarySnapshot(documents: [invalid], selectedID: invalid.id)) }
        invalid = document
        invalid.offset = .infinity
        try mustThrow("An infinite offset was accepted") { try store.save(LibrarySnapshot(documents: [invalid], selectedID: invalid.id)) }
        invalid = document
        invalid.chunkIndex = invalid.chunks.count + 1
        try mustThrow("An out-of-range chunk index was accepted") { try store.save(LibrarySnapshot(documents: [invalid], selectedID: invalid.id)) }
        try require(try store.load().documents[0] == document, "Rejected saves changed the library")
    }

    static func testDamageBoundaries(_ root: URL) throws {
        let store = try LibraryStore(root: root)
        let document = ReadingDocument(text: "损坏时保留原文件。", voiceID: "local")
        let snapshot = LibrarySnapshot(documents: [document], selectedID: document.id)
        try store.save(snapshot)
        try store.save(snapshot)
        let library = root.appendingPathComponent("library.json")
        let damaged = Data("{\"version\":1,\"documents\":[".utf8)
        try damaged.write(to: library)
        let backupBefore = try Data(contentsOf: store.backupURL)
        try mustThrow("Corrupt primary silently loaded as an empty library") { _ = try store.load() }
        try mustThrow("Corrupt primary was silently overwritten") { try store.save(LibrarySnapshot(documents: [], selectedID: nil)) }
        try require(try Data(contentsOf: library) == damaged, "Corrupt primary was not preserved")
        try require(try Data(contentsOf: store.backupURL) == backupBefore, "Corrupt primary replaced valid backup")
        try require(try store.loadBackup().documents == snapshot.documents, "Valid backup cannot be inspected")
    }

    static func testInterruptedFile(_ root: URL) throws {
        let store = try LibraryStore(root: root)
        let document = ReadingDocument(text: "上次完整保存的内容。", voiceID: "local")
        let snapshot = LibrarySnapshot(documents: [document], selectedID: document.id)
        try store.save(snapshot)
        // A process killed before rename can leave an unfinished sibling; readers
        // must only load the committed library, never the newest-looking file.
        try Data("partial next snapshot".utf8).write(to: root.appendingPathComponent(".library.json.interrupted"))
        try require(try LibraryStore(root: root).load().documents == snapshot.documents, "Uncommitted sibling displaced committed data")
        // Simulate a failed backup write. The primary must remain unchanged.
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: true)
        try Data("block atomic destination replacement".utf8).write(to: store.backupURL.appendingPathComponent("occupied"))
        try mustThrow("A blocked backup write unexpectedly succeeded") { try store.save(LibrarySnapshot(documents: [], selectedID: nil)) }
        try require(try store.load().documents == snapshot.documents, "Failed save changed committed data")
    }

    static func runWriteLoop(_ root: URL) throws {
        let store = try LibraryStore(root: root)
        var document = ReadingDocument(text: String(repeating: "完整快照必须保留全部文本与段落。", count: 2000), voiceID: "local")
        try store.save(LibrarySnapshot(documents: [document], selectedID: document.id))
        try Data().write(to: root.appendingPathComponent("writer-started"))
        while true {
            document.offset += 0.25
            try store.save(LibrarySnapshot(documents: [document], selectedID: document.id))
        }
    }

    static func testTerminatedWriter(_ root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--write-loop", root.path]
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let marker = root.appendingPathComponent("writer-started")
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: marker.path), process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try require(FileManager.default.fileExists(atPath: marker.path), "Writer never committed its first snapshot")
        Thread.sleep(forTimeInterval: 0.035)
        process.terminate()
        process.waitUntilExit()
        let store = try LibraryStore(root: root)
        let recovered = try store.load()
        try require(recovered.documents.count == 1, "Terminating writer lost committed document")
        try require(recovered.documents[0].rawText == String(repeating: "完整快照必须保留全部文本与段落。", count: 2000), "Terminating writer produced partial text")
        let backup = try store.loadBackup()
        try require(backup.documents[0].id == recovered.documents[0].id, "Backup does not belong to interrupted writing session")
    }
}
