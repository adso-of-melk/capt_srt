import XCTest
@testable import Titles
@testable import TitlesCore

/// Opening a project, and how the project view lists its videos.
@MainActor
final class ProjectViewTests: XCTestCase {

    private func video(_ name: String, added: Date? = Date(), edited: Date? = nil) -> VideoItem {
        let v = VideoItem(name: name, url: nil, master: Track(language: Language.named("en")), added: added)
        v.edited = edited
        return v
    }

    func testAProjectWithSeveralVideosOpensAtTheProjectView() {
        let (model, _) = makeModel()
        let a = video("Episode 1"), b = video("Episode 2")
        model.load(Project(name: "Show", settings: ProjectSettings(), videos: [a, b], fileURL: nil),
                   currentVideoID: b.id)
        XCTAssertTrue(model.showProjectView)
        XCTAssertTrue(model.video === b, "the video worked on last is the one Return goes back into")
        model.openVideoFromOverview(b)
        XCTAssertFalse(model.showProjectView)
    }

    func testAProjectWithOneVideoOpensTheEditor() {
        let (model, _) = makeModel()
        let only = video("Film")
        model.load(Project(name: "Film", settings: ProjectSettings(), videos: [only], fileURL: nil),
                   currentVideoID: only.id)
        XCTAssertFalse(model.showProjectView)
        XCTAssertTrue(model.video === only)
    }

    func testReloadingStaysInTheEditor() {
        let (model, _) = makeModel()
        let a = video("Episode 1"), b = video("Episode 2")
        model.load(Project(name: "Show", settings: ProjectSettings(), videos: [a, b], fileURL: nil),
                   currentVideoID: a.id, overview: false)
        XCTAssertFalse(model.showProjectView)
    }

    func testNamesSortWithTheirNumbersInOrder() {
        let videos = [video("Episode 10"), video("episode 2"), video("Episode 1"), video("Bonus")]
        XCTAssertEqual(Project.sorted(videos, by: .name).map(\.name), ["Bonus", "Episode 1", "episode 2", "Episode 10"])
    }

    func testDateAddedIsNewestFirstWithUndatedVideosAfterInTheirOrder() {
        let now = Date()
        let old1 = video("Old one"), old2 = video("Old two")
        old1.added = nil
        old2.added = nil
        let early = video("Early", added: now.addingTimeInterval(-60))
        let late = video("Late", added: now)
        XCTAssertEqual(Project.sorted([old1, early, old2, late], by: .added).map(\.name),
                       ["Late", "Early", "Old one", "Old two"])
    }

    func testANewVideoKnowsWhenItWasAdded() {
        let v = VideoItem(name: "New", url: nil, master: Track(language: Language.named("en")))
        XCTAssertNotNil(v.added)
        XCTAssertNil(v.edited)
    }

    func testEditingATitleMakesItsVideoTheLastEdited() {
        let (model, _) = makeModel()
        let a = video("Alpha"), b = video("Bravo")
        a.tracks[0].doc.replaceAll([sub(1, 2, "Hi")])
        let project = Project(name: "Show", settings: ProjectSettings(), videos: [a, b], fileURL: nil)
        project.videoSort = .edited
        model.load(project, currentVideoID: b.id)
        model.openVideoFromOverview(b)
        a.edited = Date().addingTimeInterval(-3600)
        b.edited = nil
        XCTAssertEqual(project.sortedVideos.map(\.name), ["Alpha", "Bravo"])
        model.createTitle(start: 5, end: 7)
        XCTAssertNotNil(b.edited)
        XCTAssertEqual(project.sortedVideos.map(\.name), ["Bravo", "Alpha"])
    }

    func testTheSortAndTheDatesAreSaved() throws {
        let added = Date(timeIntervalSince1970: 1_800_000_000), edited = Date(timeIntervalSince1970: 1_800_000_500)
        let v = video("Film", added: added, edited: edited)
        let project = Project(name: "Show", settings: ProjectSettings(), videos: [v], fileURL: nil)
        project.videoSort = .added
        let back = Project(try ProjectStore.decode(try ProjectStore.encode(project.file(currentVideoID: v.id))), fileURL: nil)
        XCTAssertEqual(back.videoSort, .added)
        XCTAssertEqual(back.videos[0].added, added)
        XCTAssertEqual(back.videos[0].edited, edited)
    }

    func testAnOlderProjectFileSortsByName() throws {
        let v = video("Film")
        var file = Project(name: "Show", settings: ProjectSettings(), videos: [v], fileURL: nil).file(currentVideoID: nil)
        file.videoSort = nil
        file.videos[0].added = nil
        file.videos[0].edited = nil
        let back = Project(try ProjectStore.decode(try ProjectStore.encode(file)), fileURL: nil)
        XCTAssertEqual(back.videoSort, .name)
        XCTAssertNil(back.videos[0].added)
    }
}
