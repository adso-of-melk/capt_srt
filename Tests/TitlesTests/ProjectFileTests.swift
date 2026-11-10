import XCTest
@testable import Titles

/// The project file: everything survives saving and opening, and files from other builds
/// (or damaged ones) still open.
@MainActor
final class ProjectFileTests: XCTestCase {

    func testAProjectSurvivesSavingAndOpening() throws {
        let a = sub(1, 2, "Hello"), b = sub(3.25, 4.75, "<i>Two</i>\nlines")
        let master = Track(language: Language.named("en"), subtitles: [a, b])
        let video = VideoItem(name: "Film", url: URL(fileURLWithPath: "/Movies/Film one.mp4"), master: master)
        let hr = Track(language: Language.named("hr"), locked: true,
                       subtitles: [Subtitle(start: 1, end: 2, text: "Bok", link: a.id)])
        hr.maxCPS = 20
        hr.maxCharsPerLine = 37
        video.tracks.append(hr)
        video.openTrackIDs.append(hr.id)
        video.focusedTrackID = hr.id

        var settings = ProjectSettings()
        settings.standard = .broadcast
        settings.frameRate = 23.976
        settings.startTimecode = 36000
        settings.timecodeDisplay = .milliseconds
        settings.exportFormat = .vtt
        settings.utf8BOM = true
        settings.crlf = false
        settings.namingPattern = "{project}_{lang}"
        settings.masterLanguage = Language.named("hr")
        let project = Project(name: "Round trip", settings: settings, videos: [video], fileURL: nil)

        let data = try ProjectStore.encode(project.file(currentVideoID: video.id))
        let file = try ProjectStore.decode(data)
        let back = Project(file, fileURL: nil)

        XCTAssertEqual(back.id, project.id)
        XCTAssertEqual(back.name, "Round trip")
        XCTAssertEqual(back.settings, settings)
        XCTAssertEqual(file.currentVideoID, video.id)
        XCTAssertEqual(back.videos.count, 1)

        let v = back.videos[0]
        XCTAssertEqual(v.id, video.id)
        XCTAssertEqual(v.name, "Film")
        XCTAssertEqual(v.url?.path, "/Movies/Film one.mp4")
        XCTAssertEqual(v.masterTrackID, master.id)
        XCTAssertEqual(v.openTrackIDs, [master.id, hr.id])
        XCTAssertEqual(v.focusedTrackID, hr.id)
        XCTAssertEqual(v.tracks.map(\.id), [master.id, hr.id])
        XCTAssertEqual(v.tracks[0].doc.subtitles, [a, b])
        XCTAssertEqual(v.tracks[1].doc.subtitles, hr.doc.subtitles)
        XCTAssertEqual(v.tracks[1].language, Language.named("hr"))
        XCTAssertTrue(v.tracks[1].locked)
        XCTAssertEqual(v.tracks[1].maxCPS, 20)
        XCTAssertEqual(v.tracks[1].maxCharsPerLine, 37)
        XCTAssertNil(v.tracks[0].maxCPS)
        // Opening a project leaves nothing selected and nothing to undo.
        XCTAssertNil(v.tracks[0].doc.selectedID)
        XCTAssertFalse(v.tracks[0].doc.canUndo)
    }

    func testSettingsMissingFromAFileTakeTheirDefaults() throws {
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, ProjectSettings())

        let preset = try JSONDecoder().decode(TimingPreset.self, from: Data(#"{"id":"custom","name":"Mine","maxCPS":20}"#.utf8))
        XCTAssertEqual(preset.name, "Mine")
        XCTAssertEqual(preset.maxCPS, 20)
        XCTAssertEqual(preset.maxCharsPerLine, TimingPreset.general.maxCharsPerLine)
        XCTAssertEqual(preset.maxLines, TimingPreset.general.maxLines)
        XCTAssertEqual(preset.minDuration, TimingPreset.general.minDuration)
        XCTAssertEqual(preset.maxDuration, TimingPreset.general.maxDuration)
        XCTAssertEqual(preset.minGapFrames, TimingPreset.general.minGapFrames)
    }

    func testSettingsThisBuildDoesNotKnowAreIgnored() throws {
        let json = #"{"timecodeDisplay":"bananas","crlf":false,"frameRate":"fast","somethingNew":42,"standard":{"id":"custom","name":"Mine","maxCPS":20,"alsoNew":true}}"#
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.timecodeDisplay, .frames)
        XCTAssertFalse(settings.crlf)
        XCTAssertNil(settings.frameRate)
        XCTAssertEqual(settings.standard.maxCPS, 20)
        XCTAssertEqual(settings.standard.maxCharsPerLine, 42)
        XCTAssertEqual(settings.namingPattern, "{video}.{lang}")
    }

    func testEveryStandardSurvivesSaving() throws {
        for preset in TimingPreset.all {
            let data = try JSONEncoder().encode(preset)
            XCTAssertEqual(try JSONDecoder().decode(TimingPreset.self, from: data), preset)
        }
    }

    func testAWholeProjectFileWithOnlyTheBasicsOpens() throws {
        let id = UUID(), videoID = UUID(), trackID = UUID(), titleID = UUID()
        let json = """
        {
          "format": 1,
          "id": "\(id.uuidString)",
          "name": "Old project",
          "modified": "2026-01-02T03:04:05Z",
          "settings": {},
          "videos": [{
            "id": "\(videoID.uuidString)",
            "name": "Film",
            "masterTrackID": "\(trackID.uuidString)",
            "openTrackIDs": ["\(trackID.uuidString)"],
            "tracks": [{
              "id": "\(trackID.uuidString)",
              "language": {"code": "en", "name": "English"},
              "locked": false,
              "subtitles": [{"id": "\(titleID.uuidString)", "start": 1, "end": 2.5, "text": "Hello"}]
            }]
          }]
        }
        """
        let file = try ProjectStore.decode(Data(json.utf8))
        let project = Project(file, fileURL: nil)
        XCTAssertEqual(project.name, "Old project")
        XCTAssertEqual(project.settings, ProjectSettings())
        let titles = project.videos[0].tracks[0].doc.subtitles
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles[0].id, titleID)
        XCTAssertEqual(titles[0].end, 2.5)
        XCTAssertNil(titles[0].link)
        XCTAssertNil(project.videos[0].url)
        XCTAssertEqual(project.videos[0].focusedTrackID, trackID)
    }

    func testADamagedFileStillGetsAColumnToShow() {
        let en = TrackFile(id: UUID(), language: Language.named("en"), locked: false, maxCPS: nil,
                           maxCharsPerLine: nil, subtitles: [sub(1, 2, "Hello")])
        let hr = TrackFile(id: UUID(), language: Language.named("hr"), locked: false, maxCPS: nil,
                           maxCharsPerLine: nil, subtitles: [])
        // A master, open columns and a focused language that aren't in the file.
        let lost = VideoItem(VideoFile(id: UUID(), name: "Film", url: nil, masterTrackID: UUID(),
                                       tracks: [en, hr], openTrackIDs: [UUID(), UUID()], focusedTrackID: UUID()))
        XCTAssertEqual(lost.masterTrackID, en.id)
        XCTAssertEqual(lost.openTrackIDs, [en.id])
        XCTAssertEqual(lost.focusedTrackID, en.id)
        XCTAssertEqual(lost.openTracks.count, 1)

        // Columns listed twice, and a focused language whose column is closed.
        let twice = VideoItem(VideoFile(id: UUID(), name: "Film", url: nil, masterTrackID: en.id,
                                        tracks: [en, hr], openTrackIDs: [en.id, en.id], focusedTrackID: hr.id))
        XCTAssertEqual(twice.openTrackIDs, [en.id])
        XCTAssertEqual(twice.focusedTrackID, en.id)
    }

    func testFileNamesAreMadeSafe() {
        XCTAssertEqual(ProjectStore.sanitize("A/B: C?"), "A-B- C-")
        XCTAssertEqual(ProjectStore.sanitize("  Plain name  "), "Plain name")
        XCTAssertEqual(ProjectStore.sanitize(""), "")
    }

    func testFilesAreRecognisedAsBeingInICloud() {
        let home = NSHomeDirectory()
        XCTAssertTrue(ProjectStore.isInICloud(URL(fileURLWithPath: home + "/Library/Mobile Documents/com~apple~CloudDocs/Film.kptnsub")))
        XCTAssertFalse(ProjectStore.isInICloud(URL(fileURLWithPath: home + "/Movies/KPTN.SUB/Film.kptnsub")))
        XCTAssertFalse(ProjectStore.isDataless(URL(fileURLWithPath: "/definitely/not/here.srt")))
    }
}
