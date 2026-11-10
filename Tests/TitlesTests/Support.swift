import XCTest
import AppKit
@testable import Titles

/// A title for a test.
func sub(_ start: Double, _ end: Double, _ text: String = "Text") -> Subtitle {
    Subtitle(start: start, end: end, text: text)
}

/// A player that only remembers what it was asked to do, so the model can be tested
/// without a video.
@MainActor
final class FakeEngine: PlaybackEngine {
    var duration: Double = 600
    var frameRate: Double = 25
    var currentTime: Double = 0
    var isPlaying = false
    var hasVideo = true
    var onTimeChange: ((Double) -> Void)?
    var onPlayStateChange: ((Bool) -> Void)?
    /// Every "play from … to …" that was asked for.
    var ranges: [(from: Double, to: Double)] = []

    func load(url: URL) async throws {}
    func unload() {
        currentTime = 0
        isPlaying = false
    }
    func play() {
        isPlaying = true
        onPlayStateChange?(true)
    }
    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        onPlayStateChange?(false)
    }
    func setRate(_ rate: Float) {}
    func seek(to seconds: Double, exact: Bool) {
        currentTime = seconds
        onTimeChange?(seconds)
    }
    func play(from: Double, to: Double) {
        ranges.append((from: from, to: to))
        currentTime = from
    }
    func makeVideoView() -> NSView { NSView() }
}

/// An open project with one video, ready to edit.
@MainActor
struct Fixture {
    let model: AppModel
    let engine: FakeEngine
    let video: VideoItem
    /// The master language (the first one given).
    var en: Track { video.tracks[0] }
    /// The second language.
    var hr: Track { video.tracks[1] }
}

/// A model that never writes to disk, with a fake player (25 frames a second).
@MainActor
func makeModel() -> (model: AppModel, engine: FakeEngine) {
    _ = NSApplication.shared
    let engine = FakeEngine()
    let model = AppModel(engine: engine)
    model.persists = false
    model.autoLineBreaks = true
    model.waveBands = []
    return (model, engine)
}

/// Opens a project holding the given languages; the first is the master, and the others
/// are matched to it by time, the way an imported file is.
@MainActor
func makeFixture(_ languages: [(code: String, subs: [Subtitle])]) -> Fixture {
    let (model, engine) = makeModel()
    let master = Track(language: Language.named(languages[0].code), subtitles: languages[0].subs)
    let video = VideoItem(name: "Film", url: nil, master: master)
    for extra in languages.dropFirst() {
        let linked = RowBuilder.linkByOverlap(extra.subs, master: languages[0].subs)
        let track = Track(language: Language.named(extra.code), subtitles: linked)
        video.tracks.append(track)
        video.openTrackIDs.append(track.id)
    }
    let project = Project(name: "Test", settings: ProjectSettings(), videos: [video], fileURL: nil)
    model.load(project, currentVideoID: video.id)
    // Pretend a video is loaded, so seeking and previews go to the fake player.
    model.videoURL = URL(fileURLWithPath: "/tmp/kptn-sub-test-video.mp4")
    return Fixture(model: model, engine: engine, video: video)
}

/// A new, empty folder in the temporary directory.
func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kptn-sub-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a file into `folder` and returns where it is.
func writeFile(_ name: String, _ contents: String, in folder: URL, encoding: String.Encoding = .utf8) throws -> URL {
    let url = folder.appendingPathComponent(name)
    guard let data = contents.data(using: encoding) else {
        throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    try data.write(to: url)
    return url
}

/// Lets the app's own background work run until `condition` holds (or time runs out).
@MainActor
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
}

/// The lines of a title, as the viewer reads them.
func shownLines(_ text: String) -> [String] {
    Markup.plain(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}
