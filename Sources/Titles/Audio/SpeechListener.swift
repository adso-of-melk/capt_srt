import Foundation
import AVFoundation
@testable import TitlesCore

/// Listens to a video's sound for matching subtitle files by speech: how loud the speech band
/// is in each tenth of a second. Low-pitched sound (rumble, music's bass) counts for less.
/// Reads the sound once at 8 kHz without keeping it.
enum SpeechListener {
    static let sampleRate: Double = 8_000

    /// When people speak in the video at `url` (nil: it has no sound that can be read).
    static func speech(url: URL) async -> FileMatcher.Speech? {
        guard let levels = try? await levels(url: url), levels.count > 50 else { return nil }
        return FileMatcher.Speech(levels: levels)
    }

    /// The loudness of each tenth of a second, in decibels.
    static func levels(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AudioDecoder.DecodeError.noAudio }
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
        guard reader.canAdd(output) else { throw AudioDecoder.DecodeError.readFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioDecoder.DecodeError.readFailed }

        let perFrame = Int(sampleRate * FileMatcher.Speech.frame)
        var levels: [Float] = []
        var sum: Float = 0, count = 0, previous: Float = 0
        var chunk: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let n = CMBlockBufferGetDataLength(block) / 2
            guard n > 0 else { continue }
            if chunk.count < n { chunk = [Int16](repeating: 0, count: n) }
            chunk.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 2, destination: base) }
            }
            for i in 0..<n {
                let x = Float(chunk[i]) / 32768
                // Pre-emphasis: the speech band over the low end.
                let y = x - 0.95 * previous
                previous = x
                sum += y * y
                count += 1
                if count == perFrame {
                    levels.append(10 * log10(sum / Float(perFrame) + 1e-12))
                    sum = 0
                    count = 0
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? AudioDecoder.DecodeError.readFailed }
        return levels
    }
}
