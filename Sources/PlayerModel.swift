import Foundation
import AppKit
import AVFoundation
import MediaPlayer
import Combine

@MainActor
final class PlaybackClock: ObservableObject {
    @Published var elapsed: Double = 0
}

@MainActor
final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var documents: [ReadingDocument] = []
    @Published var selectedID: UUID?
    @Published var isPlaying = false
    @Published var isPreparing = false
    // The audio clock must not invalidate the entire document view at 20 Hz.
    // Only the transport and the native character overlay subscribe to it.
    let playbackClock = PlaybackClock()
    var elapsed: Double {
        get { playbackClock.elapsed }
        set { playbackClock.elapsed = newValue }
    }
    @Published var message = ""
    @Published var errorMessage: String?
    @Published var storageError: String?
    @Published var showComposer = false
    @Published var draft = ""
    @Published var miniMode = false
    @Published var highlightEnabled = UserDefaults.standard.object(forKey: "highlightEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(highlightEnabled, forKey: "highlightEnabled") }
    }
    @Published private(set) var readingTimeline: SpeechTimeline?
    @Published var searchQuery = "" { didSet { refreshSearch() } }
    @Published private(set) var searchMatches: [TextSearchMatch] = []
    @Published private(set) var searchResultIndex = 0
    @Published var searchFocusRequest = 0
    @Published var isSearchEditing = false
    @Published private(set) var isDeleting = false
    @Published var defaultVoiceID = UserDefaults.standard.string(forKey: "preferredVoice") ?? "zh-CN-XiaoxiaoNeural"
    private(set) var store: LibraryStore?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var generationTask: Task<Void, Never>?
    private var generationTasks: [UUID: (documentID: UUID, task: Task<Void, Never>)] = [:]
    private var generationID = UUID()
    private var wantsPlayback = false
    private var lastSave = Date.distantPast
    private var sleepObserver: NSObjectProtocol?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private let playbackVolume: Float
    private var didShutdown = false

    var document: ReadingDocument? { documents.first { $0.id == selectedID } }
    var currentIndex: Int { document.map { min($0.chunkIndex, max(0, $0.chunks.count - 1)) } ?? 0 }
    var voiceName: String { SpeechService.voices.first { $0.id == document?.voiceID }?.name ?? "中文语音" }
    var isOnline: Bool { !(document?.voiceID ?? defaultVoiceID).hasPrefix("system-") }
    var preparedCount: Int { document?.chunks.filter { $0.duration != nil && $0.audioFile != nil }.count ?? 0 }
    var allPrepared: Bool { document.map { !$0.chunks.isEmpty && preparedCount == $0.chunks.count } ?? false }
    var totalDuration: Double { document?.chunks.reduce(0) { $0 + duration(of: $1) } ?? 0 }
    var timelinePosition: Double { guard let doc = document else { return 0 }; return doc.chunks.prefix(currentIndex).reduce(0) { $0 + duration(of: $1) } + elapsed }
    var rate: Double { document?.playbackRate ?? 1 }
    var canPlay: Bool { document?.chunks.isEmpty == false && storageError == nil && !isDeleting }
    var playbackLabel: String { wantsPlayback ? (isPlaying ? "暂停" : "暂停等待") : "继续听" }
    var readingRange: NSRange? { highlightEnabled ? readingTimeline?.range(at: elapsed) : nil }
    var highlightIsEstimated: Bool { readingTimeline?.source == "estimated" }
    var selectedSearchMatch: TextSearchMatch? { searchMatches.indices.contains(searchResultIndex) ? searchMatches[searchResultIndex] : nil }
    var searchScrollTarget: UUID? {
        guard let match = selectedSearchMatch, let doc = document, doc.chunks.indices.contains(match.chunkIndex) else { return nil }
        return doc.chunks[match.chunkIndex].id
    }

    init(root: URL? = nil, playbackVolume: Float = 1) {
        self.playbackVolume = playbackVolume
        super.init()
        do {
            let override = ProcessInfo.processInfo.environment["MANTING_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            let storage = try LibraryStore(root: root ?? override)
            store = storage
            let snapshot = try storage.load()
            documents = snapshot.documents
            selectedID = snapshot.selectedID ?? documents.first?.id
            if document == nil { selectedID = documents.first?.id }
            if let doc = document { elapsed = doc.offset }
            reloadTimeline()
            if documents.isEmpty { showComposer = true }
        } catch { storageError = "本地资料读取失败，原文件已保留：\(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause(); self?.persist() }
        }
        installMediaKeys()
    }

    func duration(of chunk: AudioChunk) -> Double { chunk.duration ?? max(1, Double(chunk.text.count) / 4.2) }
    func time(_ value: Double) -> String {
        let seconds = Int(max(0, value.isFinite ? value : 0))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func select(_ id: UUID) {
        guard !isDeleting else { return }
        guard id != selectedID else { showComposer = false; return }
        pause(); cancelGeneration(); persist()
        player = nil; selectedID = id; elapsed = document?.offset ?? 0
        showComposer = false; errorMessage = nil; message = "已保留上次收听位置"
        reloadTimeline(); refreshSearch(); persist(); updateNowPlaying()
    }

    func newText() { guard !isDeleting else { return }; pause(); showComposer = true; draft = "" }
    func pasteAndRead() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "剪贴板里还没有文字。复制一段文字后再试。"; return
        }
        add(text: text)
    }
    func add(text: String) {
        guard storageError == nil, !isDeleting else { return }
        let doc = ReadingDocument(text: text, voiceID: defaultVoiceID)
        guard !doc.chunks.isEmpty else { errorMessage = "请先输入或粘贴要朗读的文字。"; return }
        pause(); cancelGeneration(); player = nil
        documents.insert(doc, at: 0); selectedID = doc.id; elapsed = 0
        draft = ""; showComposer = false; errorMessage = nil
        reloadTimeline(); refreshSearch(); persist(); play()
    }

    func play() {
        guard canPlay, let doc = document else { return }
        errorMessage = nil; wantsPlayback = true
        if doc.chunkIndex >= doc.chunks.count || (currentIndex == doc.chunks.count - 1 && elapsed >= duration(of: doc.chunks[currentIndex]) - 0.05) {
            setPosition(index: 0, offset: 0); player = nil
        }
        if let player {
            player.rate = Float(rate)
            if player.play() { isPlaying = true; message = "正在朗读" }
            else { wantsPlayback = false; isPlaying = false; errorMessage = "音频输出暂时不可用，请检查系统声音输出后重试。" }
        }
        else { playCachedCurrent() }
        startGeneration(); updateNowPlaying()
    }
    func togglePlayback() { wantsPlayback ? pause() : play() }
    func pause() {
        wantsPlayback = false
        if let player { elapsed = player.currentTime; player.pause() }
        isPlaying = false; syncPosition(); persist(); updateNowPlaying()
    }

    func setRate(_ value: Double) {
        guard !isDeleting, let i = selectedDocumentIndex else { return }
        documents[i].playbackRate = min(2, max(0.5, value)); player?.rate = Float(documents[i].playbackRate)
        persist(); updateNowPlaying()
    }

    func changeVoice(_ id: String) {
        guard !isDeleting else { return }
        defaultVoiceID = id; UserDefaults.standard.set(id, forKey: "preferredVoice")
        guard let i = selectedDocumentIndex, documents[i].voiceID != id else { return }
        let resume = wantsPlayback
        pause(); cancelGeneration(); player = nil
        documents[i].voiceID = id; documents[i].offset = 0; elapsed = 0
        for j in documents[i].chunks.indices { documents[i].chunks[j].audioFile = nil; documents[i].chunks[j].duration = nil }
        reloadTimeline()
        errorMessage = nil; message = "已换音色，保留在当前段落"; persist()
        if resume { play() }
    }

    func useOfflineVoice() { changeVoice("system-tingting"); play() }

    func calibrateHighlighting() {
        guard !isDeleting, let i = selectedDocumentIndex else { return }
        pause(); cancelGeneration(); player?.stop(); player = nil
        // Keep all source text and old files. Fresh IDs prevent reuse of caches
        // that lack word anchors, and generation prioritizes the current chunk.
        documents[i].chunks = documents[i].chunks.map { AudioChunk(text: $0.text) }
        documents[i].offset = 0; elapsed = 0
        reloadTimeline(); refreshSearch()
        message = "正在校准高亮，从当前段开头继续"
        persist(); play()
    }

    func jumpToChunk(_ index: Int) {
        guard !isDeleting else { return }
        guard let doc = document, doc.chunks.indices.contains(index) else { return }
        let resume = wantsPlayback
        player?.stop(); player = nil; isPlaying = false
        setPosition(index: index, offset: 0); persist(); errorMessage = nil
        cancelGeneration()
        wantsPlayback = resume
        if resume { playCachedCurrent(); startGeneration() }
        updateNowPlaying()
    }

    func seek(to time: Double) {
        guard !isDeleting else { return }
        guard let doc = document, !doc.chunks.isEmpty else { return }
        let resume = wantsPlayback
        var remaining = min(max(0, time), max(0, totalDuration - 0.01))
        var index = doc.chunks.count - 1
        for (j, chunk) in doc.chunks.enumerated() {
            let d = duration(of: chunk)
            if remaining < d || j == doc.chunks.count - 1 { index = j; break }
            remaining -= d
        }
        player?.stop(); player = nil; isPlaying = false
        if doc.chunks[index].duration == nil { remaining = 0; message = "这段尚未生成，将从段首开始" }
        setPosition(index: index, offset: remaining); errorMessage = nil; persist()
        cancelGeneration(); wantsPlayback = resume
        if resume { playCachedCurrent(); startGeneration() }
        updateNowPlaying()
    }
    func skip(_ seconds: Double) { seek(to: timelinePosition + seconds) }
    func restart() { jumpToChunk(0); play() }

    func focusSearch() {
        guard document != nil, !isDeleting else { return }
        miniMode = false; showComposer = false; searchFocusRequest += 1
    }

    func refreshSearch(keeping matchID: Int? = nil) {
        searchMatches = TextSearch.matches(query: searchQuery, chunks: document?.chunks ?? [])
        searchResultIndex = matchID.flatMap { id in searchMatches.firstIndex(where: { $0.id == id }) } ?? 0
    }

    func moveSearchResult(_ delta: Int) {
        guard !searchMatches.isEmpty else { return }
        searchResultIndex = (searchResultIndex + delta % searchMatches.count + searchMatches.count) % searchMatches.count
    }

    func selectSearchResult(_ index: Int) {
        guard searchMatches.indices.contains(index) else { return }
        searchResultIndex = index
    }

    func playSearchResult() {
        guard !isDeleting, let match = selectedSearchMatch, let i = selectedDocumentIndex,
              let split = TextSearch.split(chunks: documents[i].chunks, at: match) else { return }
        pause(); cancelGeneration(); player?.stop(); player = nil
        documents[i].chunks = split.chunks
        setPosition(index: split.startIndex, offset: 0)
        errorMessage = nil; message = "从关键词所在句子开始朗读"
        refreshSearch(keeping: match.id)
        persist(); play()
    }

    @discardableResult
    func deleteDocument(_ id: UUID) async -> URL? {
        guard !isDeleting, storageError == nil, let store,
              documents.contains(where: { $0.id == id }) else { return nil }
        isDeleting = true
        defer { isDeleting = false }
        let deletingCurrent = selectedID == id
        if deletingCurrent {
            pause()
            cancelGeneration()
        }
        // Include recently cancelled jobs too, such as a search followed by
        // deletion or switching away from a document still being generated.
        let pending = generationTasks.values.filter { $0.documentID == id }.map(\.task)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        guard let doc = documents.first(where: { $0.id == id }) else { return nil }
        syncPosition()
        let remaining = documents.filter { $0.id != id }
        let nextID = deletingCurrent ? remaining.first?.id : selectedID
        do {
            let archivedURL = try store.trashDocument(doc, saving: LibrarySnapshot(documents: remaining, selectedID: nextID))
            if deletingCurrent { player?.stop(); player = nil; wantsPlayback = false; isPlaying = false }
            documents = remaining; selectedID = nextID
            if deletingCurrent { elapsed = document?.offset ?? 0; showComposer = documents.isEmpty }
            errorMessage = nil; message = "条目已移到废纸篓"
            reloadTimeline(); refreshSearch(); updateNowPlaying()
            return archivedURL
        } catch {
            errorMessage = "删除未完成：\(error.localizedDescription)"
            return nil
        }
    }

    private var selectedDocumentIndex: Int? { documents.firstIndex { $0.id == selectedID } }
    private func setPosition(index: Int, offset: Double) {
        guard let i = selectedDocumentIndex else { return }
        documents[i].chunkIndex = index; documents[i].offset = offset; elapsed = offset
        reloadTimeline()
    }
    private func reloadTimeline() {
        readingTimeline = nil
        guard let doc = document, doc.chunks.indices.contains(currentIndex), let store,
              let filename = doc.chunks[currentIndex].audioFile, let duration = doc.chunks[currentIndex].duration else { return }
        let chunk = doc.chunks[currentIndex]
        let audio = store.root.appendingPathComponent("Audio").appendingPathComponent(doc.id.uuidString).appendingPathComponent(filename)
        readingTimeline = SpeechTimeline.load(for: audio, text: chunk.text, duration: duration)
            ?? SpeechTimeline.estimated(text: chunk.text, duration: duration)
    }
    private func syncPosition() { if let i = selectedDocumentIndex { documents[i].offset = elapsed } }

    private func playCachedCurrent() {
        guard wantsPlayback, let doc = document, doc.chunks.indices.contains(currentIndex), let store else { return }
        let chunk = doc.chunks[currentIndex]
        guard let name = chunk.audioFile else { message = "正在准备当前段落…"; return }
        do {
            let directory = try store.audioDirectory(for: doc.id)
            let url = directory.appendingPathComponent(name)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self; p.enableRate = true; p.rate = Float(rate); p.volume = playbackVolume
            p.currentTime = min(elapsed, max(0, p.duration - 0.01)); p.prepareToPlay()
            guard p.play() else {
                player = p; wantsPlayback = false; isPlaying = false
                errorMessage = "音频设备暂时不可用，请检查系统声音输出后重试。"
                return
            }
            player = p; elapsed = p.currentTime; isPlaying = true; message = "正在朗读"
            reloadTimeline()
        } catch {
            if let i = selectedDocumentIndex { documents[i].chunks[currentIndex].audioFile = nil; documents[i].chunks[currentIndex].duration = nil }
            errorMessage = "缓存音频暂时无法播放，将重新准备。\(error.localizedDescription)"
            player = nil; isPlaying = false
            readingTimeline = nil
        }
    }

    private func startGeneration() {
        guard generationTask == nil, let docID = selectedID, let store else { return }
        let token = UUID(); generationID = token
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.generationTasks[token] = nil
                if self.generationID == token { self.isPreparing = false; self.generationTask = nil }
            }
            while !Task.isCancelled {
                guard let i = self.documents.firstIndex(where: { $0.id == docID }), self.selectedID == docID else { return }
                let doc = self.documents[i]
                let start = min(doc.chunkIndex, max(0, doc.chunks.count - 1))
                let order = Array(start..<doc.chunks.count) + Array(0..<start)
                guard let chunkIndex = order.first(where: { doc.chunks[$0].audioFile == nil || doc.chunks[$0].duration == nil }) else { return }
                let chunk = doc.chunks[chunkIndex]
                self.isPreparing = true
                do {
                    let directory = try store.audioDirectory(for: docID)
                    let safeVoice = doc.voiceID.replacingOccurrences(of: "/", with: "_")
                    let destination = directory.appendingPathComponent("\(chunk.id.uuidString)-\(safeVoice)")
                    var audioURL: URL?
                    for ext in ["mp3", "aiff"] {
                        let candidate = destination.appendingPathExtension(ext)
                        if FileManager.default.fileExists(atPath: candidate.path), let check = try? AVAudioPlayer(contentsOf: candidate), check.duration > 0 { audioURL = candidate; break }
                    }
                    if audioURL == nil { audioURL = try await SpeechService.synthesize(text: chunk.text, voiceID: doc.voiceID, destination: destination) }
                    try Task.checkCancellation()
                    guard self.generationID == token, let j = self.documents.firstIndex(where: { $0.id == docID }), self.documents[j].voiceID == doc.voiceID, let url = audioURL else { return }
                    let audio = try AVAudioPlayer(contentsOf: url)
                    guard audio.duration.isFinite, audio.duration > 0.05 else { throw NSError(domain: "Manting", code: 2, userInfo: [NSLocalizedDescriptionKey: "语音服务返回了空音频。"] ) }
                    self.documents[j].chunks[chunkIndex].audioFile = url.lastPathComponent
                    self.documents[j].chunks[chunkIndex].duration = audio.duration
                    self.persist()
                    if self.currentIndex == chunkIndex && self.wantsPlayback && self.player == nil { self.playCachedCurrent() }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self.generationID == token else { return }
                    self.errorMessage = "\(doc.voiceID.hasPrefix("system-") ? "本机" : "在线")语音准备失败：\(error.localizedDescription)"
                    self.message = "已保存进度，可以重试"
                    if self.player == nil { self.wantsPlayback = false; self.isPlaying = false }
                    return
                }
            }
        }
        if let generationTask { generationTasks[token] = (docID, generationTask) }
    }

    private func cancelGeneration() { generationID = UUID(); generationTask?.cancel(); generationTask = nil; isPreparing = false }
    private func tick() {
        guard let player, isPlaying else { return }
        elapsed = player.currentTime
        if Date().timeIntervalSince(lastSave) >= 1 { syncPosition(); persist(); updateNowPlaying() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.didFinish(player, successfully: flag) }
    }
    private func didFinish(_ finished: AVAudioPlayer, successfully: Bool) {
        guard player === finished, let doc = document else { return }
        player = nil; isPlaying = false
        if !successfully { wantsPlayback = false; errorMessage = "音频播放中断，进度已保留。"; persist(); return }
        if currentIndex + 1 < doc.chunks.count {
            setPosition(index: currentIndex + 1, offset: 0); persist()
            if wantsPlayback { playCachedCurrent(); startGeneration() }
        } else {
            elapsed = doc.chunks.last?.duration ?? elapsed; syncPosition(); wantsPlayback = false
            message = "已听完"; persist(); updateNowPlaying()
        }
    }
    func persist() {
        guard storageError == nil, let store else { return }
        syncPosition()
        do { try store.save(LibrarySnapshot(documents: documents, selectedID: selectedID)); lastSave = Date() }
        catch { storageError = "保存失败，已有资料未删除：\(error.localizedDescription)"; player?.pause(); isPlaying = false; wantsPlayback = false; cancelGeneration() }
    }
    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        pause(); cancelGeneration(); timer?.invalidate(); persist()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver); self.sleepObserver = nil }
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
    }
    func revealStorage() { if let store { NSWorkspace.shared.open(store.root) } }

    private func installMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerModel) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in Task { @MainActor in if let self { action(self) } }; return .success }
            remoteTargets.append((command, target))
        }
        bind(center.togglePlayPauseCommand) { $0.togglePlayback() }
        bind(center.playCommand) { $0.play() }; bind(center.pauseCommand) { $0.pause() }
        center.skipBackwardCommand.preferredIntervals = [15]; center.skipForwardCommand.preferredIntervals = [15]
        bind(center.skipBackwardCommand) { $0.skip(-15) }; bind(center.skipForwardCommand) { $0.skip(15) }
    }
    private func updateNowPlaying() {
        guard let doc = document else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        var info: [String: Any] = [MPMediaItemPropertyTitle: doc.title, MPMediaItemPropertyArtist: "慢听 · \(voiceName)", MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0]
        if allPrepared { info[MPMediaItemPropertyPlaybackDuration] = totalDuration; info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = timelinePosition }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}
