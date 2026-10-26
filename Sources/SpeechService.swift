import Foundation
import AVFoundation

struct SpeechVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
}

/// Speech synthesis is independent of playback: completed audio is cached by the caller.
/// The online wire protocol is documented by https://github.com/rany2/edge-tts.
/// This implementation uses only system frameworks and never installs a runtime.
enum SpeechService {
    static let voices: [SpeechVoice] = [
        .init(id: "zh-CN-XiaoxiaoNeural", name: "晓晓 · 自然女声", detail: "免费在线 · 中文神经语音"),
        .init(id: "zh-CN-YunxiNeural", name: "云希 · 自然男声", detail: "免费在线 · 中文神经语音"),
        .init(id: "system-tingting", name: "婷婷 · 离线女声", detail: "macOS 系统语音 · 文字不联网")
    ]

    static func synthesize(text: String, voiceID: String, destination: URL) async throws -> URL {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechFailure.invalidText("没有可朗读的文字。")
        }
        guard voices.contains(where: { $0.id == voiceID }) else {
            throw SpeechFailure.invalidText("这个音色暂不支持，请重新选择。")
        }
        // One deadline covers connection, synthesis and file validation.
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if voiceID == "system-tingting" {
                    return try await systemAudio(text: text, destination: destination)
                }
                return try await onlineAudio(text: text, voice: voiceID, destination: destination)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw SpeechFailure.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private static func onlineAudio(text: String, voice: String, destination: URL) async throws -> URL {
        let escapedText = xmlText(text)
        guard escapedText.utf8.count <= 4096 else {
            throw SpeechFailure.invalidText("单段文字过长，请拆成较短段落后重试。")
        }
        // These are public Edge Read Aloud protocol constants, not a user credential.
        // The service now expects the version 2 token; the old single SHA-256 value was
        // rejected during the handshake with HTTP 403. EdgeToken documents the format.
        let publicClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        let browserVersion = "143.0.3650.75"
        var components = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        components.queryItems = [
            .init(name: "TrustedClientToken", value: publicClientToken),
            .init(name: "ConnectionId", value: requestID()),
            .init(name: "Sec-MS-GEC", value: EdgeToken.secMsGec()),
            .init(name: "Sec-MS-GEC-Version", value: "2-\(browserVersion)")
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 25)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("muid=\(requestID().uppercased());", forHTTPHeaderField: "Cookie")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 2 * 1024 * 1024
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            var boundaries: [SpeechTimeline.Boundary] = []
            let audio = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                socket.resume()
                let config = "X-Timestamp:\(timestamp())\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"true\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
                try await socket.send(.string(config))
                let serverVoice = "Microsoft Server Speech Text to Speech Voice (zh-CN, \(voice.dropFirst(6)))"
                let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'><voice name='\(serverVoice)'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(escapedText)</prosody></voice></speak>"
                try await socket.send(.string("X-RequestId:\(requestID())\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp())Z\r\nPath:ssml\r\n\r\n\(ssml)"))
                var accumulated = Data()
                while true {
                    try Task.checkCancellation()
                    let message = try await socket.receive()
                    switch message {
                    case .string(let response):
                        let path = header("Path", in: response.components(separatedBy: "\r\n\r\n").first ?? response)
                        if path == "audio.metadata", let separator = response.range(of: "\r\n\r\n") {
                            boundaries += SpeechTimeline.boundaries(from: Data(response[separator.upperBound...].utf8))
                        }
                        if path == "turn.end" {
                            guard !accumulated.isEmpty else { throw SpeechFailure.emptyAudio }
                            return accumulated
                        }
                    case .data(let frame):
                        guard frame.count >= 2 else { throw SpeechFailure.malformedResponse }
                        let headerLength = Int(frame[frame.startIndex]) * 256 + Int(frame[frame.startIndex + 1])
                        guard headerLength <= frame.count - 2 else { throw SpeechFailure.malformedResponse }
                        let endOfHeader = headerLength + 2
                        guard let headers = String(data: frame.subdata(in: 2..<endOfHeader), encoding: .utf8),
                              header("Path", in: headers) == "audio" else { throw SpeechFailure.malformedResponse }
                        let payload = frame.subdata(in: endOfHeader..<frame.count)
                        if payload.isEmpty { continue }
                        guard header("Content-Type", in: headers) == "audio/mpeg" else { throw SpeechFailure.malformedResponse }
                        accumulated.append(payload)
                        guard accumulated.count <= 12 * 1024 * 1024 else { throw SpeechFailure.malformedResponse }
                    @unknown default:
                        throw SpeechFailure.malformedResponse
                    }
                }
            }, onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            })
            try Task.checkCancellation()
            let player = try AVAudioPlayer(data: audio, fileTypeHint: AVFileType.mp3.rawValue)
            guard player.duration.isFinite, player.duration > 0 else { throw SpeechFailure.emptyAudio }
            let final = destination.appendingPathExtension("mp3")
            try audio.write(to: final, options: .atomic)
            if let timeline = SpeechTimeline.online(text: text, boundaries: boundaries, duration: player.duration) {
                try timeline.save(for: final)
            }
            return final
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let known = error as? SpeechFailure { throw known }
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            throw SpeechFailure.network(status: status, reason: (error as NSError).localizedDescription)
        }
    }

    private static func systemAudio(text: String, destination: URL) async throws -> URL {
        let temporaryBase = destination.deletingLastPathComponent().appendingPathComponent(".speech-\(UUID().uuidString)")
        let input = temporaryBase.appendingPathExtension("txt")
        let output = temporaryBase.appendingPathExtension("aiff")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: SpeechTimeline.metadataURL(for: output))
        }
        try Data(text.utf8).write(to: input, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let process = Process()
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.executableURL = executable.deletingLastPathComponent().appendingPathComponent("MantingSpeechHelper")
        process.arguments = [input.path, output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let lifetime = SpeechProcessLifetime()
        do {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { process in
                        if process.terminationStatus == 0 { continuation.resume() }
                        else { continuation.resume(throwing: SpeechFailure.systemVoice) }
                    }
                    do { try lifetime.start(process) }
                    catch { continuation.resume(throwing: error) }
                }
                try Task.checkCancellation()
            }, onCancel: { lifetime.cancel() })
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        let audio = try Data(contentsOf: output)
        let player = try AVAudioPlayer(data: audio, fileTypeHint: AVFileType.aiff.rawValue)
        guard player.duration.isFinite, player.duration > 0 else { throw SpeechFailure.emptyAudio }
        try Task.checkCancellation()
        let final = destination.appendingPathExtension("aiff")
        try audio.write(to: final, options: .atomic)
        if let timeline = SpeechTimeline.load(for: output, text: text, duration: player.duration) {
            try timeline.save(for: final)
        }
        return final
    }

    private static func requestID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private static func header(_ name: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].caseInsensitiveCompare(name) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func xmlText(_ text: String) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { value in
            (value.value <= 8 || (11...12).contains(value.value) || (14...31).contains(value.value)) ? UnicodeScalar(32)! : value
        }))
        return cleaned.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private enum SpeechFailure: LocalizedError {
    case invalidText(String)
    case timeout
    case emptyAudio
    case malformedResponse
    case systemVoice
    case network(status: Int?, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidText(let message): return message
        case .timeout: return "语音生成超过 30 秒。请检查网络后重试，或选择婷婷离线音色。"
        case .emptyAudio: return "没有收到可播放的语音，请重试或切换音色。"
        case .malformedResponse: return "在线语音服务返回了无法识别的内容，请重试或选择婷婷离线音色。"
        case .systemVoice: return "macOS 婷婷语音生成失败。请检查系统设置中的中文朗读声音。"
        case .network(let status, let reason):
            let detail = status.map { "HTTP \($0)" } ?? reason
            return "在线语音暂不可用（\(detail)）。请重试，或选择婷婷离线音色。"
        }
    }
}

/// Serializes launching and cancellation so cancelling just before launch cannot orphan say.
private final class SpeechProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        self.process = process
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
}
