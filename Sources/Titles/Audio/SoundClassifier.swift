import Foundation
import AVFoundation
import SoundAnalysis
@testable import TitlesCore

/// Apple's built-in sound classifier (SoundAnalysis, part of macOS, nothing to download).
/// It names the sounds in each second of audio from about 300 kinds, speech among them,
/// so music, a door or footsteps aren't taken for speech. Mac only: a Windows port plugs
/// its own engine into `SpeechClassifier`.
struct SoundClassifier: SpeechClassifier {
    /// The sounds that count as someone speaking.
    static let speechLabels = ["speech", "shout", "yell", "whispering"]
    /// How long a stretch the classifier names at a time (it takes the nearest it allows),
    /// and how much each stretch overlaps the one before.
    static let window = 1.0
    static let overlap = 0.5

    func windows(samples: [Int16], sampleRate: Double) throws -> [SpeechWindow] {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return [] }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        if let window = Self.allowed(Self.window, by: request.windowDurationConstraint) {
            request.windowDuration = window
        }
        request.overlapFactor = Self.overlap
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let collector = Collector(labels: Self.speechLabels)
        try analyzer.add(request, withObserver: collector)

        // Ten seconds at a time, so a newer video (or quitting) stops it quickly.
        let chunk = max(1, Int(sampleRate * 10))
        var position = 0
        while position < samples.count {
            if Task.isCancelled {
                analyzer.removeAllRequests()
                throw CancellationError()
            }
            let n = min(chunk, samples.count - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let out = buffer.floatChannelData?[0] else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                for i in 0..<n { out[i] = Float(src[position + i]) / 32768 }
            }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
            position += n
        }
        analyzer.completeAnalysis()
        // The last results can come just after; wait for the classifier to say it's done.
        _ = collector.done.wait(timeout: .now() + 30)
        if let error = collector.error { throw error }
        return collector.windows.sorted { $0.start < $1.start }
    }

    /// The window length nearest `seconds` that the classifier allows (nil: keep its own).
    static func allowed(_ seconds: Double, by constraint: SNTimeDurationConstraint) -> CMTime? {
        let wanted = CMTime(seconds: seconds, preferredTimescale: 1000)
        switch constraint {
        case .enumeratedDurations(let durations):
            return durations.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) }
        case .durationRange(let range):
            let lo = range.start, hi = range.end
            if lo.isValid && CMTimeCompare(wanted, lo) < 0 { return lo }
            if hi.isValid && !hi.isIndefinite && CMTimeCompare(wanted, hi) > 0 { return hi }
            return wanted
        @unknown default:
            return nil
        }
    }
}

/// Collects how sure the classifier is that someone speaks, window by window.
private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
    let labels: [String]
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var found: [SpeechWindow] = []
    private var failure: Error?

    init(labels: [String]) { self.labels = labels }

    var windows: [SpeechWindow] {
        lock.lock(); defer { lock.unlock() }
        return found
    }

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let sure = labels.compactMap { result.classification(forIdentifier: $0)?.confidence }.max() ?? 0
        let start = result.timeRange.start.seconds
        let end = start + result.timeRange.duration.seconds
        guard start.isFinite, end.isFinite else { return }
        lock.lock()
        found.append(SpeechWindow(start: start, end: end, confidence: sure))
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock()
        failure = error
        lock.unlock()
        done.signal()
    }

    func requestDidComplete(_ request: SNRequest) {
        done.signal()
    }
}
