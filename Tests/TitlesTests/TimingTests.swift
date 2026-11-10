import XCTest
@testable import Titles

/// Reading speed, duration and line limits, and what colour they get.
@MainActor
final class TimingTests: XCTestCase {
    private let thirty = "123456789012345678901234567890"

    func testReadingSpeed() {
        XCTAssertEqual(sub(0, 2, thirty).cps, 15, accuracy: 0.0001)
        XCTAssertEqual(sub(0, 2, "<i>\(thirty)</i>").cps, 15, accuracy: 0.0001)
        XCTAssertEqual(sub(5, 5, thirty).cps, 0)
        XCTAssertEqual(sub(5, 4, thirty).duration, 0)
    }

    func testReadingSpeedColourFollowsTheNumberShown() {
        let rules = TimingPreset.broadcast          // 15 CPS, amber above 13
        // 15.04 CPS shows as "15.0", so it's judged as 15.0: at the limit, not over it.
        XCTAssertEqual(rules.cpsStatus(sub(0, 1.995, thirty)), .warn)
        XCTAssertEqual(rules.cpsStatus(sub(0, 2, thirty)), .warn)
        // 15.08 CPS shows as "15.1": over.
        XCTAssertEqual(rules.cpsStatus(sub(0, 1.99, thirty)), .bad)
        // 13.0 is not yet amber; 13.5 is.
        XCTAssertEqual(rules.cpsStatus(sub(0, 2, String(thirty.prefix(26)))), .ok)
        XCTAssertEqual(rules.cpsStatus(sub(0, 2, String(thirty.prefix(27)))), .warn)
        // Nothing to read is never too fast.
        XCTAssertEqual(rules.cpsStatus(sub(0, 0.2, "")), .ok)
        XCTAssertEqual(rules.cpsStatus(sub(0, 0.2, "<i></i>")), .ok)
    }

    func testDuration() {
        let rules = TimingPreset.general            // 0.833 to 7 seconds
        XCTAssertEqual(rules.durationStatus(sub(0, 0.5)), .bad)
        XCTAssertEqual(rules.durationStatus(sub(0, 0.7)), .warn)
        XCTAssertEqual(rules.durationStatus(sub(0, 1)), .ok)
        XCTAssertEqual(rules.durationStatus(sub(0, 7)), .ok)
        XCTAssertEqual(rules.durationStatus(sub(0, 7.5)), .warn)
        XCTAssertEqual(rules.durationStatus(sub(0, 8.1)), .bad)
    }

    func testLines() {
        let rules = TimingPreset.general            // 42 characters, 2 lines
        let fortyTwo = String(repeating: "a", count: 42)
        XCTAssertEqual(rules.lineStatus(sub(0, 2, fortyTwo)), .ok)
        XCTAssertEqual(rules.lineStatus(sub(0, 2, fortyTwo + "a")), .bad)
        XCTAssertEqual(rules.lineStatus(sub(0, 2, "<i>\(fortyTwo)</i>")), .ok)
        XCTAssertEqual(rules.lineStatus(sub(0, 2, "One\nTwo")), .ok)
        XCTAssertEqual(rules.lineStatus(sub(0, 2, "One\nTwo\nThree")), .bad)
        XCTAssertEqual(rules.longestLine(sub(0, 2, "Short\nA longer line")), 13)
        XCTAssertEqual(rules.longestLine(sub(0, 2, "")), 0)
    }

    func testTheWorstProblemDecidesTheColour() {
        let rules = TimingPreset.general
        XCTAssertEqual(rules.status(sub(0, 2, "Fine")), .ok)
        XCTAssertEqual(rules.status(sub(0, 0.7, "Hi")), .warn)
        XCTAssertEqual(rules.status(sub(0, 2, "One\nTwo\nThree")), .bad)
        XCTAssertEqual(rules.status(sub(0, 0.7, String(repeating: "a", count: 40))), .bad)
    }

    func testStandards() {
        XCTAssertEqual(TimingPreset.all.map(\.id), ["general", "broadcast", "children"])
        XCTAssertEqual(TimingPreset.general.warnCPS, 15)
        XCTAssertEqual(TimingPreset.general.summary, "17 CPS · 42 characters · 2 lines · 0.83–7 s · 2-frame gap")
    }

    func testALanguageCanHaveItsOwnLimits() {
        let track = Track(language: Language.named("hr"))
        XCTAssertEqual(track.standard(from: .general), .general)
        track.maxCPS = 20
        track.maxCharsPerLine = 37
        let own = track.standard(from: .general)
        XCTAssertEqual(own.maxCPS, 20)
        XCTAssertEqual(own.maxCharsPerLine, 37)
        XCTAssertEqual(own.maxLines, 2)
        XCTAssertEqual(own.minDuration, TimingPreset.general.minDuration)
    }

    func testJogSteps() {
        let frame = 1.0 / 25
        XCTAssertEqual(JogStep.frame.seconds(frame: frame), 0.04, accuracy: 0.000001)
        XCTAssertEqual(JogStep.ms10.seconds(frame: frame), 0.010, accuracy: 0.000001)
        XCTAssertEqual(JogStep.ms5.seconds(frame: frame), 0.005, accuracy: 0.000001)
        XCTAssertEqual(JogStep.ms1.seconds(frame: frame), 0.001, accuracy: 0.000001)
        XCTAssertEqual(JogStep.allCases.count, 4)
    }

    func testFirstLine() {
        XCTAssertEqual(sub(0, 1, "One\nTwo").firstLine, "One")
        XCTAssertEqual(sub(0, 1, "\nTwo").firstLine, "Two")
        XCTAssertEqual(sub(0, 1, "").firstLine, "")
    }
}
