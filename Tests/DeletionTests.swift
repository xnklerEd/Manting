import Foundation

enum DeletionTestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case .assertion(let message): return message } }
}

@main
struct DeletionTests {
    static let fileManager = FileManager.default

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw DeletionTestFailure.assertion(message) }
    }

    static func fixture() -> ReadingDocument {
        var document = ReadingDocument(text: String(repeating: "需要恢复的正文，含有完整收听进度。", count: 15), voiceID: "zh-CN-XiaoxiaoNeural")
        document.chunks[0].audioFile = "first.mp3"
        document.chunks[0].duration = 25.5
        document.chunkIndex = 1
        document.offset = 6.25
        document.playbackRate = 1.25
        return document
    }

    static func main() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent("manting-deletion-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try testSuccess(root.appendingPathComponent("success"))
        try testNoAudio(root.appendingPathComponent("no-audio"))
        try testSaveFailure(root.appendingPathComponent("save-failure"), blockRecovery: false)
        try testSaveFailure(root.appendingPathComponent("recovery-failure"), blockRecovery: true)
        try testMoveFailure(root.appendingPathComponent("move-failure"))
        try testRejectedSnapshot(root.appendingPathComponent("invalid-snapshot"))
        try testSymlink(root.appendingPathComponent("symlink"))
        try testMetadataCollision(root.appendingPathComponent("metadata-collision"))
        print("PASS: deletion archive preserves text/audio/progress; sibling isolation; uncached document; failed trash move; failed library save rollback; failed rollback keeps recoverable archive; invalid snapshot, symlink, and unrelated metadata rejection")
    }

    static func fakeTrash(in root: URL, source: URL) throws -> URL {
        let trash = root.appendingPathComponent("SimulatedTrash", isDirectory: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    static func archiveDocument(at directory: URL) throws -> ReadingDocument {
        try JSONDecoder().decode(ReadingDocument.self, from: Data(contentsOf: directory.appendingPathComponent("document.json")))
    }

    static func testSuccess(_ root: URL) throws {
        let store = try LibraryStore(root: root.appendingPathComponent("Library"))
        let document = fixture()
        let other = ReadingDocument(text: "其他文章必须保留。", voiceID: "local")
        try store.save(LibrarySnapshot(documents: [document, other], selectedID: document.id))
        let source = try store.audioDirectory(for: document.id)
        let audio = Data("test audio payload".utf8)
        try audio.write(to: source.appendingPathComponent("first.mp3"))
        let otherDirectory = try store.audioDirectory(for: other.id)
        let siblingData = Data("other document audio".utf8)
        try siblingData.write(to: otherDirectory.appendingPathComponent("other.mp3"))
        let remaining = LibrarySnapshot(documents: [other], selectedID: other.id)
        let archive = try store.trashDocument(document, saving: remaining) { try fakeTrash(in: root, source: $0) }
        try require(!fileManager.fileExists(atPath: source.path), "Deleted audio directory remains active")
        try require(try archiveDocument(at: archive) == document, "Recovery archive changed text, progress, voice, or chunk metadata")
        try require(try Data(contentsOf: archive.appendingPathComponent("first.mp3")) == audio, "Audio was lost or changed")
        try require(try Data(contentsOf: otherDirectory.appendingPathComponent("other.mp3")) == siblingData, "Sibling audio changed")
        try require(try store.load().documents == [other], "Library did not remove exactly the selected document")
        try require(try store.load().selectedID == other.id, "Replacement selection was not committed")
    }

    static func testNoAudio(_ root: URL) throws {
        let store = try LibraryStore(root: root.appendingPathComponent("Library"))
        let document = ReadingDocument(text: "尚未生成语音也可以删除并恢复。", voiceID: "local")
        try store.save(LibrarySnapshot(documents: [document], selectedID: document.id))
        let archive = try store.trashDocument(document, saving: LibrarySnapshot(documents: [], selectedID: nil)) { try fakeTrash(in: root, source: $0) }
        try require(try archiveDocument(at: archive) == document, "Uncached document was not archived")
        try require(try store.load().documents.isEmpty, "Deleting last uncached document left a library entry")
    }

    static func testSaveFailure(_ root: URL, blockRecovery: Bool) throws {
        let store = try LibraryStore(root: root.appendingPathComponent("Library"))
        let document = fixture()
        try store.save(LibrarySnapshot(documents: [document], selectedID: document.id))
        let source = try store.audioDirectory(for: document.id)
        let audio = Data("audio to recover".utf8)
        try audio.write(to: source.appendingPathComponent("first.mp3"))
        // A nonempty directory cannot be atomically replaced with the backup file.
        try fileManager.createDirectory(at: store.backupURL, withIntermediateDirectories: true)
        try Data("prevent backup replacement".utf8).write(to: store.backupURL.appendingPathComponent("occupied"))
        var archive: URL?
        do {
            try store.trashDocument(document, saving: LibrarySnapshot(documents: [], selectedID: nil)) { directory in
                let destination = try fakeTrash(in: root, source: directory)
                archive = destination
                if blockRecovery {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Data("do not overwrite".utf8).write(to: directory.appendingPathComponent("unexpected"))
                }
                return destination
            }
            throw DeletionTestFailure.assertion("Blocked library save unexpectedly succeeded")
        } catch let error as DocumentDeletionError {
            switch error {
            case .saveFailedRecovered:
                try require(!blockRecovery, "Expected explicit failed-recovery result")
            case .saveFailedRecoveryFailed(let recoveryURL, _, _):
                try require(blockRecovery, "Unblocked recovery unexpectedly failed")
                try require(recoveryURL == archive, "Failed recovery omitted the actual archive location")
                try require(error.localizedDescription.contains(recoveryURL.path), "Recovery instructions omit archive path")
            default:
                throw DeletionTestFailure.assertion("Unexpected deletion failure: \(error)")
            }
        }
        try require(try store.load().documents == [document], "Failed save changed the original library")
        let preserved = blockRecovery ? archive! : source
        try require(try archiveDocument(at: preserved) == document, "Failure lost recoverable document metadata")
        try require(try Data(contentsOf: preserved.appendingPathComponent("first.mp3")) == audio, "Failure lost cached audio")
        if blockRecovery {
            try require(try Data(contentsOf: source.appendingPathComponent("unexpected")) == Data("do not overwrite".utf8), "Rollback overwrote an unexpected path")
        } else {
            try require(!fileManager.fileExists(atPath: archive!.path), "Rollback left a duplicate archive")
        }
    }

    static func testMoveFailure(_ root: URL) throws {
        let store = try LibraryStore(root: root)
        let document = fixture()
        try store.save(LibrarySnapshot(documents: [document], selectedID: document.id))
        do {
            try store.trashDocument(document, saving: LibrarySnapshot(documents: [], selectedID: nil)) { _ in
                throw CocoaError(.fileWriteNoPermission)
            }
            throw DeletionTestFailure.assertion("Failed move unexpectedly succeeded")
        } catch DocumentDeletionError.trashFailed { }
        try require(try store.load().documents == [document], "Failed trash move changed library")
        try require(try archiveDocument(at: store.audioDirectory(for: document.id)) == document, "Failed move lost recovery metadata")
    }

    static func testRejectedSnapshot(_ root: URL) throws {
        let store = try LibraryStore(root: root)
        let document = fixture()
        let unchanged = LibrarySnapshot(documents: [document], selectedID: document.id)
        try store.save(unchanged)
        do {
            try store.trashDocument(document, saving: unchanged) { _ in
                throw DeletionTestFailure.assertion("Invalid deletion snapshot reached filesystem move")
            }
            throw DeletionTestFailure.assertion("Invalid remaining snapshot was accepted")
        } catch DocumentDeletionError.invalidRemainingSnapshot { }
        try require(try store.load().documents == [document], "Rejected snapshot changed library")
        try require(!fileManager.fileExists(atPath: root.appendingPathComponent("Audio").path), "Rejected snapshot touched audio")
    }

    static func testSymlink(_ root: URL) throws {
        let store = try LibraryStore(root: root.appendingPathComponent("Library"))
        let document = fixture()
        try store.save(LibrarySnapshot(documents: [document], selectedID: document.id))
        let external = root.appendingPathComponent("Unrelated", isDirectory: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        let audioRoot = store.root.appendingPathComponent("Audio", isDirectory: true)
        try fileManager.createSymbolicLink(at: audioRoot, withDestinationURL: external)
        do {
            try store.trashDocument(document, saving: LibrarySnapshot(documents: [], selectedID: nil)) { _ in
                throw DeletionTestFailure.assertion("Symlink directory reached filesystem move")
            }
            throw DeletionTestFailure.assertion("Symlink directory was accepted")
        } catch DocumentDeletionError.unsafeDirectory { }
        try require(try fileManager.contentsOfDirectory(atPath: external.path).isEmpty, "Deletion wrote through a symlink")
        try require(try store.load().documents == [document], "Rejected symlink changed library")
    }

    static func testMetadataCollision(_ root: URL) throws {
        let store = try LibraryStore(root: root)
        let document = fixture()
        try store.save(LibrarySnapshot(documents: [document], selectedID: document.id))
        let directory = try store.audioDirectory(for: document.id)
        let metadataURL = directory.appendingPathComponent("document.json")
        let original = Data("an unrelated preexisting file".utf8)
        try original.write(to: metadataURL)
        do {
            try store.trashDocument(document, saving: LibrarySnapshot(documents: [], selectedID: nil)) { _ in
                throw DeletionTestFailure.assertion("Conflicting metadata reached filesystem move")
            }
            throw DeletionTestFailure.assertion("Preexisting unrelated metadata was replaced")
        } catch DocumentDeletionError.archiveFailed { }
        try require(try Data(contentsOf: metadataURL) == original, "Unrelated metadata was changed")
        try require(try store.load().documents == [document], "Metadata collision changed library")
    }
}
