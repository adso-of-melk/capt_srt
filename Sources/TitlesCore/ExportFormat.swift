import Foundation

/// The subtitle formats titles are written in. (Its file type for save panels is the app's:
/// see `ExportFormat.type` there.)
enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case srt, vtt
    var title: String { self == .srt ? "SubRip (.srt)" : "WebVTT (.vtt)" }
}
