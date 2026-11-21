import XCTest
@testable import TitlesCore

/// Where people speak, worked out from the decoded sound for the waveform's shading.
final class SpeechShadingTests: XCTestCase {

    /// Quiet noise, with loud "speech" (a tone) from 5 to 6 s and from 12 to 13.5 s.
    private func sound(rate: Double = 16_000) -> [Int16] {
        var seed: UInt32 = 12345
        return (0..<Int(20 * rate)).map { i in
            seed = seed &* 1_103_515_245 &+ 12345
            let noise = Double(Int(seed >> 16) % 101 - 50)
            let t = Double(i) / rate
            let speaking = (5..<6).contains(t) || (12..<13.5).contains(t)
            return Int16(speaking ? noise + 8000 * sin(2 * .pi * 1000 * t) : noise)
        }
    }

    func testLevelsAreOneATenthOfASecond() {
        let levels = FileMatcher.Speech.levels(samples: sound(), sampleRate: 16_000)
        XCTAssertEqual(levels.count, 200)
        XCTAssertGreaterThan(levels[55], levels[30] + 30)
    }

    func testStretchesOfSpeech() {
        let levels = FileMatcher.Speech.levels(samples: sound(), sampleRate: 16_000)
        let stretches = FileMatcher.Speech(levels: levels).stretches
        XCTAssertEqual(stretches.count, 2, "\(stretches)")
        XCTAssertEqual(stretches[0].lowerBound, 5, accuracy: 0.11)
        XCTAssertEqual(stretches[0].upperBound, 6, accuracy: 0.11)
        XCTAssertEqual(stretches[1].lowerBound, 12, accuracy: 0.11)
        XCTAssertEqual(stretches[1].upperBound, 13.5, accuracy: 0.11)
    }

    func testSpeechRunningToTheEnd() {
        let speech = FileMatcher.Speech(active: [false, true, true, false, true, true, true])
        XCTAssertEqual(speech.stretches.count, 2)
        XCTAssertEqual(speech.stretches[1].upperBound, 0.7, accuracy: 0.0001)
    }
}
