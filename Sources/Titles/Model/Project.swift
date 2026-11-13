import Foundation
import Combine

// MARK: - Languages

struct Language: Hashable, Identifiable, Codable, Sendable {
    /// BCP-47 code, used in exported file names (Film.hr.srt).
    var code: String
    var name: String
    var id: String { code }

    /// Written right to left (Arabic, Hebrew, Persian, Urdu…).
    var isRightToLeft: Bool {
        let base = code.split(separator: "-").first.map { $0.lowercased() } ?? code.lowercased()
        return ["ar", "he", "iw", "fa", "ur", "yi", "ps", "ckb", "dv", "sd", "ug"].contains(base)
    }

    static let common: [Language] = [
        ("en", "English"), ("en-GB", "English (UK)"), ("hr", "Croatian"), ("sr-Latn", "Serbian (Latin)"),
        ("sr-Cyrl", "Serbian (Cyrillic)"), ("bs", "Bosnian"), ("sl", "Slovenian"), ("mk", "Macedonian"),
        ("sq", "Albanian"), ("de", "German"), ("fr", "French"), ("it", "Italian"), ("es", "Spanish"),
        ("es-419", "Spanish (Latin America)"), ("pt-PT", "Portuguese (Portugal)"), ("pt-BR", "Portuguese (Brazil)"),
        ("ca", "Catalan"), ("eu", "Basque"), ("gl", "Galician"), ("nl", "Dutch"), ("sv", "Swedish"),
        ("da", "Danish"), ("nb", "Norwegian"), ("fi", "Finnish"), ("is", "Icelandic"), ("et", "Estonian"),
        ("lv", "Latvian"), ("lt", "Lithuanian"), ("pl", "Polish"), ("cs", "Czech"), ("sk", "Slovak"),
        ("hu", "Hungarian"), ("ro", "Romanian"), ("bg", "Bulgarian"), ("el", "Greek"), ("tr", "Turkish"),
        ("ru", "Russian"), ("uk", "Ukrainian"), ("ka", "Georgian"), ("hy", "Armenian"), ("ar", "Arabic"),
        ("he", "Hebrew"), ("fa", "Persian"), ("hi", "Hindi"), ("bn", "Bengali"), ("ur", "Urdu"),
        ("th", "Thai"), ("vi", "Vietnamese"), ("id", "Indonesian"), ("ms", "Malay"), ("fil", "Filipino"),
        ("ja", "Japanese"), ("ko", "Korean"), ("zh-Hans", "Chinese (Simplified)"), ("zh-Hant", "Chinese (Traditional)"),
        ("sw", "Swahili"), ("af", "Afrikaans")
    ].map { Language(code: $0.0, name: $0.1) }

    static func named(_ code: String) -> Language {
        common.first { $0.code.lowercased() == code.lowercased() } ?? Language(code: code, name: code)
    }
}

// MARK: - Project settings

enum TimecodeDisplay: String, Codable, CaseIterable, Sendable {
    case frames, milliseconds
    var title: String { self == .frames ? "Frames (00:00:00:00)" : "Milliseconds (00:00:00,000)" }
}

struct ProjectSettings: Codable, Equatable, Sendable {
    var standard: TimingPreset = .general
    /// nil = use the video's own frame rate.
    var frameRate: Double?
    /// Shown added to every time (e.g. 10:00:00:00 for broadcast). Exports are unaffected.
    var startTimecode: Double = 0
    var timecodeDisplay: TimecodeDisplay = .frames
    var exportFormat: ExportFormat = .srt
    var utf8BOM = false
    var crlf = true
    /// {video} and {lang} are replaced: "Film.hr".
    var namingPattern = "{video}.{lang}"
    var masterLanguage = Language.named("en")
    /// The film's own words (names, places) that spell check accepts, per language code.
    var spellingWords: [String: [String]] = [:]

    enum CodingKeys: String, CodingKey {
        case standard, frameRate, startTimecode, timecodeDisplay, exportFormat, utf8BOM, crlf,
             namingPattern, masterLanguage, spellingWords
    }
}

extension ProjectSettings {
    /// Reads what the project file has and fills in the rest with the defaults, so a project
    /// saved by an older or a newer build always opens.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        standard = c.value(.standard, or: standard)
        frameRate = try? c.decodeIfPresent(Double.self, forKey: .frameRate)
        startTimecode = c.value(.startTimecode, or: startTimecode)
        timecodeDisplay = c.value(.timecodeDisplay, or: timecodeDisplay)
        exportFormat = c.value(.exportFormat, or: exportFormat)
        utf8BOM = c.value(.utf8BOM, or: utf8BOM)
        crlf = c.value(.crlf, or: crlf)
        namingPattern = c.value(.namingPattern, or: namingPattern)
        masterLanguage = c.value(.masterLanguage, or: masterLanguage)
        spellingWords = c.value(.spellingWords, or: spellingWords)
    }
}

// MARK: - File format (JSON, one file per project: Name.kptnsub)

struct TrackFile: Codable, Sendable {
    var id: UUID
    var language: Language
    var locked: Bool
    var maxCPS: Double?
    var maxCharsPerLine: Int?
    var maxLines: Int?
    /// true: spell check is off for this language (absent in older projects: on).
    var spellCheckOff: Bool?
    /// An older code page for this language's exported files (nil: UTF-8).
    var exportEncoding: String?
    /// Right-to-left marks on each line when exporting.
    var directionMarks: Bool?
    var subtitles: [Subtitle]
}

struct VideoFile: Codable, Sendable {
    var id: UUID
    var name: String
    var url: String?
    var masterTrackID: UUID
    var tracks: [TrackFile]
    var openTrackIDs: [UUID]
    var focusedTrackID: UUID?
}

struct ProjectFile: Codable, Sendable {
    var format = 1
    var id: UUID
    var name: String
    var modified: Date
    var settings: ProjectSettings
    var videos: [VideoFile]
    var currentVideoID: UUID?
}

// MARK: - Runtime model

/// One language version of one video's titles.
@MainActor
final class Track: ObservableObject, Identifiable {
    let id: UUID
    @Published var language: Language
    @Published var locked: Bool
    @Published var maxCPS: Double?
    @Published var maxCharsPerLine: Int?
    @Published var maxLines: Int?
    /// Spell check for this language (Language Options). The app-wide switch is in the Edit menu.
    @Published var spellCheck = true
    /// An older code page for exports (nil: UTF-8, with the project's BOM setting).
    @Published var exportEncoding: String?
    /// Add right-to-left marks to each line on export (right-to-left languages only).
    @Published var directionMarks = false
    let doc = SubtitleDocument()

    init(id: UUID = UUID(), language: Language, locked: Bool = false, subtitles: [Subtitle] = []) {
        self.id = id
        self.language = language
        self.locked = locked
        doc.replaceAll(subtitles)
        doc.selectedID = nil
    }

    convenience init(_ f: TrackFile) {
        self.init(id: f.id, language: f.language, locked: f.locked, subtitles: f.subtitles)
        maxCPS = f.maxCPS
        maxCharsPerLine = f.maxCharsPerLine
        maxLines = f.maxLines
        spellCheck = f.spellCheckOff != true
        exportEncoding = f.exportEncoding
        directionMarks = f.directionMarks ?? false
    }

    var file: TrackFile {
        TrackFile(id: id, language: language, locked: locked, maxCPS: maxCPS,
                  maxCharsPerLine: maxCharsPerLine, maxLines: maxLines,
                  spellCheckOff: spellCheck ? nil : true, exportEncoding: exportEncoding,
                  directionMarks: directionMarks ? true : nil, subtitles: doc.subtitles)
    }

    /// The project standard with this language's own overrides.
    func standard(from base: TimingPreset) -> TimingPreset {
        var p = base
        if let c = maxCPS { p.maxCPS = c }
        if let l = maxCharsPerLine { p.maxCharsPerLine = l }
        if let n = maxLines { p.maxLines = n }
        return p
    }
}

@MainActor
final class VideoItem: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var url: URL?
    @Published var masterTrackID: UUID
    @Published var tracks: [Track]
    /// Languages shown as columns (and waveform lanes), in order.
    @Published var openTrackIDs: [UUID]
    @Published var focusedTrackID: UUID?

    init(id: UUID = UUID(), name: String, url: URL?, master: Track) {
        self.id = id
        self.name = name
        self.url = url
        self.masterTrackID = master.id
        self.tracks = [master]
        self.openTrackIDs = [master.id]
        self.focusedTrackID = master.id
    }

    init(_ f: VideoFile) {
        // A damaged file may name a master, open columns or a focused language that isn't
        // there: fall back to languages that are, so the editor always has a column to show.
        let known = Set(f.tracks.map(\.id))
        let master = known.contains(f.masterTrackID) ? f.masterTrackID : (f.tracks.first?.id ?? f.masterTrackID)
        var open: [UUID] = []
        for trackID in f.openTrackIDs where known.contains(trackID) && !open.contains(trackID) { open.append(trackID) }
        if open.isEmpty { open = [master] }
        id = f.id
        name = f.name
        url = f.url.flatMap(URL.init(string:))
        tracks = f.tracks.map(Track.init)
        masterTrackID = master
        openTrackIDs = open
        focusedTrackID = f.focusedTrackID.flatMap { open.contains($0) ? $0 : nil } ?? open.first
    }

    var file: VideoFile {
        VideoFile(id: id, name: name, url: url?.absoluteString, masterTrackID: masterTrackID,
                  tracks: tracks.map(\.file), openTrackIDs: openTrackIDs, focusedTrackID: focusedTrackID)
    }

    func track(_ id: UUID?) -> Track? { tracks.first { $0.id == id } }
    var master: Track? { track(masterTrackID) }
    var openTracks: [Track] { openTrackIDs.compactMap(track) }
}

@MainActor
final class Project: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var settings: ProjectSettings
    @Published var videos: [VideoItem]
    /// Where the person keeps the project (may be in iCloud). A local copy is always kept too.
    var fileURL: URL?

    init(id: UUID = UUID(), name: String, settings: ProjectSettings, videos: [VideoItem], fileURL: URL?) {
        self.id = id
        self.name = name
        self.settings = settings
        self.videos = videos
        self.fileURL = fileURL
    }

    convenience init(_ f: ProjectFile, fileURL: URL?) {
        self.init(id: f.id, name: f.name, settings: f.settings, videos: f.videos.map(VideoItem.init), fileURL: fileURL)
    }

    func file(currentVideoID: UUID?) -> ProjectFile {
        ProjectFile(id: id, name: name, modified: Date(), settings: settings,
                    videos: videos.map(\.file), currentVideoID: currentVideoID)
    }

    func video(_ id: UUID?) -> VideoItem? { videos.first { $0.id == id } }
}

// MARK: - Rows across languages

/// One row of the side-by-side card pane: titles from different languages that sit at the
/// same time on screen. Rows are built from timing alone, so moving a title in one language
/// never reorders another, and each column always reads in time order.
struct CardRow: Identifiable, Equatable {
    /// The row's first title (its anchor).
    let key: UUID
    var time: Double
    var cells: [UUID: Subtitle]   // track id → title
    var id: UUID { key }
}

enum RowBuilder {
    @MainActor
    static func rows(for video: VideoItem, tracks: [Track]) -> [CardRow] {
        var items: [(track: UUID, sub: Subtitle)] = []
        for t in tracks { for s in t.doc.subtitles { items.append((t.id, s)) } }
        items.sort {
            $0.sub.start != $1.sub.start ? $0.sub.start < $1.sub.start : $0.sub.id.uuidString < $1.sub.id.uuidString
        }
        var rows: [CardRow] = []
        var anchor: Subtitle?
        for item in items {
            if let a = anchor, var row = rows.last, row.cells[item.track] == nil, sameRow(a, item.sub) {
                row.cells[item.track] = item.sub
                rows[rows.count - 1] = row
            } else {
                rows.append(CardRow(key: item.sub.id, time: item.sub.start, cells: [item.track: item.sub]))
                anchor = item.sub
            }
        }
        return rows
    }

    /// Two titles share a row when they start within a quarter second of each other, or
    /// overlap for at least half of the shorter one.
    static func sameRow(_ a: Subtitle, _ b: Subtitle) -> Bool {
        if abs(a.start - b.start) <= 0.25 { return true }
        let overlap = min(a.end, b.end) - max(a.start, b.start)
        return overlap > 0 && overlap / max(0.001, min(a.duration, b.duration)) >= 0.5
    }

    /// Links titles of an imported or newly created language to the master by overlapping time.
    /// Each master title is used at most once; titles that overlap nothing stay unlinked.
    static func linkByOverlap(_ subs: [Subtitle], master: [Subtitle], skip: Set<UUID> = []) -> [Subtitle] {
        var used = skip
        var out: [Subtitle] = []
        var j = 0
        for var s in subs.sorted(by: { $0.start < $1.start }) {
            while j < master.count && master[j].end <= s.start { j += 1 }
            var best: (id: UUID, overlap: Double)?
            var k = max(0, j - 1)
            while k < master.count && master[k].start < s.end {
                let m = master[k]
                let overlap = min(m.end, s.end) - max(m.start, s.start)
                let shorter = max(0.001, min(m.duration, s.duration))
                if overlap / shorter >= 0.3, !used.contains(m.id), overlap > (best?.overlap ?? 0) {
                    best = (m.id, overlap)
                }
                k += 1
            }
            if let best {
                s.link = best.id
                used.insert(best.id)
            }
            out.append(s)
        }
        return out
    }
}
