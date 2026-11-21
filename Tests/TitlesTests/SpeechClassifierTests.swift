import XCTest
import AVFoundation
@testable import Titles
@testable import TitlesCore

/// Telling speech from other sound: the classifier says what is speech, loudness where it
/// starts and ends.
final class SpeechClassifierTests: XCTestCase {

    /// Loudness, a tenth of a second at a time: quiet (-60 dB) for the first 3 s, then
    /// `music` dB, with `bursts` (frame ranges) at their own level.
    private func levels(count: Int = 300, music: Float = -60, bursts: [(Range<Int>, Float)]) -> [Float] {
        var out = (0..<count).map { $0 < 30 ? Float(-60) : music }
        for (range, level) in bursts { for i in range { out[i] = level } }
        return out
    }

    private func heard(_ count: Int, _ sure: [(Range<Int>, Float)]) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for (range, c) in sure { for i in range { out[i] = c } }
        return out
    }

    func testLoudSoundTheClassifierDoesntHearAsSpeechIsLeftOut() {
        // A door slam at 5 s and someone speaking at 12 s, equally loud.
        let lv = levels(bursts: [(50..<60, -20), (120..<135, -20)])
        XCTAssertEqual(FileMatcher.Speech(levels: lv).stretches.count, 2, "loudness alone takes both")
        let sure = heard(lv.count, [(50..<60, 0.02), (118..<138, 0.9)])
        let stretches = FileMatcher.Speech(levels: lv, heard: sure).stretches
        XCTAssertEqual(stretches.count, 1, "\(stretches)")
        XCTAssertEqual(stretches[0].lowerBound, 12, accuracy: 0.11)
        XCTAssertEqual(stretches[0].upperBound, 13.5, accuracy: 0.11, "loudness sets the edges")
    }

    func testSpeechOverMusicCountsWhenTheClassifierIsSure() {
        // Music at -24 dB all along; speech over it only 3 dB louder.
        let lv = levels(music: -24, bursts: [(150..<170, -21)])
        XCTAssertFalse(FileMatcher.Speech(levels: lv).stretches.contains { $0.contains(16) },
                       "too little above the music for loudness alone")
        let sure = heard(lv.count, [(150..<170, 0.85)])
        let stretches = FileMatcher.Speech(levels: lv, heard: sure).stretches
        XCTAssertEqual(stretches.count, 1, "\(stretches)")
        XCTAssertEqual(stretches[0].lowerBound, 15, accuracy: 0.11)
        XCTAssertEqual(stretches[0].upperBound, 17, accuracy: 0.11)
    }

    func testMusicAloneIsntSpeech() {
        // Loud music bursts the classifier hears as music, not speech.
        let lv = levels(music: -50, bursts: [(60..<90, -15), (200..<240, -12)])
        let sure = heard(lv.count, [(60..<90, 0.1), (200..<240, 0.15)])
        XCTAssertTrue(FileMatcher.Speech(levels: lv, heard: sure).stretches.isEmpty)
    }

    func testEachFrameTakesTheSurestWindowOverIt() {
        let windows = [SpeechWindow(start: 0, end: 1, confidence: 0.2),
                       SpeechWindow(start: 0.5, end: 1.5, confidence: 0.9),
                       SpeechWindow(start: 1, end: 2, confidence: 0.4)]
        let h = FileMatcher.Speech.heard(windows, frames: 25)
        XCTAssertEqual(h.count, 25)
        XCTAssertEqual(h[2], 0.2, accuracy: 0.001)
        XCTAssertEqual(h[7], 0.9, accuracy: 0.001)
        XCTAssertEqual(h[14], 0.9, accuracy: 0.001)
        XCTAssertEqual(h[15], 0.4, accuracy: 0.001, "a window ends where its last frame does")
        XCTAssertEqual(h[17], 0.4, accuracy: 0.001)
        XCTAssertEqual(h[22], 0, accuracy: 0.001)
    }

    private struct Failing: SpeechClassifier {
        struct Broken: Error {}
        func windows(samples: [Int16], sampleRate: Double) throws -> [SpeechWindow] { throw Broken() }
    }

    private struct Fixed: SpeechClassifier {
        var heard: [SpeechWindow]
        func windows(samples: [Int16], sampleRate: Double) throws -> [SpeechWindow] { heard }
    }

    /// Quiet noise with two loud tones, 5 to 6 s and 12 to 13.5 s.
    private func sound(rate: Double = 16_000) -> [Int16] {
        var seed: UInt32 = 12345
        return (0..<Int(20 * rate)).map { i in
            seed = seed &* 1_103_515_245 &+ 12345
            let noise = Double(Int(seed >> 16) % 101 - 50)
            let t = Double(i) / rate
            let loud = (5..<6).contains(t) || (12..<13.5).contains(t)
            return Int16(loud ? noise + 8000 * sin(2 * .pi * 1000 * t) : noise)
        }
    }

    func testWhenTheClassifierFailsLoudnessAloneIsUsed() throws {
        let s = sound()
        let speech = try FileMatcher.Speech(samples: s, sampleRate: 16_000, classifier: Failing())
        XCTAssertEqual(speech.stretches.count, 2)
    }

    func testAnotherEngineCanBePluggedIn() throws {
        // As a Windows port would: its own engine says only the second tone is speech.
        let engine = Fixed(heard: [SpeechWindow(start: 4.5, end: 6.5, confidence: 0.05),
                                     SpeechWindow(start: 11.5, end: 14, confidence: 0.95)])
        let speech = try FileMatcher.Speech(samples: sound(), sampleRate: 16_000, classifier: engine)
        XCTAssertEqual(speech.stretches.count, 1)
        XCTAssertEqual(speech.stretches[0].lowerBound, 12, accuracy: 0.11)
    }

    func testTheCursorAnswersMomentByMomentAndCanGoBack() {
        let cursor = SpeechCursor([1...2, 4...5, 8...9])
        XCTAssertFalse(cursor.contains(0.5))
        XCTAssertTrue(cursor.contains(1.5))
        XCTAssertFalse(cursor.contains(3))
        XCTAssertTrue(cursor.contains(4))
        XCTAssertTrue(cursor.contains(8.5))
        XCTAssertFalse(cursor.contains(9.5))
        XCTAssertTrue(cursor.contains(1.2), "back in time")
        XCTAssertFalse(SpeechCursor([]).contains(1))
    }

    // MARK: Apple's sound classifier, on the Mac

    func testAToneAndSilenceArentSpeech() throws {
        let rate = 16_000.0
        let samples = (0..<Int(6 * rate)).map { i -> Int16 in
            let t = Double(i) / rate
            return t < 3 ? Int16(8000 * sin(2 * .pi * 440 * t)) : 0
        }
        let windows = try SoundClassifier().windows(samples: samples, sampleRate: rate)
        XCTAssertFalse(windows.isEmpty, "the classifier gave nothing back")
        XCTAssertLessThan(windows.map(\.confidence).max() ?? 1, 0.5, "\(windows)")
    }

    func testSpokenWordsAreSpeech() throws {
        // macOS's own voice, saved as a sound file in a temporary folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("spoken.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "--data-format=LEI16@16000",
                         "Captain, the shields are holding, but we cannot take another hit like that. Shall I hail them?"]
        do { try say.run() } catch { throw XCTSkip("No voice to speak with here") }
        say.waitUntilExit()
        guard say.terminationStatus == 0, FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("No voice to speak with here")
        }
        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(audio.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames))
        try audio.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = (0..<Int(buffer.frameLength)).map { Int16(max(-1, min(1, data[$0])) * 32767) }
        XCTAssertGreaterThan(samples.count, 16_000)

        let windows = try SoundClassifier().windows(samples: samples, sampleRate: audio.processingFormat.sampleRate)
        XCTAssertGreaterThan(windows.map(\.confidence).max() ?? 0, 0.5, "\(windows)")
    }
}
