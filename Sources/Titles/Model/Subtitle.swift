import Foundation

/// One subtitle ("title"). Times are in seconds from the start of the video.
struct Subtitle: Identifiable, Equatable, Hashable {
    let id: UUID
    var start: Double
    var end: Double
    var text: String

    init(id: UUID = UUID(), start: Double, end: Double, text: String = "") {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }

    var duration: Double { max(0, end - start) }

    /// Characters counted for reading speed: everything except line breaks.
    var characterCount: Int {
        text.filter { $0 != "\n" && $0 != "\r" }.count
    }

    /// Characters per second.
    var cps: Double {
        guard duration > 0.001 else { return 0 }
        return Double(characterCount) / duration
    }

    var firstLine: String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }
}

enum Edge {
    case start, end
}

enum TimingStatus {
    case ok, warn, bad

    var rank: Int {
        switch self {
        case .ok: return 0
        case .warn: return 1
        case .bad: return 2
        }
    }
}

/// One preset sets every timing rule at once, instead of a page of settings.
struct TimingPreset: Equatable, Identifiable {
    let id: String
    let name: String
    let warnCPS: Double
    let maxCPS: Double
    let minDuration: Double
    let maxDuration: Double
    /// Minimum gap between titles, in frames.
    let minGapFrames: Int

    static let general = TimingPreset(id: "general", name: "General (17 CPS)",
                                      warnCPS: 15, maxCPS: 17, minDuration: 0.833,
                                      maxDuration: 7, minGapFrames: 2)
    static let streaming = TimingPreset(id: "streaming", name: "Streaming (20 CPS)",
                                        warnCPS: 17, maxCPS: 20, minDuration: 0.833,
                                        maxDuration: 7, minGapFrames: 2)
    static let children = TimingPreset(id: "children", name: "Children (13 CPS)",
                                       warnCPS: 11, maxCPS: 13, minDuration: 1.5,
                                       maxDuration: 7, minGapFrames: 2)
    static let all: [TimingPreset] = [.general, .streaming, .children]

    func cpsStatus(_ s: Subtitle) -> TimingStatus {
        if s.characterCount == 0 { return .ok }
        if s.cps > maxCPS { return .bad }
        if s.cps > warnCPS { return .warn }
        return .ok
    }

    func durationStatus(_ s: Subtitle) -> TimingStatus {
        if s.duration < minDuration * 0.75 || s.duration > maxDuration * 1.15 { return .bad }
        if s.duration < minDuration || s.duration > maxDuration { return .warn }
        return .ok
    }

    func status(_ s: Subtitle) -> TimingStatus {
        let a = cpsStatus(s), b = durationStatus(s)
        return a.rank >= b.rank ? a : b
    }
}
