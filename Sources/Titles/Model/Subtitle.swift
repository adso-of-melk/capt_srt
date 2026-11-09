import Foundation

/// One subtitle ("title"). Times are in seconds from the start of the video.
struct Subtitle: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: UUID
    var start: Double
    var end: Double
    var text: String
    /// In a language other than the master: the master title this one translates.
    /// Linked titles share a row in the side-by-side card pane.
    var link: UUID?

    init(id: UUID = UUID(), start: Double, end: Double, text: String = "", link: UUID? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.link = link
    }

    var duration: Double { max(0, end - start) }

    /// Characters counted for reading speed: everything except line breaks and formatting tags.
    var characterCount: Int {
        Markup.plain(text).filter { $0 != "\n" && $0 != "\r" }.count
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

/// A subtitling standard: every timing and layout rule at once. Projects pick one
/// (General, Broadcast, Children's) and can override any value, which makes it Custom.
struct TimingPreset: Equatable, Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var maxCPS: Double
    var maxCharsPerLine: Int
    var maxLines: Int
    var minDuration: Double
    var maxDuration: Double
    /// Minimum gap between titles, in frames.
    var minGapFrames: Int

    /// Reading speed turns amber this close to the limit.
    var warnCPS: Double { maxCPS - 2 }

    static let general = TimingPreset(id: "general", name: "General", maxCPS: 17, maxCharsPerLine: 42,
                                      maxLines: 2, minDuration: 0.833, maxDuration: 7, minGapFrames: 2)
    static let broadcast = TimingPreset(id: "broadcast", name: "Broadcast", maxCPS: 15, maxCharsPerLine: 37,
                                        maxLines: 2, minDuration: 1.0, maxDuration: 7, minGapFrames: 2)
    static let children = TimingPreset(id: "children", name: "Children's", maxCPS: 13, maxCharsPerLine: 37,
                                       maxLines: 2, minDuration: 1.5, maxDuration: 7, minGapFrames: 2)
    static let all: [TimingPreset] = [.general, .broadcast, .children]

    var summary: String {
        "\(Int(maxCPS)) CPS · \(maxCharsPerLine) characters · \(maxLines) lines · "
            + String(format: "%.2g–%.2g s · %d-frame gap", minDuration, maxDuration, minGapFrames)
    }

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

    /// Too many lines, or a line longer than the limit.
    func lineStatus(_ s: Subtitle) -> TimingStatus {
        let lines = Markup.plain(s.text).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines { return .bad }
        if lines.contains(where: { $0.count > maxCharsPerLine }) { return .bad }
        return .ok
    }

    func longestLine(_ s: Subtitle) -> Int {
        Markup.plain(s.text).split(separator: "\n").map(\.count).max() ?? 0
    }

    func status(_ s: Subtitle) -> TimingStatus {
        [cpsStatus(s), durationStatus(s), lineStatus(s)].max { $0.rank < $1.rank } ?? .ok
    }
}
