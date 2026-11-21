import Foundation

/// A stretch of sound a sound classifier listened to, and how sure it is (0 to 1) that
/// someone speaks in it.
struct SpeechWindow: Sendable, Equatable {
    var start: Double
    var end: Double
    var confidence: Double
}

/// Tells speech apart from other sound: music, doors, footsteps, traffic. Loudness alone
/// can't, since it finds every sound that rises above the quiet around it; loudness then
/// only sets where each stretch of speech starts and ends (`FileMatcher.Speech`).
///
/// The Mac uses Apple's built-in sound classifier (`SoundClassifier` in the app). A port to
/// another system plugs its own engine in here (on Windows, Silero VAD for one), and
/// everything after it stays the same.
protocol SpeechClassifier: Sendable {
    /// How sure the classifier is that someone speaks, window by window, for mono sound.
    /// Throws `CancellationError` when the task is cancelled.
    func windows(samples: [Int16], sampleRate: Double) throws -> [SpeechWindow]
}

extension FileMatcher.Speech {
    /// From the loudness of each frame and, per frame, how sure a classifier is that
    /// someone speaks (`heard(_:frames:)`): speech must be heard, and loudness sharpens
    /// where it starts and ends.
    init(levels: [Float], heard: [Float]) { self.init(active: Self.detect(levels, heard: heard)) }

    /// Speech, worked out with a classifier: loudness alone when it fails.
    init(samples: [Int16], sampleRate: Double, classifier: SpeechClassifier?) throws {
        let levels = Self.levels(samples: samples, sampleRate: sampleRate)
        guard let classifier else { self.init(levels: levels); return }
        let windows: [SpeechWindow]
        do {
            windows = try classifier.windows(samples: samples, sampleRate: sampleRate)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.init(levels: levels)
            return
        }
        self.init(levels: levels, heard: Self.heard(windows, frames: levels.count))
    }

    /// Per tenth of a second, the most sure any window covering it is that someone speaks.
    static func heard(_ windows: [SpeechWindow], frames n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, n))
        for w in windows where w.end > w.start {
            // (A hair inwards, so 1.5 s / 0.1 doesn't come out as 15.000000001 and reach frame 15.)
            let lo = max(0, Int((w.start / frame + 1e-6).rounded(.down)))
            let hi = min(n, Int((w.end / frame - 1e-6).rounded(.up)))
            guard lo < hi else { continue }
            let c = Float(min(1, max(0, w.confidence)))
            for i in lo..<hi where out[i] < c { out[i] = c }
        }
        return out
    }
}

/// Answers "is someone speaking at this moment?" for moments asked in time order, walking
/// the stretches of speech once (the waveform asks pixel by pixel, left to right).
final class SpeechCursor {
    private let stretches: [ClosedRange<Double>]
    private var index = 0
    private var last = -Double.infinity

    init(_ stretches: [ClosedRange<Double>]) { self.stretches = stretches }

    func contains(_ t: Double) -> Bool {
        if t < last || last == -.infinity {
            // The first stretch that reaches t (they're in time order).
            var lo = 0, hi = stretches.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if stretches[mid].upperBound < t { lo = mid + 1 } else { hi = mid }
            }
            index = lo
        }
        last = t
        while index < stretches.count && stretches[index].upperBound < t { index += 1 }
        return index < stretches.count && stretches[index].lowerBound <= t
    }
}
