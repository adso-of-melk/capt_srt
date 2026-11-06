import Foundation
import AVFoundation

/// Owns the decoded audio for the current video and loads it in the background.
@MainActor
final class AudioStore: ObservableObject {
    @Published private(set) var waveform: Waveform?
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var task: Task<Void, Never>?
    private var generation = UUID()

    func load(url: URL) {
        task?.cancel()
        waveform = nil
        progress = 0
        errorMessage = nil
        isLoading = true
        let gen = UUID()
        generation = gen
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

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
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
