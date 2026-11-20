import Foundation

/// The subtitle formats titles are written in. (Its file type for save panels is the app's:
/// see `ExportFormat.type` there.) The raw values are saved in projects: never rename one.
enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case srt, vtt, ttml, dfxp, itt, stl, ass, ssa, sbv, txt, list, avid

    var title: String {
        switch self {
        case .srt: return "SubRip (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        case .ttml: return "TTML / IMSC 1.1 (.ttml)"
        case .dfxp: return "DFXP (.dfxp)"
        case .itt: return "iTunes Timed Text (.itt)"
        case .stl: return "EBU STL (.stl)"
        case .ass: return "Advanced SubStation Alpha (.ass)"
        case .ssa: return "SubStation Alpha (.ssa)"
        case .sbv: return "YouTube (.sbv)"
        case .txt: return "Plain text (.txt)"
        case .list: return "Dialogue list with timecodes (.txt)"
        case .avid: return "Avid DS captions (.txt)"
        }
    }

    /// Who asks for it, in a few words (under the format menus).
    var note: String {
        switch self {
        case .srt: return "Plays almost everywhere."
        case .vtt: return "Web players and HTML5 video."
        case .ttml: return "Netflix, Amazon, broadcasters (IMSC 1.1 Text profile)."
        case .dfxp: return "The older TTML flavour some platforms still ask for. Times in ticks."
        case .itt: return "Apple TV and iTunes delivery. Times in frames."
        case .stl: return "European broadcast (teletext). Times in frames, from the project's start timecode."
        case .ass: return "Aegisub, VLC and mpv. Keeps italics, bold and titles at the top."
        case .ssa: return "Older players that read SubStation Alpha."
        case .sbv: return "YouTube uploads. No formatting."
        case .txt: return "The words only, one title after another: for translators and reviewers."
        case .list: return "Each title with its in and out timecodes (from the project's start timecode)."
        case .avid: return "Avid Media Composer's SubCap. Times in frames, from the project's start timecode."
        }
    }

    /// The file name's extension.
    var fileExtension: String {
        switch self {
        case .txt, .list, .avid: return "txt"
        default: return rawValue
        }
    }

    /// Written as bytes of its own (EBU STL), not as text.
    var isBinary: Bool { self == .stl }

    /// XML: always UTF-8, and no byte-order mark.
    var isXML: Bool { self == .ttml || self == .dfxp || self == .itt }

    /// Can be written in an older code page (Language Options). WebVTT and the XML formats
    /// are UTF-8 by definition; EBU STL has its own character tables.
    var allowsCodePage: Bool {
        switch self {
        case .vtt, .ttml, .dfxp, .itt, .stl: return false
        default: return true
        }
    }

    /// Its times count from the project's start timecode (10:00:00:00 for broadcast), the
    /// way broadcast and editing systems number a programme. The others count from the
    /// start of the video file.
    var usesStartTimecode: Bool { self == .stl || self == .list || self == .avid }
}

/// What a writer needs to know beyond the titles.
struct ExportContext: Sendable {
    /// Frames per second, for formats with frame timecodes.
    var fps: Double = 25
    /// The language's code (xml:lang, the EBU STL language code).
    var language = "en"
    /// The programme's name (in the file's header, where there is one).
    var title = ""
    /// Seconds added to every time in formats that count from the start timecode.
    var startTimecode: Double = 0
    /// The file's creation date (EBU STL's header).
    var date = Date()
}
