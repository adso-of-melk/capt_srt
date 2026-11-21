import Foundation
import AVFoundation
@testable import TitlesCore

/// Owns the decoded audio for the current video and loads it in the background.
@MainActor
final class AudioStore: ObservableObject {
    @Published private(set) var waveform: Waveform?
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// When people speak in the video (the waveform is coloured there), worked out from the
    /// decoded sound once it's in, in the background. Nil until then. First from loudness
    /// alone (quick), then from what the sound classifier hears (`classifier`).
    @Published private(set) var speech: [ClosedRange<Double>]? {
        didSet { speechRevision += 1 }
    }
    /// Goes up whenever `speech` changes, so the waveform redraws.
    private(set) var speechRevision = 0
    /// Tells speech from other sound: Apple's sound classifier on the Mac.
    var classifier: SpeechClassifier? = SoundClassifier()

    private var task: Task<Void, Never>?
    private var generation = UUID()
    /// What the classifier heard in each video this session, so going back to one is quick.
    private var heardSpeech: [URL: [ClosedRange<Double>]] = [:]

    func load(url: URL) {
        task?.cancel()
        waveform = nil
        speech = nil
        progress = 0
        errorMessage = nil
        isLoading = true
        let gen = UUID()
        generation = gen
        let classifier = classifier, known = heardSpeech[url]
        task = Task.detached(priority: .userInitiated) { [self] in
            do {
                let wf = try await AudioDecoder.decode(url: url) { p in
                    Task { @MainActor in
                        if self.generation == gen { self.progress = p }
                    }
                }
                await MainActor.run {
                    if self.generation == gen {
                        self.waveform = wf
                        self.isLoading = false
                    }
                }
                // Then where the speech is: from loudness at once, then from what the
                // classifier hears (it takes longer).
                try Task.checkCancellation()
                if let known {
                    await MainActor.run {
                        if self.generation == gen { self.speech = known }
                    }
                    return
                }
                let levels = FileMatcher.Speech.levels(samples: wf.samples, sampleRate: wf.sampleRate)
                try Task.checkCancellation()
                guard levels.count > 50 else {
                    await MainActor.run {
                        if self.generation == gen { self.speech = [] }
                    }
                    return
                }
                let loud = FileMatcher.Speech(levels: levels).stretches
                await MainActor.run {
                    if self.generation == gen { self.speech = loud }
                }
                guard let classifier else { return }
                let heard = try FileMatcher.Speech(samples: wf.samples, sampleRate: wf.sampleRate,
                                                   classifier: classifier).stretches
                await MainActor.run {
                    if self.generation == gen {
                        self.speech = heard
                        self.heardSpeech[url] = heard
                    }
                }
            } catch is CancellationError {
                // A newer load replaced this one.
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    if self.generation == gen {
                        self.errorMessage = message
                        self.isLoading = false
                    }
                }
            }
        }
    }

    func clear() {
        task?.cancel()
        generation = UUID()
        waveform = nil
        speech = nil
        isLoading = false
        errorMessage = nil
    }
}

/// Plays very short snippets ("grains") of the decoded audio while scrubbing,
/// so audio never waits on the video decoder.
@MainActor
final class ScrubAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioDecoder.sampleRate, channels: 1)!
    /// Lives as long as the app, so the observer is never removed.
    private var configObserver: NSObjectProtocol?

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // macOS stops the engine when the audio output changes (another device, a new
        // sample rate after video playback, headphones). Reconnect so grains keep sounding.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.node.stop()
            self.engine.disconnectNodeOutput(self.node)
            self.engine.connect(self.node, to: self.engine.mainMixerNode, format: self.format)
        }
    }

    func grain(at t: Double, from wf: Waveform, length: Double = 0.07) {
        // Check the engine itself each time: it can be stopped behind our back.
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return }
        }
        let n = Int(length * wf.sampleRate)
        guard n > 16, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let channel = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let start = Int(t * wf.sampleRate)
        let fade = n / 6
        wf.samples.withUnsafeBufferPointer { samples in
            for i in 0..<n {
                let idx = start + i
                var v: Float = (idx >= 0 && idx < samples.count) ? Float(samples[idx]) / 32768 : 0
                if i < fade { v *= Float(i) / Float(fade) }
                else if i > n - fade { v *= Float(n - i) / Float(fade) }
                channel[i] = v
            }
        }
        node.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }
}
