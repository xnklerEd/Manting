import SwiftUI
import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var player: PlayerModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { Self.player?.shutdown(); return .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct MantingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = PlayerModel(playbackVolume: ProcessInfo.processInfo.environment["MANTING_MUTE_PLAYBACK"] == "1" ? 0 : 1)
    var body: some Scene {
        WindowGroup("慢听") {
            ReaderView(model: model)
                .onAppear { AppDelegate.player = model; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1000, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建文本") { model.newText() }.keyboardShortcut("n")
                Button("朗读剪贴板") { model.pasteAndRead() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("播放") {
                Button(model.playbackLabel) { model.togglePlayback() }.keyboardShortcut(" ", modifiers: []).disabled(!model.canPlay || model.showComposer || model.isSearchEditing)
                Button("后退 15 秒") { model.skip(-15) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("前进 15 秒") { model.skip(15) }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Divider()
                Button("从头播放") { model.restart() }.disabled(!model.canPlay)
            }
            CommandGroup(after: .textEditing) {
                Button("查找文本") { model.focusSearch() }.keyboardShortcut("f").disabled(model.document == nil)
                Button("下一个匹配") { model.moveSearchResult(1) }.keyboardShortcut("g").disabled(model.searchMatches.isEmpty)
                Button("上一个匹配") { model.moveSearchResult(-1) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(model.searchMatches.isEmpty)
            }
        }
    }
}

struct ReaderView: View {
    @ObservedObject var model: PlayerModel
    @AppStorage("readerFontSize") private var readerFontSize = 32.0
    @AppStorage("readerShowPinyin") private var readerShowPinyin = true
    @AppStorage("readerEnlargeCharacter") private var readerEnlargeCharacter = true
    @StateObject private var readingFocus = ReadingTextView.FocusCoordinator()
    @State private var followReading = true
    @State private var expandedWindowFrame: NSRect?
    @FocusState private var editorFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var deletionCandidate: ReadingDocument?
    private let accent = Color(red: 0.24, green: 0.46, blue: 0.35)

    var body: some View {
        VStack(spacing: 0) {
            if !model.miniMode {
                HStack(spacing: 0) {
                    sidebar.frame(width: 205)
                    Divider()
                    VStack(spacing: 0) {
                        if let error = model.storageError { errorBanner(error, storage: true) }
                        if let error = model.errorMessage { errorBanner(error, storage: false) }
                        if model.showComposer || model.document == nil { composer } else { reader }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            PlaybackBar(model: model, clock: model.playbackClock)
        }
        .frame(minWidth: 680, minHeight: model.miniMode ? 165 : 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .disabled(model.isDeleting)
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: searchFocused) { _, value in model.isSearchEditing = value }
        .alert("删除文本条目？", isPresented: Binding(get: { deletionCandidate != nil }, set: { if !$0 { deletionCandidate = nil } }), presenting: deletionCandidate) { doc in
            Button("删除", role: .destructive) { Task { await model.deleteDocument(doc.id) } }
            Button("取消", role: .cancel) {}
        } message: { doc in
            Text("“\(doc.title)”\n正文和音频将移到废纸篓。")
        }
        .onChange(of: model.miniMode) { _, compact in
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
            if compact { expandedWindowFrame = window.frame }
            let normalFrame = expandedWindowFrame
            DispatchQueue.main.async {
                if compact {
                    var target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 760, height: 165))
                    target.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - target.height)
                    window.setFrame(target, display: true, animate: true)
                } else if let normalFrame { window.setFrame(normalFrame, display: true, animate: true) }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.document != nil && !model.showComposer {
                    Picker("音色", selection: Binding(get: { model.document?.voiceID ?? model.defaultVoiceID }, set: { model.changeVoice($0) })) {
                        ForEach(SpeechService.voices) { voice in Text(voice.name).tag(voice.id) }
                    }.frame(width: 165).help("在线音色免费，无需账号；本机音色无需联网。更换音色会重新生成音频，保留当前段落。")
                    Button { deletionCandidate = model.document } label: { Label("删除当前条目", systemImage: "trash") }.help("删除当前条目")
                }
                Button { model.miniMode.toggle() } label: { Label(model.miniMode ? "展开正文" : "迷你模式", systemImage: model.miniMode ? "rectangle.expand.vertical" : "rectangle.compress.vertical") }
                    .help(model.miniMode ? "展开正文" : "收起正文")
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { model.newText() } label: { Label("新建文本", systemImage: "plus").frame(maxWidth: .infinity) }.controlSize(.large)
            Text("收听列表").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.documents) { doc in
                        Button { model.select(doc.id) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(doc.title).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                Text(progressLabel(doc)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                                .background(model.selectedID == doc.id && !model.showComposer ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).contextMenu {
                            Button("删除条目…", role: .destructive) { deletionCandidate = doc }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("内容与进度保存在本机").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 7)
        }.padding(14).background(Color(nsColor: .underPageBackgroundColor))
    }

    private func progressLabel(_ doc: ReadingDocument) -> String {
        let index = min(doc.chunkIndex, max(0, doc.chunks.count - 1))
        let position = doc.chunks.prefix(index).reduce(0) { $0 + model.duration(of: $1) } + (doc.id == model.selectedID ? model.elapsed : doc.offset)
        return "\(model.time(position)) · \(doc.chunks.count) 段"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("把文字交给声音").font(.system(size: 28, weight: .semibold))
            Text("粘贴文章或 AI 回答，随时暂停，下次接着听。").foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty { Text("在这里粘贴想听的文字…").foregroundStyle(.tertiary).padding(10).allowsHitTesting(false) }
                TextEditor(text: $model.draft).font(.system(size: 15)).scrollContentBackground(.hidden).padding(5).focused($editorFocused)
            }.frame(minHeight: 200).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
            HStack {
                Picker("音色", selection: $model.defaultVoiceID) { ForEach(SpeechService.voices) { Text($0.name).tag($0.id) } }.frame(maxWidth: 260)
                Spacer()
                Text("\(model.draft.count) 字符").foregroundStyle(.secondary).font(.caption)
            }
            Text(model.defaultVoiceID.hasPrefix("system-") ? "本机朗读：无需联网，文字不会发送出去。" : "免费在线音色：文字发送给 Microsoft 生成声音；生成后保存在本机，无需注册。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("直接朗读剪贴板") { model.pasteAndRead() }.controlSize(.large)
                Spacer()
                Button("开始朗读") { editorFocused = false; model.add(text: model.draft) }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: .command).disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.storageError != nil)
            }
        }.padding(32)
    }

    private var reader: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.document?.title ?? "").font(.system(size: 24, weight: .semibold)).lineLimit(2)
                    Text("第 \(model.currentIndex + 1) / \(model.document?.chunks.count ?? 0) 段 · 点击段落定位").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Picker("字号", selection: $readerFontSize) {
                        ForEach([16.0, 20, 24, 28, 32, 40, 48, 56, 64], id: \.self) { size in
                            Text("\(Int(size)) 号").tag(size)
                        }
                    }.frame(width: 132).font(.caption).accessibilityLabel("正文字号")
                        .help("调整正文字号，自动保存；字号越大，每屏显示的文字越少。")
                    HStack(spacing: 14) {
                        Toggle("逐字高亮", isOn: $model.highlightEnabled)
                            .help("按播放器时间逐字移动；多字词内采用插值，暂停、倍速和跳转时同步跟随。")
                        Toggle("跟随朗读", isOn: $followReading)
                    }.toggleStyle(.checkbox).font(.caption)
                    HStack(spacing: 14) {
                        Toggle("放大当前字", isOn: $readerEnlargeCharacter)
                            .help("当前高亮字显示为正文字号的两倍，并显示拼音；预留字位，朗读时文字不会反复换行。")
                        Toggle("全文拼音", isOn: $readerShowPinyin)
                            .help("自动为所有正文的汉字显示带声调拼音；设置会保存，新旧文本都适用。")
                    }.toggleStyle(.checkbox).font(.caption)
                    if readerShowPinyin || readerEnlargeCharacter {
                        Text("自动拼音 · 多音字请核对").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)
            if model.highlightEnabled {
                HStack(spacing: 10) {
                    Text(model.highlightIsEstimated ? "旧音频 · 逐字位置为估算" : "逐字跟读 · 词内字位为估算").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if model.highlightIsEstimated {
                        Button("重新生成本篇，从本段开始") { model.calibrateHighlighting() }
                            .font(.caption).help("为本篇音频补充字词时间信息，从当前段落开头重新播放。正文和旧音频保留。")
                    }
                }.padding(.horizontal, 28).padding(.bottom, 10)
            }
            searchBar.padding(.horizontal, 28).padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if let doc = model.document {
                            ForEach(Array(doc.chunks.enumerated()), id: \.element.id) { index, chunk in
                                Button { model.jumpToChunk(index) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(String(format: "%02d", index + 1)).font(.caption2).foregroundStyle(.secondary).monospacedDigit().frame(width: 24)
                                        readingText(chunk.text, index: index).frame(maxWidth: .infinity, alignment: .leading)
                                        if chunk.audioFile != nil { Image(systemName: "checkmark").font(.caption2).foregroundStyle(.tertiary).accessibilityLabel("音频已保存") }
                                    }.padding(14).contentShape(Rectangle()).background(index == model.currentIndex ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).id(chunk.id).accessibilityLabel("从第 \(index + 1) 段开始：\(chunk.text)")
                            }
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 24)
                }.task(id: "\(model.selectedID?.uuidString ?? "")-\(model.currentIndex)-\(readerFontSize)-\(readerShowPinyin)-\(readerEnlargeCharacter)-\(model.selectedSearchMatch?.id ?? -1)") {
                    guard let doc = model.document else { return }
                    let searching = model.selectedSearchMatch != nil
                    let targetIndex = model.selectedSearchMatch?.chunkIndex ?? model.currentIndex
                    guard doc.chunks.indices.contains(targetIndex), searching || (followReading && model.searchQuery.isEmpty) else { return }
                    let target = doc.chunks[targetIndex].id
                    // Resolve lazy-row geometry once after appearance or a
                    // display-mode change. Chunk/match changes cancel stale
                    // work; the native view then reveals the exact glyph.
                    for pass in 0..<3 {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !Task.isCancelled else { return }
                        if pass < 2 { proxy.scrollTo(target, anchor: searching || !model.isPlaying ? .center : .top) }
                        readingFocus.reveal(search: searching)
                    }
                }.onChange(of: model.currentIndex) { _, value in
                    if followReading, model.searchQuery.isEmpty, let doc = model.document, doc.chunks.indices.contains(value) { proxy.scrollTo(doc.chunks[value].id, anchor: model.isPlaying ? .top : .center) }
                }
                .onChange(of: model.isPlaying) { _, playing in
                    if playing, followReading, model.searchQuery.isEmpty,
                       let doc = model.document, doc.chunks.indices.contains(model.currentIndex) {
                        proxy.scrollTo(doc.chunks[model.currentIndex].id, anchor: .top)
                    }
                }
                .onChange(of: followReading) { _, follows in
                    if follows, model.searchQuery.isEmpty, let doc = model.document, doc.chunks.indices.contains(model.currentIndex) {
                        proxy.scrollTo(doc.chunks[model.currentIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索当前文本的关键词", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityLabel("搜索关键词")
                    .onSubmit { model.playSearchResult() }
                    .onExitCommand { model.searchQuery = ""; searchFocused = false }
                if !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(model.searchMatches.isEmpty ? "无匹配" : "\(model.searchResultIndex + 1)/\(model.searchMatches.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button { model.moveSearchResult(-1) } label: { Image(systemName: "chevron.up") }.help("上一个匹配 ⇧⌘G").accessibilityLabel("上一个匹配").disabled(model.searchMatches.isEmpty)
                    Button { model.moveSearchResult(1) } label: { Image(systemName: "chevron.down") }.help("下一个匹配 ⌘G").accessibilityLabel("下一个匹配").disabled(model.searchMatches.isEmpty)
                    Button { model.searchQuery = ""; searchFocused = true } label: { Image(systemName: "xmark") }.help("清空搜索").accessibilityLabel("清空搜索")
                }
            }
            if let match = model.selectedSearchMatch {
                Button { searchFocused = false; model.playSearchResult() } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "play.circle.fill").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(match.snippet).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                            Text("第 \(match.chunkIndex + 1) 段 · 从本句开始朗读 ↩").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityLabel("从搜索结果所在句子开始朗读：\(match.snippet)")
            }
        }
    }

    private func readingText(_ value: String, index: Int) -> some View {
        let start = model.document?.chunks.prefix(index).reduce(0) { $0 + $1.text.utf16.count } ?? 0
        let focusedRange = model.selectedSearchMatch.flatMap { match in
            match.chunkIndex == index ? TextSearch.highlightRanges(in: value, chunkStart: start, matches: [match]).first : nil
        }
        return ReadingTextView(text: value, fontSize: CGFloat(readerFontSize), showPinyin: readerShowPinyin,
                               enlargeReading: readerEnlargeCharacter && model.highlightEnabled,
                               readingRange: index == model.currentIndex ? model.readingRange : nil,
                               playbackClock: index == model.currentIndex && model.highlightEnabled ? model.playbackClock : nil,
                               timeline: index == model.currentIndex && model.highlightEnabled ? model.readingTimeline : nil,
                               followsReading: index == model.currentIndex && model.isPlaying && followReading && model.searchQuery.isEmpty,
                               searchRanges: TextSearch.highlightRanges(in: value, chunkStart: start, matches: model.searchMatches),
                               focusedSearchRange: focusedRange, focusCoordinator: readingFocus) {
            model.jumpToChunk(index)
        }
    }

    private func errorBanner(_ text: String, storage: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text(text).font(.caption).textSelection(.enabled)
            Spacer()
            if storage { Button("查看资料") { model.revealStorage() } }
            else {
                Button("重试") { model.play() }
                if model.isOnline { Button("用本机语音") { model.useOfflineVoice() } }
                Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
            }
        }.padding(12).background(Color.orange.opacity(0.12))
    }

}

struct PlaybackBar: View {
    @ObservedObject var model: PlayerModel
    let clock: PlaybackClock
    @State private var seeking = false
    @State private var seekValue = 0.0
    @State private var displayedElapsed = 0.0
    private var displayedPosition: Double { model.timelinePosition - model.elapsed + displayedElapsed }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(model.document?.title ?? "粘贴文字，即可开始").font(.caption).lineLimit(1)
                Spacer()
                if model.isPreparing { ProgressView().controlSize(.small); Text("正在准备 \(model.preparedCount)/\(model.document?.chunks.count ?? 0) 段").font(.caption).foregroundStyle(.secondary) }
                else if model.allPrepared { Text("音频已保存 · 可离线听").font(.caption).foregroundStyle(.secondary) }
                else { Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            HStack(spacing: 12) {
                Text(model.time(seeking ? seekValue : displayedPosition)).monospacedDigit().font(.caption).frame(width: 50, alignment: .leading)
                Slider(value: Binding(get: { seeking ? seekValue : min(displayedPosition, max(1, model.totalDuration)) }, set: { seekValue = $0 }), in: 0...max(1, model.totalDuration), onEditingChanged: { editing in
                    if editing { seekValue = model.timelinePosition; seeking = true }
                    else { seeking = false; model.seek(to: seekValue) }
                }).disabled(!model.canPlay).accessibilityLabel("播放进度")
                Text("\(model.allPrepared ? "" : "约 ")\(model.time(model.totalDuration))").monospacedDigit().font(.caption).foregroundStyle(.secondary).frame(minWidth: 50, alignment: .trailing)
            }
            HStack {
                Text(model.document == nil ? "免费 · 无需账号" : "\(model.voiceName) · \(model.isOnline ? "在线生成" : "本机生成")").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 22) {
                    Button { model.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title2) }.buttonStyle(.plain).help("后退 15 秒").accessibilityLabel("后退 15 秒")
                    Button { model.togglePlayback() } label: { Label(model.playbackLabel, systemImage: model.isPlaying ? "pause.fill" : "play.fill").frame(minWidth: 84) }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityLabel(model.playbackLabel)
                    Button { model.skip(15) } label: { Image(systemName: "goforward.15").font(.title2) }.buttonStyle(.plain).help("前进 15 秒").accessibilityLabel("前进 15 秒")
                }.disabled(!model.canPlay)
                HStack {
                    Spacer()
                    Picker("倍速", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) { ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } }.labelsHidden().frame(width: 85).disabled(!model.canPlay).accessibilityLabel("播放速度")
                    Menu { Button("从头播放") { model.restart() }; Button("查看本地资料") { model.revealStorage() } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                }.frame(maxWidth: .infinity)
            }
        }.padding(.horizontal, 22).padding(.vertical, 16)
            .onReceive(clock.$elapsed.throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)) { displayedElapsed = $0 }
    }
}
