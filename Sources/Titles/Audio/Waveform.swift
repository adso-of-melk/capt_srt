import Foundation
import AVFoundation

/// Decoded mono audio (16 kHz, 16-bit) plus a pyramid of loudness summaries,
/// so the waveform draws instantly at any zoom level.
final class Waveform: @unchecked Sendable {
    struct Bucket {
        var peak: Float   // 0…1, highest absolute sample
        var meanSquare: Float  // for RMS
    }

    let samples: [Int16]
    let sampleRate: Double
    let baseSize = 32           // samples per bucket at level 0 (2 ms)
    let factor = 4              // each level is 4× coarser
    private(set) var levels: [[Bucket]] = []

    var duration: Double { Double(samples.count) / sampleRate }

    init(samples: [Int16], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        buildLevels()
    }

    private func buildLevels() {
        var base: [Bucket] = []
        base.reserveCapacity(samples.count / baseSize + 1)
        samples.withUnsafeBufferPointer { buf in
            var i = 0
            while i < buf.count {
                let end = min(i + baseSize, buf.count)
                var peak: Int32 = 0
                var sum: Float = 0
                for j in i..<end {
                    let v = Int32(buf[j])
                    let a = v < 0 ? -v : v
                    if a > peak { peak = a }
                    let f = Float(v) / 32768
                    sum += f * f
                }
                base.append(Bucket(peak: Float(peak) / 32768, meanSquare: sum / Float(end - i)))
                i = end
            }
        }
        levels = [base]
        var current = base
        while current.count > 256 {
            var next: [Bucket] = []
            next.reserveCapacity(current.count / factor + 1)
            var i = 0
            while i < current.count {
                let end = min(i + factor, current.count)
                var peak: Float = 0
                var ms: Float = 0
                for j in i..<end {
                    peak = max(peak, current[j].peak)
                    ms += current[j].meanSquare
                }
                next.append(Bucket(peak: peak, meanSquare: ms / Float(end - i)))
                i = end
            }
            levels.append(next)
            current = next
        }
    }

    /// One (peak, rms) pair per pixel column, starting at `t0`.
    func envelope(from t0: Double, secondsPerPixel: Double, pixels: Int) -> [(peak: Float, rms: Float)] {
        guard pixels > 0, !samples.isEmpty else { return [] }
        let samplesPerPixel = secondsPerPixel * sampleRate
        var out = [(peak: Float, rms: Float)](repeating: (0, 0), count: pixels)

        // Choose the coarsest level whose buckets are still smaller than a pixel.
        var level = -1
        var size = baseSize
        if samplesPerPixel >= Double(baseSize) {
            level = 0
            while level + 1 < levels.count && Double(size * factor) <= samplesPerPixel {
                level += 1
                size *= factor
            }
        }

        for px in 0..<pixels {
            let s0 = Int((t0 + Double(px) * secondsPerPixel) * sampleRate)
            let s1 = Int((t0 + Double(px + 1) * secondsPerPixel) * sampleRate)
            if s1 <= 0 || s0 >= samples.count { continue }
            let a = max(0, s0), b = min(samples.count, max(s1, a + 1))
            if level < 0 {
                var peak: Float = 0, sum: Float = 0
                for j in a..<b {
                    let f = Float(samples[j]) / 32768
                    peak = max(peak, abs(f))
                    sum += f * f
                }
                out[px] = (peak, sqrt(sum / Float(b - a)))
            } else {
                let buckets = levels[level]
                let b0 = a / size
                let b1 = min(buckets.count, max(b0 + 1, b / size))
                var peak: Float = 0, ms: Float = 0
                for j in b0..<b1 {
                    peak = max(peak, buckets[j].peak)
                    ms += buckets[j].meanSquare
                }
                out[px] = (peak, sqrt(ms / Float(b1 - b0)))
            }
        }
        return out
    }
}

enum AudioDecoder {
    static let sampleRate: Double = 16_000

    enum DecodeError: LocalizedError {
        case noAudio, readFailed
        var errorDescription: String? {
            switch self {
            case .noAudio: return "This file has no audio track."
            case .readFailed: return "The audio could not be read."
            }
        }
    }

    /// Decodes the first audio track to mono 16 kHz. Runs off the main thread.
    static func decode(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Waveform {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw DecodeError.noAudio }

        let reader = try AVAssetReader(asset: asset)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: layoutData,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.readFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? DecodeError.readFailed }

        var samples: [Int16] = []
        if duration.isFinite && duration > 0 {
            samples.reserveCapacity(Int(duration * sampleRate) + 4096)
        }
        var lastReport = 0.0

        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / 2
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2,
                                                   destination: base.advanced(by: start * 2))
                }
            }
            if duration > 0 {
                let p = Double(samples.count) / (duration * sampleRate)
                if p - lastReport > 0.02 {
                    lastReport = p
                    progress(min(p, 1))
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? DecodeError.readFailed }
        progress(1)
        return Waveform(samples: samples, sampleRate: sampleRate)
    }
}
