import Foundation

enum DocumentDeletionError: LocalizedError {
    case invalidRemainingSnapshot
    case unsafeDirectory(URL)
    case archiveFailed(String)
    case trashFailed(String)
    case missingTrashLocation
    case saveFailedRecovered(String)
    case saveFailedRecoveryFailed(archive: URL, saveReason: String, recoveryReason: String)

    var errorDescription: String? {
        switch self {
        case .invalidRemainingSnapshot:
            return "删除未执行：保存后的阅读库仍包含这篇文本。"
        case .unsafeDirectory(let url):
            return "删除未执行：音频目录不是普通文件夹（\(url.path)）。原资料已保留。"
        case .archiveFailed(let reason):
            return "无法保存这篇文本的恢复资料，删除未执行：\(reason)"
        case .trashFailed(let reason):
            return "无法将这篇文本移到废纸篓，阅读库未修改：\(reason)"
        case .missingTrashLocation:
            return "这篇文本已移到废纸篓，但 macOS 未返回恢复位置，阅读库未修改。请在废纸篓中查看对应的文章目录；正文保存在其中的 document.json。"
        case .saveFailedRecovered(let reason):
            return "删除未完成：无法保存阅读库，已将文本和音频恢复原处：\(reason)"
        case .saveFailedRecoveryFailed(let archive, let saveReason, let recoveryReason):
            return "删除未完成：阅读库保存失败（\(saveReason)），自动恢复也失败（\(recoveryReason)）。文本和音频仍保存在废纸篓的 \(archive.path)，未被永久删除；正文和收听进度在 document.json 中。"
        }
    }
}

extension LibraryStore {
    /// The caller must first stop this document's player and await cancellation of
    /// its synthesis task, so no producer can recreate files during the move.
    /// Archive the exact document and cached audio together before committing the
    /// smaller library. Failed library writes restore the archive when possible.
    @discardableResult
    func trashDocument(
        _ document: ReadingDocument,
        saving remaining: LibrarySnapshot,
        moveToTrash: (URL) throws -> URL = LibraryStore.moveDocumentToSystemTrash
    ) throws -> URL {
        guard !remaining.documents.contains(where: { $0.id == document.id }),
              remaining.selectedID != document.id else {
            throw DocumentDeletionError.invalidRemainingSnapshot
        }

        let fileManager = FileManager.default
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let directory = audioRoot.appendingPathComponent(document.id.uuidString, isDirectory: true)

        do {
            // Do not follow symlinks when creating the archive or moving it. A
            // document's UUID determines its only allowed audio directory.
            for url in [audioRoot, directory] {
                do {
                    let attributes = try fileManager.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                        throw DocumentDeletionError.unsafeDirectory(url)
                    }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    // No audio has been generated yet; create its archive below.
                }
            }
            _ = try audioDirectory(for: document.id)
            let metadataURL = directory.appendingPathComponent("document.json")
            if fileManager.fileExists(atPath: metadataURL.path) {
                // A previous failed deletion can leave our recovery metadata.
                // Never replace a preexisting unrelated file or cached audio.
                guard !document.chunks.contains(where: { $0.audioFile == "document.json" }),
                      let previous = try? JSONDecoder().decode(ReadingDocument.self, from: Data(contentsOf: metadataURL)),
                      previous.id == document.id else {
                    throw DocumentDeletionError.archiveFailed("音频目录中已有不属于这篇文本的 document.json，已保留原文件。")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: metadataURL, options: [.atomic])
        } catch let error as DocumentDeletionError {
            throw error
        } catch {
            throw DocumentDeletionError.archiveFailed(error.localizedDescription)
        }

        let archivedURL: URL
        do {
            archivedURL = try moveToTrash(directory)
        } catch let error as DocumentDeletionError {
            throw error
        } catch {
            throw DocumentDeletionError.trashFailed(error.localizedDescription)
        }

        do {
            try save(remaining)
        } catch {
            let saveReason = error.localizedDescription
            do {
                // moveItem refuses to overwrite an unexpectedly recreated path.
                try fileManager.moveItem(at: archivedURL, to: directory)
            } catch {
                throw DocumentDeletionError.saveFailedRecoveryFailed(
                    archive: archivedURL,
                    saveReason: saveReason,
                    recoveryReason: error.localizedDescription
                )
            }
            throw DocumentDeletionError.saveFailedRecovered(saveReason)
        }
        return archivedURL
    }

    private static func moveDocumentToSystemTrash(_ directory: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: directory, resultingItemURL: &resultingURL)
        guard let resultingURL else { throw DocumentDeletionError.missingTrashLocation }
        return resultingURL as URL
    }
}
