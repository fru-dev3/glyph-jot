@preconcurrency import AVFoundation
import GlyphCore
import Speech
import SwiftUI

/// The words while a recording runs. The microphone goes to Apple's on-device model as well as to
/// the file, so a meeting reads itself onto the screen as it is spoken instead of an hour later.
/// It keeps its own microphone tap beside the Recorder's, so nothing that happens here can stop
/// the recording: the sound is already on disk by another path.
///
/// These words are the screen's, not the vault's. The transcript that is kept is still made from
/// the saved audio after Stop, because that pass knows who spoke and splits the words by voice,
/// and this one hears only one running line. So the live lines stay up after Stop, dimming into
/// the second pass, and are dropped the moment the real transcript lands (`clear`).
@MainActor @Observable
final class LiveTranscript {
    /// One finished phrase, with when it was said on the recording's own clock.
    struct Line: Identifiable, Equatable {
        var id: Int
        var at: Double
        var text: String
    }

    /// The recording these words belong to; nil when nothing is listening and nothing is held.
    private(set) var conversation: String?
    private(set) var lines: [Line] = []
    /// The guess at what is being said right now, after the last finished line.
    private(set) var partial = ""
    /// The words are arriving. False while the model is still being reached, and after a failure.
    private(set) var on = false
    /// Why the words are not arriving. Said on the recording's own screen, never as a banner:
    /// the recording itself is fine, and this is the one thing that is not.
    private(set) var problem: String?

    /// Anything to show at all: a line, a guess, or a reason there is neither.
    var hasWords: Bool { !lines.isEmpty || !partial.isEmpty }

    private let engine = AVAudioEngine()
    private var audio: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var task: Task<Void, Never>?
    private var lastEnd: Double?
    private var next = 0

    /// Starts listening for `id`. Safe to call when speech is unavailable: the screen then says so
    /// and the recording carries on.
    func start(for id: String) {
        stop()
        conversation = id
        lines = []
        partial = ""
        problem = nil
        lastEnd = nil
        next = 0
        task = Task { await listen() }
    }

    /// Stops listening. What has been heard stays on screen for the second pass to replace.
    func stop() {
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        audio?.finish()
        audio = nil
        task?.cancel()
        task = nil
        on = false
        partial = ""
    }

    /// Forgets the words: the vault's transcript has landed and it is the better one.
    func clear(_ id: String) {
        guard conversation == id else { return }
        stop()
        conversation = nil
        lines = []
    }

    // MARK: listening

    private func listen() async {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingNewest(120))
        audio = continuation
        let mic: AVAudioFormat
        do {
            mic = try await openMicrophone(continuation)
        } catch {
            fail(error)
            return
        }
        do {
            let module = try await Transcription.make(live: true)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.module], considering: mic),
                  let converter = AVAudioConverter(from: mic, to: format) else {
                throw JotError("Speech recognition can't read this microphone's audio.")
            }
            converter.primeMethod = .none
            let analyzer = SpeechAnalyzer(modules: [module.module])
            try await analyzer.setContext(Transcription.context)
            let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
            let words = Task { @MainActor in
                for try await piece in module.pieces { self.heard(piece) }
            }
            try await analyzer.start(inputSequence: input)
            on = true
            for await buffer in stream {
                if let converted = Self.convert(buffer, converter, format) { feed.yield(AnalyzerInput(buffer: converted)) }
            }
            feed.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            _ = try? await words.value
            on = false
        } catch {
            fail(error)
        }
    }

    /// Our own tap on the input device, in parallel with the Recorder's. Starting the engine can
    /// block for seconds, so it happens off the main actor.
    private func openMicrophone(_ out: AsyncStream<AVAudioPCMBuffer>.Continuation) async throws -> AVAudioFormat {
        let engine = engine
        return try await Task.detached(priority: .userInitiated) {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureError.noMicrophone }
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
                out.yield(buffer)
            }
            engine.prepare()
            do { try engine.start() } catch {
                input.removeTap(onBus: 0)
                throw JotError("The words can't be heard live: \(error.localizedDescription)")
            }
            return format
        }.value
    }

    /// A finished phrase becomes a line, or joins the one before it when it followed straight on.
    /// An unfinished one is the guess under the last line. The pause that starts a new line is
    /// the same one that starts a new paragraph in a saved transcript.
    private func heard(_ piece: Transcription.Piece) {
        let words = Transcription.corrected(piece.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !words.isEmpty else { return }
        let start = CMTimeGetSeconds(piece.range.start)
        guard piece.isFinal else { partial = words; return }
        partial = ""
        if let last = lines.indices.last, let lastEnd, start - lastEnd < Transcription.paragraphPause {
            lines[last].text += " " + words
        } else {
            lines.append(Line(id: next, at: start, text: words))
            next += 1
        }
        self.lastEnd = CMTimeGetSeconds(piece.range.end)
    }

    private func fail(_ error: Error) {
        on = false
        partial = ""
        audio?.finish()
        audio = nil
        // Still downloading is not a failure worth a sentence: it says so instead.
        problem = (error as? JotError) == .notReady
            ? "The speech model is still downloading. The transcript is written when you stop."
            : error.localizedDescription
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter,
                                            _ format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }
}
