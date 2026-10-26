import Foundation
import AppKit
import AVFoundation

/// Own process/run loop: file synthesis callbacks cannot be delayed by UI work.
/// File positions give word anchors; they are approximate by one output buffer.
@MainActor final class SpeechFileRecorder: NSObject, NSSpeechSynthesizerDelegate {
    let output: URL
    var finished = false
    var success = false
    var events: [SpeechTimeline.SystemEvent] = []
    init(output: URL) { self.output = output }
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord range: NSRange, of string: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? UInt64) ?? 0
        events.append(.init(location: range.location, length: range.length, byteOffset: size))
    }
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking flag: Bool) {
        success = flag; finished = true
    }
}

@main struct SpeechHelper {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else { throw failure("invalid arguments") }
            let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            let output = URL(fileURLWithPath: CommandLine.arguments[2])
            guard let voice = NSSpeechSynthesizer.availableVoices.first(where: { $0.rawValue.lowercased().contains("tingting") || $0.rawValue.lowercased().contains("ting-ting") }),
                  let speaker = NSSpeechSynthesizer(voice: voice) else { throw failure("Tingting unavailable") }
            let recorder = SpeechFileRecorder(output: output)
            speaker.delegate = recorder
            signal(SIGTERM, SIG_IGN)
            let cancellation = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            cancellation.setEventHandler { speaker.stopSpeaking(); recorder.success = false; recorder.finished = true }
            cancellation.resume()
            defer { cancellation.cancel() }
            guard speaker.startSpeaking(text, to: output) else { throw failure("synthesis start failed") }
            let started = Date()
            while !recorder.finished {
                if Date().timeIntervalSince(started) > 26 { speaker.stopSpeaking(); throw failure("synthesis timeout") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard recorder.success else { throw failure("synthesis cancelled") }
            let file = try AVAudioFile(forReading: output)
            let duration = Double(file.length) / file.fileFormat.sampleRate
            let bytesPerSecond = file.fileFormat.sampleRate * Double(file.fileFormat.streamDescription.pointee.mBytesPerFrame)
            let data = try Data(contentsOf: output)
            let dataOffset = try aiffDataOffset(data)
            if let timeline = SpeechTimeline.system(text: text, events: recorder.events, dataOffset: UInt64(dataOffset), bytesPerSecond: bytesPerSecond, duration: duration) {
                try timeline.save(for: output)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func aiffDataOffset(_ data: Data) throws -> Int {
        func uint32(_ at: Int) -> Int { data[at..<at + 4].reduce(0) { ($0 << 8) | Int($1) } }
        guard data.count >= 12, String(data: data[0..<4], encoding: .ascii) == "FORM" else { throw failure("invalid AIFF") }
        var offset = 12
        while offset + 8 <= data.count {
            let length = uint32(offset + 4)
            guard length <= data.count - offset - 8 else { throw failure("invalid audio chunk") }
            if String(data: data[offset..<offset + 4], encoding: .ascii) == "SSND", length >= 8 {
                return offset + 16 + uint32(offset + 8)
            }
            offset += 8 + length + length % 2
        }
        throw failure("missing audio data")
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "MantingSpeechHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
