import Foundation
import AppKit
import Combine

@main
struct PlaybackTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manting-playback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PlayerModel(root: root, playbackVolume: 0)
        defer { model.shutdown() }
        model.defaultVoiceID = "system-tingting"
        model.add(text: "这是一段真实播放器检查。我们要确认暂停以后，可以从保存的位置继续收听。\n第二段用来检查跨段跳转。拖动进度条时，播放器应该准确切换到对应的声音位置。\n第三段检查重新打开以后，文章、音色、倍速和播放进度都能恢复。")
        try await wait("offline generation", seconds: 15, model: model) { model.allPrepared && model.isPlaying }
        try check(model.readingTimeline?.source == "systemWords", "offline word timing exists")
        try check((model.readingTimeline?.cues.count ?? 0) > 3, "offline has multiple real word anchors")
        model.pause()
        let firstCue = try require(model.readingTimeline?.cues.first, "offline first anchor")
        let lastCue = try require(model.readingTimeline?.cues.last, "offline last anchor")
        model.seek(to: firstCue.start + 0.02)
        let firstCharacter = model.readingRange
        model.seek(to: lastCue.start + 0.02)
        try check(model.readingRange != firstCharacter, "character highlighting follows seek")
        let pausedHighlight = model.readingRange
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(model.readingRange == pausedHighlight, "paused highlight remains stable")
        model.seek(to: 0)
        model.play()
        let firstID = try require(model.selectedID, "first ID")
        var clockUpdates = 0, documentUpdates = 0
        let clockObserver = model.playbackClock.$elapsed.dropFirst().sink { _ in clockUpdates += 1 }
        let documentObserver = model.objectWillChange.sink { documentUpdates += 1 }
        try await Task.sleep(nanoseconds: 900_000_000)
        clockObserver.cancel(); documentObserver.cancel()
        try check(clockUpdates >= 5, "playback clock updates smoothly")
        try check(documentUpdates < clockUpdates / 2, "audio clock does not refresh the whole document")
        print("PASS: clock isolation (\(clockUpdates) clock updates, \(documentUpdates) document updates)")
        model.pause()
        try check(model.elapsed > 0.5, "real AVAudioPlayer advanced")
        let paused = model.elapsed
        try await Task.sleep(nanoseconds: 350_000_000)
        try check(abs(model.elapsed - paused) < 0.01, "pause stable")
        model.setRate(1.5)
        try check((model.document?.chunks.count ?? 0) > 1, "fixture has multiple chunks")
        let firstBoundary = try require(model.document?.chunks.first?.duration, "first cached duration")
        let nextDuration = try require(model.document?.chunks[1].duration, "second cached duration")
        model.seek(to: firstBoundary + nextDuration * 0.35)
        let seekIndex = model.currentIndex
        let seekOffset = model.elapsed
        try check(seekIndex > 0, "seek traversed chunks")
        model.play()
        try await Task.sleep(nanoseconds: 400_000_000)
        model.pause()
        try check(model.elapsed > seekOffset, "resume after seek")
        let savedOffset = model.elapsed
        model.shutdown()
        let restored = PlayerModel(root: root, playbackVolume: 0)
        defer { restored.shutdown() }
        try check(restored.selectedID == firstID && restored.currentIndex == seekIndex, "restore document and chunk")
        try check(abs(restored.elapsed - savedOffset) < 0.05 && restored.rate == 1.5, "restore offset and rate")
        try check(restored.allPrepared && !restored.isPlaying, "restore cached, paused")
        try check(restored.readingTimeline?.source == "systemWords" && restored.readingRange != nil, "restore character highlighting")
        restored.play()
        try check(restored.isPlaying, "cached playback starts without synthesis")
        restored.pause()
        restored.defaultVoiceID = "system-tingting"
        restored.add(text: "第二篇文章用来验证每篇内容各自保留进度。切换文章不会清空上一段已经保存的位置。")
        try await wait("second article", seconds: 10, model: restored) { restored.allPrepared }
        restored.select(firstID)
        try check(restored.currentIndex == seekIndex && abs(restored.elapsed - savedOffset) < 1, "per-document resume")
        // Finish a cached chunk, exercise AVAudioPlayer's delegate, and advance to the next.
        restored.jumpToChunk(0)
        let firstDuration = try require(restored.document?.chunks.first?.duration, "first duration")
        restored.seek(to: firstDuration - 0.25)
        restored.play()
        try await wait("delegate advances chunk", seconds: 5) { restored.currentIndex == 1 && restored.isPlaying }
        restored.pause()
        if CommandLine.arguments.contains("--online") {
            restored.defaultVoiceID = "zh-CN-XiaoxiaoNeural"
            restored.add(text: "这是慢听的免费在线音色。文字变成声音之后，会保存在本机。暂停、拖动进度，再次打开，都可以继续收听。")
            try await wait("online full playback", seconds: 35, model: restored) { restored.allPrepared && restored.isPlaying }
            try check(restored.document?.chunks.first?.audioFile?.hasSuffix(".mp3") == true, "online MP3 cache")
            try check(restored.readingTimeline?.source == "onlineWords" && (restored.readingTimeline?.cues.count ?? 0) > 3, "online word timing integration")
            restored.pause()
        }
        try await verifySearchAndDeletion(root: root.appendingPathComponent("features"))
        try await verifyLegacyHighlighting(root: root.appendingPathComponent("legacy-highlighting"))
        print("PASS: real audio generation, playback, pause, seek, speed, restart restore, per-article position, cached playback, chunk completion, keyword sentence start and restore, system Trash archive, deletion during generation, delete other without interruption, last-item empty state" + (CommandLine.arguments.contains("--online") ? ", online synthesis integration" : ""))
    }

    @MainActor static func verifyLegacyHighlighting(root: URL) async throws {
        let initial = PlayerModel(root: root, playbackVolume: 0)
        initial.defaultVoiceID = "system-tingting"
        initial.add(text: String(repeating: "这是开头的内容，用于验证旧音频不会被自动覆盖。", count: 4) + "\n后面的内容在校准之后应该从当前段开头继续，并逐字显示高亮。")
        try await wait("legacy fixture", seconds: 15, model: initial) { initial.allPrepared }
        try check((initial.document?.chunks.count ?? 0) > 1, "legacy fixture has later chunk")
        initial.pause(); initial.jumpToChunk(1)
        initial.seek(to: initial.timelinePosition + 1)
        initial.shutdown()
        let original = try require(initial.document, "legacy document")
        let directory = try initial.store!.audioDirectory(for: original.id)
        for chunk in original.chunks {
            if let file = chunk.audioFile { try FileManager.default.removeItem(at: SpeechTimeline.metadataURL(for: directory.appendingPathComponent(file))) }
        }
        let restored = PlayerModel(root: root, playbackVolume: 0)
        defer { restored.shutdown() }
        try check(restored.highlightIsEstimated && restored.readingRange != nil, "old cache immediately supports labeled character estimates")
        try check(restored.document == original, "opening old cache preserves all original state")
        restored.calibrateHighlighting()
        try check(restored.currentIndex == original.chunkIndex && restored.elapsed == 0, "explicit calibration starts at current chunk")
        try await wait("calibrated word timing", seconds: 15, model: restored) { restored.allPrepared && restored.isPlaying }
        restored.pause()
        try check(!restored.highlightIsEstimated && restored.readingTimeline?.source == "systemWords", "calibration installs word anchors")
        try check(restored.document?.rawText == original.rawText && restored.document?.chunks.map(\.text) == original.chunks.map(\.text), "calibration preserves text")
        for chunk in original.chunks {
            if let file = chunk.audioFile { try check(FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path), "calibration preserves old audio files") }
        }
    }

    @MainActor static func verifySearchAndDeletion(root: URL) async throws {
        var archives: [URL] = []
        defer { for url in archives { try? FileManager.default.removeItem(at: url) } }
        let text = "开场说明要跳过这一句。目标起点从这句话开始，确认搜索后不会重新朗读开头。另一个目标在后面。\n最后一段用于验证剩余内容仍然完整。"
        let model = PlayerModel(root: root, playbackVolume: 0)
        defer { model.shutdown() }
        model.defaultVoiceID = "system-tingting"
        model.add(text: text)
        try await wait("search fixture audio", seconds: 15, model: model) { model.allPrepared && model.isPlaying }
        model.pause()
        let id = try require(model.selectedID, "search document ID")
        let original = try require(model.document, "search document")
        model.searchQuery = "目标"
        try check(model.searchMatches.count == 2, "all keyword occurrences")
        model.moveSearchResult(-1)
        try check(model.searchResultIndex == 1, "previous match wraps")
        model.moveSearchResult(1)
        try check(model.searchResultIndex == 0, "next match wraps")
        model.playSearchResult()
        try check(model.document?.chunks[model.currentIndex].text.hasPrefix("目标起点") == true, "playback starts at exact sentence text")
        try check(model.document?.chunks.map(\.text).joined() == original.chunks.map(\.text).joined(), "split preserves complete text")
        try check(model.document?.rawText == original.rawText, "search preserves source")
        try await wait("search target playback", seconds: 15, model: model) { model.allPrepared && model.isPlaying }
        try await Task.sleep(nanoseconds: 400_000_000)
        model.pause()
        let targetIndex = model.currentIndex
        let targetOffset = model.elapsed
        model.shutdown()

        let resumed = PlayerModel(root: root, playbackVolume: 0)
        defer { resumed.shutdown() }
        try check(resumed.currentIndex == targetIndex && abs(resumed.elapsed - targetOffset) < 0.05, "search target survives restart")
        resumed.searchQuery = "目标起点"
        let cachedIDs = resumed.document?.chunks.map(\.id)
        resumed.playSearchResult()
        try check(resumed.isPlaying && resumed.document?.chunks.map(\.id) == cachedIDs, "same sentence reuses cached audio")
        resumed.defaultVoiceID = "system-tingting"
        resumed.add(text: "保留文章正在播放。删除另一篇文章时，这一篇的声音和进度应该继续。")
        try await wait("kept document playback", seconds: 15, model: resumed) { resumed.allPrepared && resumed.isPlaying }
        let keptID = try require(resumed.selectedID, "kept ID")
        let archived = try require(await resumed.deleteDocument(id), "delete other: \(resumed.errorMessage ?? "unknown")")
        archives.append(archived)
        try check(resumed.selectedID == keptID && resumed.isPlaying, "delete other does not stop current")
        let recovered = try JSONDecoder().decode(ReadingDocument.self, from: Data(contentsOf: archived.appendingPathComponent("document.json")))
        try check(recovered.rawText == text && recovered.chunkIndex == targetIndex, "Trash contains text and progress")
        for chunk in recovered.chunks {
            if let name = chunk.audioFile { try check(FileManager.default.fileExists(atPath: archived.appendingPathComponent(name).path), "Trash contains cached audio") }
        }
        try check(try resumed.store!.load().documents.map(\.id) == [keptID], "deletion persists")

        resumed.add(text: String(repeating: "开场说明。目标起点用于检查生成中的快速搜索和删除。\n", count: 80))
        let pendingID = try require(resumed.selectedID, "pending ID")
        try await wait("synthesis in progress", seconds: 5, model: resumed) { resumed.isPreparing }
        resumed.searchQuery = "目标起点"
        resumed.playSearchResult()
        let pendingArchive = try require(await resumed.deleteDocument(pendingID), "delete generating: \(resumed.errorMessage ?? "unknown")")
        archives.append(pendingArchive)
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Audio").appendingPathComponent(pendingID.uuidString).path), "cancelled jobs do not recreate deleted directory")
        try check(resumed.selectedID == keptID && !resumed.isPlaying && !resumed.isPreparing, "delete current selects remaining paused")
        let finalArchive = try require(await resumed.deleteDocument(keptID), "delete final")
        archives.append(finalArchive)
        try check(resumed.documents.isEmpty && resumed.selectedID == nil && resumed.showComposer && !resumed.canPlay, "empty library state")
        try check(try resumed.store!.load().documents.isEmpty, "empty library persisted")
    }

    @MainActor static func wait(_ label: String, seconds: Double, model: PlayerModel? = nil, until condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if let error = model?.errorMessage ?? model?.storageError { throw failure("\(label): \(error)") }
            if Date().timeIntervalSince(start) > seconds { throw failure("timeout: \(label)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    static func require<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    static func failure(_ message: String) -> NSError { NSError(domain: "PlaybackTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
