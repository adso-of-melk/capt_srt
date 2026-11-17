import XCTest
@testable import Titles

/// Dropping a mix of videos and subtitle files: matching each file to its video, and the
/// project made from that.
@MainActor
final class ImportTests: XCTestCase {

    // MARK: Test material

    /// Titles with irregular, repeatable start times (a film's timing template).
    private func template(seed: UInt64, count: Int, gaps: ClosedRange<Double> = 1.5...5) -> [Subtitle] {
        var state = seed
        var t = 2.0
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = Double(state >> 33) / Double(1 << 31)
            t += gaps.lowerBound + r * (gaps.upperBound - gaps.lowerBound)
            return Subtitle(start: t, end: t + 1.2, text: "Line \(i)")
        }
    }

    /// A translation made from a template: nearly the same starts, a few titles merged away.
    private func translation(of subs: [Subtitle], dropEvery n: Int = 7) -> [Subtitle] {
        subs.enumerated().filter { $0.offset % n != n - 1 }.map {
            Subtitle(start: $0.element.start + 0.08, end: $0.element.end, text: "Prijevod \($0.offset)")
        }
    }

    private func video(_ name: String, folder: String? = nil, duration: Double? = nil) -> FileMatcher.Video {
        FileMatcher.Video(id: UUID(), name: name, folder: folder, duration: duration)
    }

    private func file(_ name: String, _ subs: [Subtitle], folder: String? = nil) -> FileMatcher.SubFile {
        FileMatcher.SubFile(name: name, folder: folder, subtitles: subs)
    }

    private func read(_ name: String, _ subs: [Subtitle], _ code: String?) -> ImportPlan.ReadFile {
        ImportPlan.ReadFile(url: URL(fileURLWithPath: "/tmp/drop/\(name).srt"), subtitles: subs,
                            language: code.map(Language.named))
    }

    private let short = [sub(1, 2), sub(3, 4), sub(5, 6)]

    // MARK: Names and episodes

    func testNamesAreComparedWithoutTheLanguageTagAndTheExtras() {
        XCTAssertEqual(FileMatcher.subtitleStem("Film.pt-BR"), ["film"])
        XCTAssertEqual(FileMatcher.subtitleStem("Film_ENG_SDH"), ["film"])
        XCTAssertEqual(FileMatcher.subtitleStem("Tražeći nju croatian v2 FINAL"), ["trazeci", "nju"])
        XCTAssertEqual(FileMatcher.subtitleStem("The.Film.2023.1080p.WEB-DL.x264.hr"), ["the", "film"])
        // A language word is only a tag at the end; a name alone is never emptied.
        XCTAssertEqual(FileMatcher.subtitleStem("What Is It.hr"), ["what", "is", "it"])
        XCTAssertEqual(FileMatcher.subtitleStem("English Patient.hr"), ["english", "patient"])
        XCTAssertEqual(FileMatcher.videoStem("Tražeći nju 1080p final v3"), ["trazeci", "nju"])
    }

    func testEpisodeNumbersAreReadInTheUsualWays() {
        typealias Ep = FileMatcher.Episode
        let e = FileMatcher.episode(in:)
        XCTAssertEqual(e("Show.S01E03.1080p"), Ep(season: 1, number: 3))
        XCTAssertEqual(e("Show S02 E10"), Ep(season: 2, number: 10))
        XCTAssertEqual(e("show.1x03.hr"), Ep(season: 1, number: 3))
        XCTAssertEqual(e("Show - Ep. 3 - English"), Ep(season: nil, number: 3))
        XCTAssertEqual(e("Serija epizoda 12"), Ep(season: nil, number: 12))
        XCTAssertEqual(e("Serija 3. epizoda"), Ep(season: nil, number: 3))
        XCTAssertEqual(e("Show E07"), Ep(season: nil, number: 7))
        XCTAssertEqual(e("Show 03 final"), Ep(season: nil, number: 3))
        XCTAssertNil(e("Film 1920x1080"))
        XCTAssertNil(e("Film 2023"))
        XCTAssertNil(e("Film.hr"))
        XCTAssertTrue(FileMatcher.Episode(season: 1, number: 3).agrees(.init(season: nil, number: 3)))
        XCTAssertFalse(FileMatcher.Episode(season: 1, number: 3).agrees(.init(season: 2, number: 3)))
    }

    func testFilesGoToTheVideoTheirNameMatches() {
        let videos = [video("Tražeći nju"), video("Other Film 1080p")]
        let subs = [file("Trazeci_nju.HR.final", short), file("Tražeći nju (ENG) v2", short),
                    file("Other.Film.de", short), file("Something else entirely.en", short)]
        let m = FileMatcher.match(videos: videos, subs: subs)
        XCTAssertEqual(m[subs[0].id]?.video, videos[0].id)
        XCTAssertEqual(m[subs[0].id]?.reason, .name)
        XCTAssertEqual(m[subs[1].id]?.video, videos[0].id)
        XCTAssertEqual(m[subs[2].id]?.video, videos[1].id)
        XCTAssertNil(m[subs[3].id]?.video)
    }

    func testEpisodesDecideAndADifferentEpisodeNeverMatches() {
        let videos = [video("Show S01E01 1080p"), video("Show S01E02 1080p"), video("Show S01E03")]
        let subs = [file("show.1x02.hr", short), file("Show - Ep 3 - English", short),
                    file("Show S01E01.fr", short), file("Show S01E04.en", short)]
        let m = FileMatcher.match(videos: videos, subs: subs)
        XCTAssertEqual(m[subs[0].id]?.video, videos[1].id)
        XCTAssertEqual(m[subs[0].id]?.reason, .episode)
        XCTAssertEqual(m[subs[1].id]?.video, videos[2].id)
        XCTAssertEqual(m[subs[2].id]?.video, videos[0].id)
        // Same show, but an episode that isn't here: left out, not put with a look-alike.
        XCTAssertNil(m[subs[3].id]?.video)
    }

    /// Jeremy's test set, renamed: a series' season 4, four videos, subtitle files in seven
    /// languages named after the episodes' titles (one set with the language in front).
    func testASeasonNumberIsNeverTakenForTheEpisode() {
        typealias Ep = FileMatcher.Episode
        XCTAssertEqual(FileMatcher.episode(in: "space-show-the-next-voyage-season-4-brothers.fa"), Ep(season: 4, number: nil))
        XCTAssertEqual(FileMatcher.episode(in: "Space.show.the.next.voyage.season.4.episode.2.family_720"), Ep(season: 4, number: 2))
        XCTAssertEqual(FileMatcher.episode(in: "Show Sezona 2 Epizoda 5"), Ep(season: 2, number: 5))
        XCTAssertEqual(FileMatcher.episode(in: "Show S02"), Ep(season: 2, number: nil))
        XCTAssertNil(FileMatcher.episode(in: "Film_720"))
        XCTAssertTrue(Ep(season: 4, number: nil).agrees(Ep(season: 4, number: 2)))
        XCTAssertFalse(Ep(season: 4, number: nil).sameEpisode(Ep(season: 4, number: 2)))

        let titles = ["the.long.way.home.part.ii", "family", "brothers", "strangers"]
        let videos = titles.enumerated().map { video("Space.show.the.next.voyage.season.4.episode.\($0.offset + 1).\($0.element)_720") }
        var subs: [(file: FileMatcher.SubFile, video: Int)] = []
        for (i, t) in titles.enumerated() {
            let dashed = t.replacingOccurrences(of: ".", with: "-")
            subs.append((file("english-space-show-the-next-voyage-season-4-\(dashed)", short), i))
            for code in ["fa", "ja", "pl", "sr-Cyrl", "th", "zh-Hans"] {
                subs.append((file("space-show-the-next-voyage-season-4-\(dashed).\(code)", short), i))
            }
        }
        let m = FileMatcher.match(videos: videos, subs: subs.map(\.file))
        for s in subs {
            XCTAssertEqual(m[s.file.id]?.video, videos[s.video].id, s.file.name)
            XCTAssertEqual(m[s.file.id]?.reason, .name, s.file.name)
        }
        XCTAssertEqual(FileMatcher.commonName(videos.map(\.name)).map(FileMatcher.readable),
                       "Space show the next voyage season 4")
    }

    func testANameOrEpisodeWinsOverTheVideosLength() {
        // Short test clips with full-length subtitle files: the names still decide.
        let long = template(seed: 1, count: 300)   // ends near 970 s
        let videos = [video("Film 1", duration: 120), video("Film 2", duration: 120), video("Film 3", duration: 2000)]
        let subs = [file("Film 1.hr", long), file("Film 2.en", long), file("Film_3_DE", long)]
        let m = FileMatcher.match(videos: videos, subs: subs)
        XCTAssertEqual(subs.map { m[$0.id]?.video }, videos.map(\.id))
        XCTAssertEqual(subs.map { m[$0.id]?.reason }, [.episode, .episode, .episode])
        let named = [video("Alpha", duration: 120), video("Bravo", duration: 2000)]
        let alpha = [file("Alpha.hr", long)]
        XCTAssertEqual(FileMatcher.match(videos: named, subs: alpha)[alpha[0].id]?.video, named[0].id)
    }

    func testTheOnlyVideoInAFileFolderTakesIt() {
        let videos = [video("movie", folder: "/a/Film One"), video("movie", folder: "/b/Film Two")]
        let subs = [file("titlovi.hr", short, folder: "/b/Film Two")]
        let m = FileMatcher.match(videos: videos, subs: subs)
        XCTAssertEqual(m[subs[0].id]?.video, videos[1].id)
        XCTAssertEqual(m[subs[0].id]?.reason, .folder)
    }

    func testWithOneVideoEveryFileGoesToIt() {
        let videos = [video("Film")]
        let subs = [file("whatever.hr", short), file("export 3", short)]
        let m = FileMatcher.match(videos: videos, subs: subs)
        XCTAssertEqual(Set(subs.compactMap { m[$0.id]?.video }), [videos[0].id])
        XCTAssertEqual(m[subs[1].id]?.reason, .single)
    }

    // MARK: Timing and length

    func testTranslationsOfOneCutShareTheirTiming() {
        let a = template(seed: 1, count: 300), b = template(seed: 2, count: 280)
        XCTAssertTrue(FileMatcher.sameTiming(a.map(\.start), translation(of: a).map(\.start)))
        XCTAssertFalse(FileMatcher.sameTiming(a.map(\.start), b.map(\.start)))
        // A very busy file matches anything by chance: that isn't enough.
        let busy = (0..<2000).map { Double($0) * 0.5 }
        XCTAssertFalse(FileMatcher.sameTiming(a.map(\.start), busy))
        XCTAssertFalse(FileMatcher.sameTiming(Array(a.prefix(3)).map(\.start), a.map(\.start)))
    }

    func testBadlyNamedFilesFollowTheFilesTimedLikeThem() {
        let a = template(seed: 1, count: 300), b = template(seed: 2, count: 280)
        let videos = [video("Alpha", duration: 1200), video("Bravo", duration: 1200)]
        let subs = [file("Alpha.en", a), file("export (3)", translation(of: a)), file("titlovi final", translation(of: a, dropEvery: 5)),
                    file("Bravo.en", b), file("export (4)", translation(of: b)), file("prijevod", translation(of: b, dropEvery: 9))]
        let m = FileMatcher.match(videos: videos, subs: subs)
        XCTAssertEqual(subs.map { m[$0.id]?.video }, [videos[0].id, videos[0].id, videos[0].id,
                                                      videos[1].id, videos[1].id, videos[1].id])
        XCTAssertEqual(m[subs[1].id]?.reason, .timing)
        XCTAssertEqual(m[subs[0].id]?.group, m[subs[2].id]?.group)
        XCTAssertNotEqual(m[subs[0].id]?.group, m[subs[3].id]?.group)
    }

    func testNamelessFilesGoToTheVideoWhoseLengthTheyFit() {
        let a = template(seed: 1, count: 300)                       // ends near 970 s
        let b = template(seed: 2, count: 300, gaps: 3...5.2)        // ends near 1240 s
        let aEnd = a.last!.end, bEnd = b.last!.end
        XCTAssertGreaterThan(bEnd, 1005)
        let videos = [video("clip_a", duration: 1000), video("clip_b", duration: 1300)]
        let subs = [file("untitled.hr", a), file("untitled.en", translation(of: a)),
                    file("untitled.hr", b), file("untitled.en", translation(of: b))]
        XCTAssertLessThan(aEnd, 1000)
        let m = FileMatcher.match(videos: videos, subs: subs)
        // B's titles run past the end of the shorter video, so they can only be the longer one's.
        XCTAssertEqual(m[subs[2].id]?.video, videos[1].id)
        XCTAssertEqual(m[subs[3].id]?.video, videos[1].id)
        XCTAssertEqual(m[subs[0].id]?.video, videos[0].id)
        XCTAssertEqual(m[subs[1].id]?.video, videos[0].id)
        XCTAssertEqual(m[subs[0].id]?.reason, .length)
        XCTAssertTrue(FileMatcher.Reason.length.isGuess)
    }

    func testLengthsArePairedClosestFirst() {
        // Groups ending at 950 and 990 s; videos of 1000 and 1100 s.
        let spans: [Double] = [950, 990], lengths: [Double] = [1000, 1100]
        let pairs = FileMatcher.orderedMatching(groups: 2, videos: [0, 1]) { g, j in
            let s = lengths[j] - spans[g]
            return s >= -5 ? s * s : nil
        }
        XCTAssertEqual(Set(pairs.map { "\($0.0)-\($0.1)" }), ["0-0", "1-1"])
        // A group that fits no video stays out.
        let none = FileMatcher.orderedMatching(groups: 1, videos: [0]) { _, _ in nil }
        XCTAssertTrue(none.isEmpty)
    }

    func testFilesWithNothingToGoOnAreLeftForYouToPlace() {
        let videos = [video("Alpha"), video("Bravo")]
        let subs = [file("export", short)]
        let m = FileMatcher.match(videos: videos, subs: subs)
        XCTAssertNil(m[subs[0].id]?.video)
    }

    func testTimingIsFoundThroughAnOffsetOrAnotherFrameRate() {
        let a = template(seed: 3, count: 300)
        let starts = a.map(\.start)
        // 3.2 s later (a different head on the video).
        let late = translation(of: a).map { $0.start + 3.2 }
        let fit = FileMatcher.timingFit(starts, late)
        XCTAssertEqual(fit?.offset ?? 0, 3.28, accuracy: 0.15)
        XCTAssertEqual(fit?.speed, 1)
        XCTAssertGreaterThan(fit?.share ?? 0, 0.8)
        // Timed for 25 fps where the other is 23.976: 4% faster all the way through.
        let pal = translation(of: a).map { $0.start * 23.976 / 25 }
        XCTAssertEqual(FileMatcher.timingFit(starts, pal)?.speed ?? 0, 23.976 / 25, accuracy: 0.0001)
        // A broadcast file starting at 10:00:00.
        let broadcast = translation(of: a).map { $0.start + 36000 }
        XCTAssertEqual(FileMatcher.timingFit(starts, broadcast)?.offset ?? 0, 36000.08, accuracy: 0.15)
        XCTAssertEqual(FileMatcher.span(36000.1), "10 h 0.1 s")
        XCTAssertEqual(FileMatcher.span(3.24), "3.2 s")
        // Unrelated files still aren't timed alike, however they're moved.
        XCTAssertNil(FileMatcher.timingFit(starts, template(seed: 4, count: 300).map(\.start)))

        // Placed by timing, the dialog says how alike and that it's offset.
        let videos = [video("Alpha", duration: 1200), video("Bravo", duration: 1200)]
        let late2 = translation(of: a).map { Subtitle(start: $0.start + 3.2, end: $0.end + 3.2, text: $0.text) }
        let subs = [file("Alpha.en", a), file("export", late2)]
        let m = FileMatcher.match(videos: videos, subs: subs)
        XCTAssertEqual(m[subs[1].id]?.video, videos[0].id)
        XCTAssertEqual(m[subs[1].id]?.reason, .timing)
        XCTAssertGreaterThan(m[subs[1].id]?.score ?? 0, 0.8)
        XCTAssertTrue(m[subs[1].id]?.caution ?? false)
        XCTAssertTrue(m[subs[1].id]?.detail?.contains("3.3 s later") ?? false, m[subs[1].id]?.detail ?? "")
    }

    /// Speech heard under a file's titles: starting a little before each, ending a little
    /// before it goes, with a few stray noises.
    private func speech(under subs: [Subtitle], length: Double, seed: UInt64) -> FileMatcher.Speech {
        let n = Int(length / FileMatcher.Speech.frame)
        var active = [Bool](repeating: false, count: n)
        for s in subs {
            let a = max(0, Int((s.start - 0.3) * 10)), b = min(n, Int((s.end - 0.4) * 10))
            if b > a { for f in a..<b { active[f] = true } }
        }
        var state = seed
        for _ in 0..<(n / 40) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            active[Int(state >> 33) % n] = true
        }
        return FileMatcher.Speech(active: active)
    }

    func testFilesNothingElsePlacesGoWhereTheirTitlesFollowTheSpeech() {
        let a = template(seed: 5, count: 300), b = template(seed: 6, count: 300)
        let videos = [video("reel_a", duration: 1300), video("reel_b", duration: 1300)]
        // Names say nothing, and both sets fit both videos' length.
        let subs = [file("titles.hr", a), file("titles.en", translation(of: a)),
                    file("prijevod.hr", b), file("prijevod.en", translation(of: b))]
        // The first video speaks B's lines, the second A's.
        let heard = [videos[0].id: speech(under: b, length: 1300, seed: 1),
                     videos[1].id: speech(under: a, length: 1300, seed: 2)]
        let m = FileMatcher.match(videos: videos, subs: subs, speech: heard)
        XCTAssertEqual(subs.map { m[$0.id]?.video }, [videos[1].id, videos[1].id, videos[0].id, videos[0].id])
        XCTAssertEqual(subs.map { m[$0.id]?.reason }, [.speech, .speech, .speech, .speech])
        XCTAssertGreaterThan(m[subs[0].id]?.score ?? 0, 0.5)
        XCTAssertFalse(m[subs[0].id]?.caution ?? true)

        // Both videos sound alike to A's titles: speech can't tell, and length guesses.
        let same = [videos[0].id: speech(under: a, length: 1300, seed: 1),
                    videos[1].id: speech(under: a, length: 1300, seed: 2)]
        let unsure = FileMatcher.match(videos: videos, subs: Array(subs.prefix(2)), speech: same)
        XCTAssertNotEqual(unsure[subs[0].id]?.reason, .speech)

        // Titles timed for 25 fps against a 23.976 video still find it, with a warning.
        let pal = a.map { Subtitle(start: $0.start * 23.976 / 25, end: $0.end * 23.976 / 25, text: $0.text) }
        let fit = FileMatcher.speechFit(file("x", pal), speech(under: a, length: 1300, seed: 3))
        XCTAssertEqual(fit?.speed ?? 0, 25 / 23.976, accuracy: 0.0001)
        XCTAssertGreaterThan(fit?.score ?? 0, 0.5)
    }

    func testSpeechIsWhereTheSoundRisesAboveTheQuietAroundIt() {
        var levels = [Float](repeating: -60, count: 600)
        for i in 100..<130 { levels[i] = -25 }
        for i in 200..<210 { levels[i] = -28 }
        for i in 212..<220 { levels[i] = -28 }   // a pause of 0.2 s: bridged
        levels[500] = -20                        // a click: dropped
        let active = FileMatcher.Speech.detect(levels)
        XCTAssertEqual(active.indices.filter { active[$0] }, Array(100..<130) + Array(200..<220))
        let speech = FileMatcher.Speech(levels: levels)
        XCTAssertEqual(speech.frames, 600)
        XCTAssertEqual(speech.prefix[600], 50)
    }

    // MARK: The plan

    func testAProjectNameAndAMasterLanguageAreSuggested() {
        XCTAssertEqual(FileMatcher.commonName(["Show.S01E01.1080p", "Show.S01E02.1080p"]), "Show")
        XCTAssertEqual(FileMatcher.commonName(["Tražeći nju"]), "Tražeći nju")
        XCTAssertNil(FileMatcher.commonName(["Alpha", "Bravo"]))
        XCTAssertEqual(FileMatcher.displayStem("Show.S01E02.en"), "Show.S01E02")
        XCTAssertEqual(FileMatcher.displayStem("Film_HR_final"), "Film")

        // No English for one of the videos: Croatian, which both have, is the master.
        let plan = ImportPlan.make(
            videos: [(URL(fileURLWithPath: "/tmp/drop/Show S01E01.mp4"), nil), (URL(fileURLWithPath: "/tmp/drop/Show S01E02.mp4"), nil)],
            subtitles: [read("Show S01E01.hr", short, "hr"), read("Show S01E01.de", short, "de"),
                        read("Show S01E02.hr", short, "hr"), read("Show S01E02.en", short, "en")],
            defaultMaster: Language.named("en"), intoProject: false)
        XCTAssertEqual(plan.name, "Show")
        XCTAssertEqual(plan.masterLanguage.code, "hr")
        XCTAssertEqual(plan.files.filter { $0.target == nil }.count, 0)
        // The master language comes first.
        XCTAssertEqual(plan.files(of: plan.targets[0].id).first?.language.code, "hr")
    }

    func testSubtitlesWithoutVideosMakeOneVideoPerCut() {
        let a = template(seed: 1, count: 200), b = template(seed: 2, count: 200)
        let plan = ImportPlan.make(
            videos: [],
            subtitles: [read("Show.S01E02.en", b, "en"), read("Show.S01E02.hr", translation(of: b), "hr"),
                        read("Show.S01E01.en", a, "en"), read("Show.S01E01.hr", translation(of: a), "hr"),
                        read("Show.S01E01.de", translation(of: a), nil)],
            defaultMaster: Language.named("en"), intoProject: false)
        XCTAssertEqual(plan.targets.map(\.name), ["Show.S01E01", "Show.S01E02"])
        XCTAssertEqual(plan.files(of: plan.targets[0].id).count, 3)
        XCTAssertEqual(plan.files(of: plan.targets[1].id).count, 2)
        XCTAssertTrue(plan.targets.allSatisfy { $0.url == nil })
        // No language found: the master's, marked for checking.
        let guessed = plan.files.filter(\.languageGuessed)
        XCTAssertEqual(guessed.map(\.url.lastPathComponent), ["Show.S01E01.de.srt"])
        XCTAssertEqual(guessed.first?.language.code, "en")
    }

    func testMovingAFileTakesTheFilesTimedLikeItAlong() throws {
        let a = template(seed: 1, count: 300)
        let videos: [(url: URL, duration: Double?)] = [(URL(fileURLWithPath: "/tmp/drop/clip_a.mp4"), 1000),
                                                       (URL(fileURLWithPath: "/tmp/drop/clip_b.mp4"), 1000)]
        var plan = ImportPlan.make(videos: videos,
                                   subtitles: [read("x.en", a, "en"), read("y.hr", translation(of: a), "hr"),
                                               read("z.de", translation(of: a), "de")],
                                   defaultMaster: Language.named("en"), intoProject: false)
        let en = try XCTUnwrap(plan.files.first { $0.language.code == "en" })
        let placed = try XCTUnwrap(en.target)
        XCTAssertEqual(en.reason, .length)
        XCTAssertEqual(plan.groupMates(of: en.id).count, 2)
        let other = try XCTUnwrap(plan.targets.first { $0.id != placed })
        plan.move(en.id, to: other.id, withGroup: true)
        XCTAssertEqual(plan.files(of: other.id).count, 3)
        XCTAssertTrue(plan.files.allSatisfy { $0.reason == .moved })
        // One alone, then out of the project.
        plan.move(en.id, to: nil, withGroup: false)
        XCTAssertEqual(plan.files(of: other.id).count, 2)
        XCTAssertEqual(plan.files(of: nil).map(\.id), [en.id])
    }

    // MARK: Making the project

    func testTheProjectHasEachVideoWithItsLanguagesLinkedToItsMaster() throws {
        let a = template(seed: 1, count: 120), b = template(seed: 2, count: 100)
        let plan = ImportPlan.make(
            videos: [(URL(fileURLWithPath: "/tmp/drop/Alpha.mp4"), 1200), (URL(fileURLWithPath: "/tmp/drop/Bravo.mp4"), 1200),
                     (URL(fileURLWithPath: "/tmp/drop/Extra.mp4"), 300)],
            subtitles: [read("Alpha.hr", translation(of: a), "hr"), read("Alpha.en", a, "en"), read("Alpha.de", translation(of: a), "de"),
                        read("Bravo.en", b, "en"), read("Bravo.hr", translation(of: b), "hr")],
            defaultMaster: Language.named("en"), intoProject: false)
        let (model, _) = makeModel()
        var settings = ProjectSettings()
        settings.masterLanguage = plan.masterLanguage
        let project = model.buildProject(from: plan, name: "Test", settings: settings, fileURL: nil)
        XCTAssertEqual(project.videos.map(\.name), ["Alpha", "Bravo", "Extra"])
        let alpha = project.videos[0]
        XCTAssertEqual(alpha.master?.language.code, "en")
        XCTAssertEqual(alpha.tracks.map(\.language.code), ["en", "hr", "de"])
        XCTAssertEqual(alpha.openTrackIDs.count, 3)
        let hr = try XCTUnwrap(alpha.tracks.first { $0.language.code == "hr" })
        let masterIDs = Set(alpha.master?.doc.subtitles.map(\.id) ?? [])
        let links = hr.doc.subtitles.compactMap(\.link)
        XCTAssertGreaterThan(links.count, 90)
        XCTAssertTrue(links.allSatisfy(masterIDs.contains))
        // A video without subtitle files comes in with an empty master.
        XCTAssertEqual(project.videos[2].tracks.count, 1)
        XCTAssertTrue(project.videos[2].master?.doc.subtitles.isEmpty ?? false)
        // Opened, every language is wired up (undo, the minimum gap…).
        model.load(project, currentVideoID: alpha.id)
        XCTAssertTrue(project.videos.allSatisfy { $0.tracks.allSatisfy { $0.doc.tidy != nil } })
    }

    func testFilesAreAddedToTheOpenProject() throws {
        let master = template(seed: 1, count: 80)
        let f = makeFixture([("en", master)])
        let plan = ImportPlan.make(
            videos: [(URL(fileURLWithPath: "/tmp/drop/Other.mp4"), nil)],
            existing: [ImportPlan.Target(id: UUID(), name: "Film", url: nil, existingID: f.video.id, duration: nil)],
            subtitles: [read("Film.hr", translation(of: master), "hr"), read("Other.de", short, "de")],
            defaultMaster: Language.named("en"), intoProject: true)
        XCTAssertEqual(plan.files.compactMap(\.reason), [.name, .name])
        f.model.addToProject(plan)
        let project = try XCTUnwrap(f.model.project)
        XCTAssertEqual(project.videos.count, 2)
        XCTAssertEqual(f.video.tracks.map(\.language.code), ["en", "hr"])
        XCTAssertTrue(f.video.openTrackIDs.contains(f.video.tracks[1].id))
        XCTAssertGreaterThan(f.video.tracks[1].doc.subtitles.compactMap(\.link).count, 60)
        let other = project.videos[1]
        XCTAssertEqual(other.name, "Other")
        XCTAssertEqual(other.master?.language.code, "de")
        XCTAssertNotNil(other.master?.doc.tidy)
        // The rows show the new language straight away.
        XCTAssertTrue(f.model.rows.contains { $0.cells[f.video.tracks[1].id] != nil })
    }

    func testAnEmptyMasterIsFilledFirst() throws {
        let f = makeFixture([("en", [])])
        let master = template(seed: 3, count: 60)
        let plan = ImportPlan.make(
            videos: [],
            existing: [ImportPlan.Target(id: UUID(), name: "Film", url: nil, existingID: f.video.id, duration: nil)],
            subtitles: [read("Film.hr", translation(of: master), "hr"), read("Film.en", master, "en")],
            defaultMaster: Language.named("en"), intoProject: true)
        f.model.addToProject(plan)
        XCTAssertEqual(f.video.tracks.map(\.language.code), ["en", "hr"])
        XCTAssertEqual(f.en.doc.subtitles.count, 60)
        XCTAssertGreaterThan(f.hr.doc.subtitles.compactMap(\.link).count, 40)
    }

    // MARK: Dropping

    func testSubtitleFilesDroppedOnAVideoGoStraightIntoIt() throws {
        // A video added on its own: an empty master in the project's usual language.
        let f = makeFixture([("en", [])])
        let folder = try tempFolder()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let a = template(seed: 4, count: 40)
        let hr = try writeFile("Brothers.hr.srt", SubtitleFormats.srt(a), in: folder)
        let fa = try writeFile("Brothers.fa.srt", SubtitleFormats.srt(translation(of: a)), in: folder)
        f.model.dropFiles([hr, fa], onto: f.video)
        XCTAssertTrue(waitUntil { f.video.tracks.count == 2 })
        // No file in English: the first file's language becomes the master, filled from it.
        XCTAssertEqual(f.video.tracks.map(\.language.code), ["hr", "fa"])
        XCTAssertEqual(f.video.master?.language.code, "hr")
        XCTAssertEqual(f.video.master?.doc.subtitles.count, 40)
        XCTAssertGreaterThan(f.video.tracks[1].doc.subtitles.compactMap(\.link).count, 30)
        // Straight in: no dialog.
        XCTAssertNil(f.model.importPlan)
        XCTAssertNil(f.model.sheet)
    }


    func testDroppedFoldersAreOpenedAndHiddenFilesSkipped() throws {
        let folder = try tempFolder()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let inner = folder.appendingPathComponent("Episode 2", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        _ = try writeFile("b.srt", "", in: folder)
        _ = try writeFile("a.srt", "", in: inner)
        _ = try writeFile(".DS_Store", "", in: folder)
        let found = AppModel.expandFolders([folder]).map(\.lastPathComponent)
        XCTAssertEqual(Set(found), ["a.srt", "b.srt"])
    }

    func testDroppingSubtitleFilesOnTheHomeScreenOffersANewProject() throws {
        let folder = try tempFolder()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let a = template(seed: 1, count: 60), b = template(seed: 2, count: 60)
        for (name, subs) in [("Show.S01E01.en", a), ("Show.S01E01.hr", translation(of: a)),
                             ("Show.S01E02.en", b), ("Show.S01E02.hr", translation(of: b))] {
            _ = try writeFile(name + ".srt", SubtitleFormats.srt(subs), in: folder)
        }
        _ = try writeFile("notes.txt", "not a subtitle", in: folder)
        let (model, _) = makeModel()
        model.handleDrop([folder])
        XCTAssertTrue(waitUntil { model.importPlan != nil })
        let plan = try XCTUnwrap(model.importPlan)
        XCTAssertEqual(model.sheet, .dropImport)
        XCTAssertFalse(plan.intoProject)
        XCTAssertEqual(plan.targets.map(\.name), ["Show.S01E01", "Show.S01E02"])
        XCTAssertEqual(Set(plan.files.map(\.language.code)), ["en", "hr"])
        XCTAssertEqual(plan.name, "Show")
    }
}
