import Foundation

/// Dropping a mix of videos and subtitle files: works out which video each subtitle file
/// belongs to. In order of trust:
///  1. Episode: S01E03, 1x03, "Ep 3", "Epizoda 3" or a lone number in both names, and the same.
///     Different episode numbers are never matched.
///  2. Name: the subtitle file's name without its language tag and without the usual extras
///     (final, v2, SDH, 1080p, x264, a year) compared word by word with the video's.
///  3. Folder: the only video in the subtitle file's folder.
///  4. Timing: translations of one film share most of their start times (within half a second,
///     allowing for a constant offset or a 25/23.976 speed change), so a file timed like a file
///     already matched goes with it.
///  5. Speech: when the videos' audio has been listened to (`Speech`), a set of files timed
///     alike goes to the video whose speech its titles line up with, clearly better than any
///     other's.
///  6. Length: what's still open goes to the video whose length its titles fit. A subtitle
///     file whose titles run past a video's end never belongs to that video.
/// Pure and quick (the audio is read beforehand): the dialog shows each match's reason and
/// everything can be moved.
enum FileMatcher {
    struct Video: Sendable {
        let id: UUID
        /// File name without its extension (or the video's name when it has no file).
        let name: String
        /// The folder it's in, for files.
        let folder: String?
        /// Seconds, when it could be read.
        let duration: Double?
    }

    struct SubFile: Sendable {
        let id: UUID
        /// File name without its extension.
        let name: String
        let folder: String?
        /// Start times of its titles, in order.
        let starts: [Double]
        /// Their end times, in the same order.
        let ends: [Double]
        /// When its last title ends.
        let lastEnd: Double

        init(id: UUID = UUID(), name: String, folder: String? = nil, subtitles: [Subtitle]) {
            self.id = id
            self.name = name
            self.folder = folder
            let sorted = subtitles.sorted { $0.start < $1.start }
            starts = sorted.map(\.start)
            ends = sorted.map(\.end)
            lastEnd = subtitles.map(\.end).max() ?? 0
        }
    }

    enum Reason: String, Sendable, Equatable, CaseIterable {
        case episode, name, folder, timing, speech, length, single, moved, dropped

        /// The word on the chip in the dialog (nil: no chip).
        var chip: String? {
            switch self {
            case .episode: return "EPISODE"
            case .name: return "NAME"
            case .folder: return "FOLDER"
            case .timing: return "TIMING"
            case .speech: return "SPEECH"
            case .length: return "LENGTH"
            case .single, .moved, .dropped: return nil
            }
        }

        var explanation: String {
            switch self {
            case .episode: return "Same episode number as the video"
            case .name: return "Its name matches the video's"
            case .folder: return "The only video in its folder"
            case .timing: return "Timed like the other files matched to this video"
            case .speech: return "Its titles line up with the speech in this video, far better than in any other"
            case .length: return "A guess: its titles fit this video's length. Check it."
            case .single: return "The only video"
            case .moved: return "Moved here by you"
            case .dropped: return "Dropped on this video"
            }
        }

        /// Less certain: shown in a warning colour.
        var isGuess: Bool { self == .length }

        /// Placed with the files timed like it: they move together.
        var placesGroup: Bool { self == .timing || self == .speech || self == .length }
    }

    struct Match: Sendable, Equatable {
        var video: UUID?
        var reason: Reason?
        /// Files timed alike share a group (translations of the same cut).
        var group: Int
        /// How well it fits: the share of titles timed alike (TIMING), or how closely its
        /// titles follow the speech (SPEECH).
        var score: Double? = nil
        /// More about the match, for the dialog (an offset, a speed change).
        var detail: String? = nil
        /// Worth a look: its titles are offset or run at another speed.
        var caution = false
    }

    // MARK: Matching

    /// `speech`: when people speak in each video (by video id), for the videos that were listened to.
    static func match(videos: [Video], subs: [SubFile], speech: [UUID: Speech] = [:]) -> [UUID: Match] {
        let (videoStems, common) = distinctive(videos.map { Set(videoStem($0.name)) })
        let videoEpisodes = videos.map { episode(in: $0.name) }
        let (groups, fits) = timingLinks(subs)
        var out: [UUID: Match] = [:]
        // Per file: the videos it could be by episode (`sameCut`), and of those, the ones
        // its titles also fit (`allowed`).
        var sameCut: [[Int]] = []
        var allowed: [[Int]] = []

        for (i, s) in subs.enumerated() {
            out[s.id] = Match(video: nil, reason: nil, group: groups[i])
            let ep = episode(in: s.name)
            // A different episode number rules a video out, whatever else fits.
            let noConflict = videos.indices.filter { j in
                guard let ep, let other = videoEpisodes[j] else { return true }
                return ep.agrees(other)
            }
            sameCut.append(noConflict)
            let fits = noConflict.filter { j in
                guard let d = videos[j].duration else { return true }
                return s.lastEnd <= d + 5
            }
            // Runs past the end of every video (a broadcast offset, say): length can't decide.
            let possible = fits.isEmpty ? noConflict : fits
            allowed.append(possible)
            guard !noConflict.isEmpty else { continue }
            if videos.count == 1 {
                out[s.id]?.video = videos[noConflict[0]].id
                out[s.id]?.reason = .single
                continue
            }
            // Episode, name and folder come before length: a file named for a video goes to
            // it even if its titles run past that video's end (the dialog says so). Length
            // only decides for files nothing else places.
            var candidates = noConflict
            if let ep {
                let same = noConflict.filter { videoEpisodes[$0].map(ep.sameEpisode) ?? false }
                if same.count == 1 {
                    out[s.id]?.video = videos[same[0]].id
                    out[s.id]?.reason = .episode
                    continue
                }
                if same.count > 1 { candidates = same }
            }
            let full = Set(subtitleStem(s.name))
            let stem = full.subtracting(common).isEmpty ? full : full.subtracting(common)
            let scored = candidates.map { (j: $0, score: similarity(stem, videoStems[$0])) }
                .sorted { $0.score > $1.score }
            if let best = scored.first, best.score >= 0.5,
               best.score - (scored.dropFirst().first?.score ?? 0) >= 0.2 {
                out[s.id]?.video = videos[best.j].id
                out[s.id]?.reason = .name
                continue
            }
            if let folder = s.folder {
                let here = candidates.filter { videos[$0].folder == folder }
                if here.count == 1 {
                    out[s.id]?.video = videos[here[0]].id
                    out[s.id]?.reason = .folder
                    continue
                }
            }
            if noConflict.count == 1 {
                out[s.id]?.video = videos[noConflict[0]].id
                out[s.id]?.reason = .episode
            }
        }

        // Timing: a file goes where the files timed like it went (when they all agree).
        var members: [Int: [Int]] = [:]
        for i in subs.indices { members[groups[i], default: []].append(i) }
        for list in members.values {
            let decided = Set(list.compactMap { out[subs[$0].id]?.video })
            guard decided.count == 1, let v = decided.first, let j = videos.firstIndex(where: { $0.id == v }) else { continue }
            let placed = list.filter { out[subs[$0].id]?.video != nil }
            for m in list where out[subs[m].id]?.video == nil && sameCut[m].contains(j) {
                out[subs[m].id]?.video = v
                out[subs[m].id]?.reason = .timing
                // The closest of the files already placed, for the dialog.
                let closest = placed.compactMap { k in fits[m][k].map { (k: k, fit: $0) } }.max { $0.fit.share < $1.fit.share }
                if let closest {
                    let fit = closest.fit
                    let (note, caution) = fit.describe()
                    out[subs[m].id]?.score = fit.share
                    out[subs[m].id]?.detail = "\(Int((fit.share * 100).rounded()))% of its titles start within half a second of one in \(subs[closest.k].name)" + note
                    out[subs[m].id]?.caution = caution
                }
            }
        }

        // Speech: sets of files nothing placed go to the video whose speech their titles
        // follow, when it's clearly that video and no other. One set per video.
        if !speech.isEmpty {
            var found: [(members: [Int], video: Int, fit: SpeechFit, next: Double)] = []
            for list in members.values.sorted(by: { $0[0] < $1[0] })
            where list.allSatisfy({ out[subs[$0].id]?.video == nil }) {
                // The fullest file speaks for the set.
                guard let rep = list.max(by: { subs[$0].starts.count < subs[$1].starts.count }) else { continue }
                let options = list.dropFirst().reduce(Set(allowed[list[0]])) { $0.intersection(allowed[$1]) }
                let scored = options.compactMap { j -> (j: Int, fit: SpeechFit)? in
                    guard let sp = speech[videos[j].id], let fit = speechFit(subs[rep], sp) else { return nil }
                    return (j, fit)
                }.sorted { $0.fit.score > $1.fit.score }
                guard let best = scored.first, best.fit.score >= speechMinimum else { continue }
                let next = scored.dropFirst().first?.fit.score ?? 0
                guard best.fit.score - next >= speechMargin else { continue }
                found.append((list, best.j, best.fit, next))
            }
            var heard: Set<Int> = []
            for f in found.sorted(by: { $0.fit.score > $1.fit.score }) where !heard.contains(f.video) {
                heard.insert(f.video)
                var detail = "Score " + String(format: "%.2f", f.fit.score)
                    + "; the next best video " + String(format: "%.2f", max(0, f.next))
                var caution = false
                if abs(f.fit.offset) >= 0.5 {
                    detail += "; its times are " + span(abs(f.fit.offset)) + (f.fit.offset > 0 ? " earlier" : " later")
                        + " than the speech"
                    caution = true
                }
                if f.fit.speed != 1 {
                    detail += "; \(rateNote(f.fit.speed)): its titles will drift"
                    caution = true
                }
                for m in f.members {
                    out[subs[m].id]?.video = videos[f.video].id
                    out[subs[m].id]?.reason = .speech
                    out[subs[m].id]?.score = f.fit.score
                    out[subs[m].id]?.detail = detail + "."
                    out[subs[m].id]?.caution = caution
                }
            }
        }

        // Length: groups with nothing decided go to the videos their titles fit, closest
        // fit first, one group per video where there are enough videos.
        let waiting = members.values.filter { list in list.allSatisfy { out[subs[$0].id]?.video == nil } }
            .map { list -> (members: [Int], span: Double, allowed: Set<Int>) in
                let span = list.map { subs[$0].lastEnd }.max() ?? 0
                let common = list.dropFirst().reduce(Set(allowed[list[0]])) { $0.intersection(allowed[$1]) }
                return (list, span, common)
            }
            .filter { $0.span > 0 }
            .sorted { $0.span < $1.span }
        guard !waiting.isEmpty else { return out }
        func slack(_ g: Int, _ j: Int) -> Double? {
            guard waiting[g].allowed.contains(j), let d = videos[j].duration else { return nil }
            let s = d - waiting[g].span
            // Past the end, or covering less than half of it: not this video.
            guard s >= -5, waiting[g].span >= d * 0.5 else { return nil }
            return max(0, s)
        }
        let taken = Set(out.values.compactMap(\.video))
        let free = videos.indices.filter { videos[$0].duration != nil && !taken.contains(videos[$0].id) }
            .sorted { videos[$0].duration! < videos[$1].duration! }
        var assigned: [Int: Int] = [:]   // group index → video index
        for (g, j) in orderedMatching(groups: waiting.count, videos: free, cost: { g, j in slack(g, j).map { $0 * $0 } }) {
            assigned[g] = j
        }
        // Left over (more groups than videos without titles): only a clear best fit.
        for g in waiting.indices where assigned[g] == nil {
            let fits = videos.indices.compactMap { j in slack(g, j).map { (j: j, slack: $0) } }.sorted { $0.slack < $1.slack }
            guard let best = fits.first, best.slack <= 180,
                  fits.count == 1 || fits[1].slack - best.slack >= 60 else { continue }
            assigned[g] = best.j
        }
        for (g, j) in assigned {
            for m in waiting[g].members {
                out[subs[m].id]?.video = videos[j].id
                out[subs[m].id]?.reason = .length
            }
        }
        return out
    }

    /// Pairs groups (sorted by length) with videos (sorted by length) in order, skipping
    /// either where needed: as many pairs as possible, then the closest fits. In one
    /// dimension, pairing in order is the best there is.
    static func orderedMatching(groups n: Int, videos: [Int], cost: (Int, Int) -> Double?) -> [(Int, Int)] {
        let m = videos.count
        guard n > 0, m > 0 else { return [] }
        let skip = 1e12   // leaving a group without a video costs more than any fit
        var dp = Array(repeating: Array(repeating: Double.infinity, count: m + 1), count: n + 1)
        var move = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)   // 1 skip group, 2 skip video, 3 pair
        for j in 0...m { dp[0][j] = 0; move[0][j] = 2 }
        for i in 1...n {
            dp[i][0] = Double(i) * skip
            move[i][0] = 1
            for j in 1...m {
                var best = dp[i - 1][j] + skip, how = 1
                if dp[i][j - 1] < best { best = dp[i][j - 1]; how = 2 }
                if let c = cost(i - 1, videos[j - 1]), dp[i - 1][j - 1] + c < best { best = dp[i - 1][j - 1] + c; how = 3 }
                dp[i][j] = best
                move[i][j] = how
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            switch move[i][j] {
            case 1: i -= 1
            case 2: j -= 1
            default:
                pairs.append((i - 1, videos[j - 1]))
                i -= 1
                j -= 1
            }
        }
        return pairs
    }

    // MARK: Timing

    /// Groups files that share most of their start times (translations made from one
    /// template). Returns a group number for each file.
    static func timingGroups(_ subs: [SubFile]) -> [Int] { timingLinks(subs).groups }

    /// The groups, and how each pair of files in them lines up (`fits[i][j]`: file i against
    /// file j; nil when they aren't timed alike).
    static func timingLinks(_ subs: [SubFile]) -> (groups: [Int], fits: [[TimingFit?]]) {
        var parent = Array(subs.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var fits = Array(repeating: [TimingFit?](repeating: nil, count: subs.count), count: subs.count)
        for i in subs.indices {
            for j in subs.indices where j > i {
                guard let fit = timingFit(subs[i].starts, subs[j].starts) else { continue }
                fits[i][j] = fit
                fits[j][i] = fit.inverse
                if root(i) != root(j) { parent[root(j)] = root(i) }
            }
        }
        var numbers: [Int: Int] = [:]
        let groups = subs.indices.map { i -> Int in
            let r = root(i)
            if let n = numbers[r] { return n }
            numbers[r] = numbers.count
            return numbers.count - 1
        }
        return (groups, fits)
    }

    /// How two files' timing lines up: `a` at `speed`, then moved by `offset` seconds, starts
    /// where `b` does, for `share` of the smaller file's titles.
    struct TimingFit: Sendable, Equatable {
        var share: Double
        var offset: Double
        var speed: Double

        var inverse: TimingFit { TimingFit(share: share, offset: -offset / speed, speed: 1 / speed) }

        /// Said in the dialog: an offset or another speed, and whether that's worth a look.
        func describe() -> (note: String, caution: Bool) {
            var note = "", caution = false
            if abs(offset) >= 0.5 {
                note += ", " + FileMatcher.span(abs(offset)) + (offset > 0 ? " earlier" : " later")
                caution = true
            }
            if speed != 1 {
                note += ", \(FileMatcher.rateNote(speed)): its titles will drift against this video"
                caution = true
            }
            return (note + ".", caution)
        }
    }

    /// "3.2 s", "10 h", "1 h 2.5 s".
    static func span(_ seconds: Double) -> String {
        let hours = (seconds / 3600 + 0.001).rounded(.down)
        let rest = seconds - hours * 3600
        let s = String(format: "%.1f s", rest)
        guard hours >= 1 else { return s }
        return "\(Int(hours)) h" + (rest >= 0.05 ? " " + s : "")
    }

    /// The speed changes tried: the same film at 25 and at 23.976 or 24 frames a second.
    static let speeds: [Double] = [1, 25 / 23.976, 23.976 / 25, 25 / 24, 24 / 25]

    /// "timed for 25 fps, not 23.976" for a speed from `speeds` (times at `speed` line up).
    static func rateNote(_ speed: Double) -> String {
        let pairs: [(Double, String)] = [(25 / 23.976, "timed for 25 fps, not 23.976"), (23.976 / 25, "timed for 23.976 fps, not 25"),
                                         (25 / 24, "timed for 25 fps, not 24"), (24 / 25, "timed for 24 fps, not 25")]
        return pairs.min(by: { abs($0.0 - speed) < abs($1.0 - speed) })?.1 ?? "timed for another frame rate"
    }

    /// True when the files are timed alike (see `timingFit`).
    static func sameTiming(_ a: [Double], _ b: [Double]) -> Bool { timingFit(a, b) != nil }

    /// Whether two files share their timing: at least half the titles of the smaller one
    /// start within half a second of a title in the other, well above what chance gives for
    /// files this busy. One may be moved against the other (up to 10 s either way, or by
    /// whole hours, as broadcast files start at 10:00:00) or run at another frame rate
    /// (`speeds`). Nil when they don't.
    static func timingFit(_ a: [Double], _ b: [Double]) -> TimingFit? {
        let swapped = a.count > b.count
        let (small, large) = swapped ? (b, a) : (a, b)
        guard small.count >= 5, small.count * 3 >= large.count,
              let first = large.first, let last = large.last, last > first else { return nil }
        let window = 0.5
        var best: TimingFit?
        for speed in speeds {
            let moved = small.map { $0 * speed }
            var bases: [Double] = [0]
            // Whole hours apart (a broadcast file starting at 10:00:00, say).
            let hours = ((first - moved[0]) / 3600).rounded()
            if hours != 0 { bases.append(hours * 3600) }
            for base in bases {
                let offset = bestOffset(moved, large, around: base, reach: 10)
                let share = Double(hits(moved, large, offset: offset, window: window)) / Double(small.count)
                if share > (best?.share ?? 0) { best = TimingFit(share: share, offset: offset, speed: speed) }
            }
        }
        let chance = min(1, Double(large.count) * 2 * window / (last - first))
        guard let best, best.share >= max(0.5, chance + 0.3) else { return nil }
        return swapped ? best.inverse : best
    }

    /// The shift (within `reach` of `around`, to a tenth of a second) that lines most of `a`
    /// up with `b`. Both sorted.
    static func bestOffset(_ a: [Double], _ b: [Double], around: Double, reach: Double) -> Double {
        let step = 0.1
        let bins = Int(2 * reach / step) + 1
        var counts = [Int](repeating: 0, count: bins)
        var lo = 0
        for t in a {
            let from = t + around - reach, to = t + around + reach
            while lo < b.count && b[lo] < from { lo += 1 }
            var j = lo
            while j < b.count && b[j] <= to {
                let bin = Int(((b[j] - t - around + reach) / step).rounded())
                if bin >= 0 && bin < bins { counts[bin] += 1 }
                j += 1
            }
        }
        // Counted over half a second either way, as `hits` will; then the middle of what
        // was counted there.
        var best = bins / 2, bestSum = -1
        for i in 0..<bins {
            let sum = counts[max(0, i - 5)...min(bins - 1, i + 5)].reduce(0, +)
            if sum > bestSum || (sum == bestSum && abs(i - bins / 2) < abs(best - bins / 2)) { best = i; bestSum = sum }
        }
        var center = Double(best)
        for _ in 0..<2 {
            let mid = Int(center.rounded())
            var weighted = 0.0, total = 0
            for k in max(0, mid - 5)...min(bins - 1, mid + 5) {
                weighted += Double(counts[k] * k)
                total += counts[k]
            }
            if total > 0 { center = weighted / Double(total) }
        }
        return around - reach + center * step
    }

    /// How many of `a`, moved by `offset`, start within `window` of one of `b`. Both sorted.
    static func hits(_ a: [Double], _ b: [Double], offset: Double, window: Double) -> Int {
        var j = 0, count = 0
        for t0 in a {
            let t = t0 + offset
            while j < b.count && b[j] < t - window { j += 1 }
            if j < b.count && abs(b[j] - t) <= window { count += 1 }
        }
        return count
    }

    // MARK: Speech

    /// When people speak in a video: one flag a tenth of a second, kept as running counts.
    struct Speech: Sendable {
        static let frame = 0.1
        /// `prefix[i]`: how many of the first i frames have speech.
        let prefix: [Int32]
        var frames: Int { prefix.count - 1 }

        init(active: [Bool]) {
            var p = [Int32](repeating: 0, count: active.count + 1)
            for (i, a) in active.enumerated() { p[i + 1] = p[i] + (a ? 1 : 0) }
            prefix = p
        }

        /// From the loudness of each frame in decibels (`SpeechListener`).
        init(levels: [Float]) { self.init(active: Self.detect(levels)) }

        /// The loudness of each tenth of a second of mono sound, in decibels, with the low
        /// end turned down (as `SpeechListener` hears it), from sound already in memory.
        static func levels(samples: [Int16], sampleRate: Double) -> [Float] {
            let perFrame = max(1, Int(sampleRate * frame))
            var levels: [Float] = []
            levels.reserveCapacity(samples.count / perFrame + 1)
            var sum: Float = 0, count = 0, previous: Float = 0
            samples.withUnsafeBufferPointer { buffer in
                for v in buffer {
                    let x = Float(v) / 32768
                    let y = x - 0.95 * previous
                    previous = x
                    sum += y * y
                    count += 1
                    if count == perFrame {
                        levels.append(10 * log10(sum / Float(perFrame) + 1e-12))
                        sum = 0
                        count = 0
                    }
                }
            }
            return levels
        }

        /// The stretches of speech, in seconds from the start (for the waveform's shading).
        var stretches: [ClosedRange<Double>] {
            var out: [ClosedRange<Double>] = []
            var start: Int?
            for i in 0..<frames {
                let on = prefix[i + 1] > prefix[i]
                if on, start == nil { start = i }
                if !on, let s = start {
                    out.append(Double(s) * Self.frame...Double(i) * Self.frame)
                    start = nil
                }
            }
            if let s = start { out.append(Double(s) * Self.frame...Double(frames) * Self.frame) }
            return out
        }

        /// Speech is where the sound rises well above the quiet moments around it (the
        /// quietest tenth of the 10 s around it: the pauses between words, or steady music)
        /// and above the quietest tenth of the film; pauses under 0.3 s are bridged and
        /// blips under 0.2 s dropped.
        static func detect(_ levels: [Float]) -> [Bool] {
            let n = levels.count
            guard n > 0 else { return [] }
            let quiet = levels.sorted()[Int(Double(n - 1) * 0.1)]
            let reach = 50
            var floor = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let around = levels[max(0, i - reach)...min(n - 1, i + reach)].sorted()
                floor[i] = around[Int(Double(around.count - 1) * 0.1)]
            }
            var active = (0..<n).map { levels[$0] > max(floor[$0] + 6, quiet + 9) }
            // Bridge short pauses, then drop short blips.
            var i = 0
            while i < n {
                guard !active[i] else { i += 1; continue }
                var j = i
                while j < n && !active[j] { j += 1 }
                if i > 0 && j < n && j - i <= 3 { for k in i..<j { active[k] = true } }
                i = j
            }
            i = 0
            while i < n {
                guard active[i] else { i += 1; continue }
                var j = i
                while j < n && active[j] { j += 1 }
                if j - i < 2 { for k in i..<j { active[k] = false } }
                i = j
            }
            return active
        }
    }

    /// How a file's titles line up with a video's speech: `score` is the correlation of
    /// "a title is up" with "someone speaks", tenth of a second by tenth (0: no relation),
    /// at the best `offset` and `speed`.
    struct SpeechFit: Sendable, Equatable {
        var score: Double
        var offset: Double
        var speed: Double
    }

    /// Below this, titles and speech have too little to do with each other to decide.
    static let speechMinimum = 0.15
    /// And the best video must beat the next one by this much.
    static let speechMargin = 0.07

    /// The best fit of a file's titles with a video's speech: shifted up to 2 s either way
    /// (or by whole hours), at the speeds a film is converted between.
    static func speechFit(_ file: SubFile, _ speech: Speech) -> SpeechFit? {
        let n = speech.frames
        guard n > 50, file.starts.count >= 5, let first = file.starts.first else { return nil }
        let length = Double(n) * Speech.frame
        var best: SpeechFit?
        for speed in [1, 25 / 23.976, 23.976 / 25] {
            var bases: [Double] = [0]
            if file.lastEnd * speed > length + 5 {
                let hours = (first * speed / 3600).rounded(.down)
                if hours >= 1 { bases.append(-hours * 3600) }
            }
            for base in bases {
                for k in -20...20 {
                    let offset = base + Double(k) * Speech.frame
                    guard let score = correlation(file, speech, speed: speed, offset: offset) else { continue }
                    if score > (best?.score ?? -2) { best = SpeechFit(score: score, offset: offset, speed: speed) }
                }
            }
        }
        return best
    }

    /// The correlation (phi) between the file's titles, moved, and the video's speech, over
    /// the stretch the titles cover (and 10 s either side): the credits and the silence
    /// after the last line, alike in every video, don't count.
    static func correlation(_ file: SubFile, _ speech: Speech, speed: Double, offset: Double) -> Double? {
        let n = speech.frames
        func frame(_ t: Double) -> Int { min(n, max(0, Int(((t * speed + offset) / Speech.frame).rounded()))) }
        guard let first = file.starts.first else { return nil }
        let lo = min(n, max(0, Int(((first * speed + offset - 10) / Speech.frame).rounded())))
        let hi = min(n, max(0, Int(((file.lastEnd * speed + offset + 10) / Speech.frame).rounded())))
        let all = Double(hi - lo)
        let total = Double(speech.prefix[hi] - speech.prefix[lo])
        var titled = 0.0, both = 0.0
        for i in file.starts.indices {
            let a = min(hi, max(lo, frame(file.starts[i]))), b = min(hi, max(lo, frame(file.ends[i])))
            guard b > a else { continue }
            titled += Double(b - a)
            both += Double(speech.prefix[b] - speech.prefix[a])
        }
        let spread = (titled * (all - titled) * total * (all - total)).squareRoot()
        guard titled > 0, spread > 0 else { return nil }
        return (all * both - titled * total) / spread
    }

    // MARK: Names

    /// A file name in words: lower case, without accents, split at anything not a letter or digit.
    static func words(_ name: String) -> [String] {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Words in file names that say nothing about which film it is.
    static let noise: Set<String> = [
        "480p", "576p", "720p", "1080p", "1080i", "2160p", "4k", "uhd", "hd", "sd", "hdr", "hdr10", "sdr",
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "aac", "ac3", "eac3", "dts", "ddp",
        "atmos", "flac", "mp3", "10bit", "8bit", "prores", "proxy", "dnxhd", "dnxhr",
        "bluray", "bdrip", "brrip", "webrip", "web", "webdl", "dl", "hdtv", "dvdrip", "dvd", "remux",
        "final", "finalfinal", "draft", "new", "old", "fixed", "fix", "corrected", "edit", "edited", "copy",
        "sync", "synced", "timed", "retimed", "export", "ok", "approved", "qc", "checked", "rev", "ver",
        "version", "verzija", "temp", "wip", "sdh", "cc", "hi", "forced", "full", "sub", "subs", "subtitle",
        "subtitles", "srt", "vtt", "titl", "titlovi", "titles", "prijevod", "prevod", "translation",
        "translated", "caption", "captions", "mix"
    ]

    private static func isNoise(_ word: String) -> Bool {
        if noise.contains(word) { return true }
        // v2, r3, a year, a date
        if word.count >= 2, word.count <= 3, word.first == "v" || word.first == "r",
           word.dropFirst().allSatisfy(\.isNumber) { return true }
        if word.allSatisfy(\.isNumber) {
            if word.count == 4, let y = Int(word), (1900...2099).contains(y) { return true }
            if word.count >= 6 { return true }
        }
        return false
    }

    /// Words that carry the episode number, left out of the name comparison.
    private static func isEpisodeWord(_ word: String) -> Bool {
        if episodeWords.contains(word) { return true }
        if word.allSatisfy(\.isNumber) { return word.count <= 3 }
        let patterns = ["^s\\d{1,2}e\\d{1,3}$", "^\\d{1,2}x\\d{1,3}$", "^e\\d{1,3}$", "^s\\d{1,2}$", "^ep\\d{1,3}$"]
        return patterns.contains { word.range(of: $0, options: .regularExpression) != nil }
    }

    private static let episodeWords: Set<String> = [
        "ep", "episode", "epizoda", "epizode", "folge", "odcinek", "episodio", "aflevering", "jakso",
        "afsnit", "avsnitt", "part", "pt", "dio", "del", "teil", "chapter",
        "season", "seasons", "sezona", "staffel", "saison", "temporada", "stagione", "seizoen", "sesong",
        "sasong", "kausi", "sezon", "series"
    ]

    /// A video's name, in the words that say which film it is.
    static func videoStem(_ name: String) -> [String] {
        words(name).filter { !isNoise($0) && !isEpisodeWord($0) }
    }

    /// A subtitle file's name, in the words that say which film it is: its language tag
    /// ("Film.hr", "Film_ENG", "Film croatian", "Film.pt-BR") and the extras around it go.
    static func subtitleStem(_ name: String) -> [String] {
        var w = withoutLanguageTag(words(name))
        w.removeAll { isNoise($0) || isEpisodeWord($0) }
        return w
    }

    /// The words of a subtitle file's name without the language tag at its end, and (with
    /// `leading`) a language's name at its start ("english-star-trek-…").
    static func withoutLanguageTag(_ words: [String], leading: Bool = true) -> [String] {
        var w = words
        while let last = w.last, isNoise(last) { w.removeLast() }
        let codes = Set(Language.common.map { $0.code.lowercased() })
        if w.count >= 3, codes.contains(w[w.count - 2] + "-" + w[w.count - 1]) {
            w.removeLast(2)
        } else if w.count >= 2, let last = w.last,
                  LanguageGuess.isLanguageWord(last) || (last.count == 2 && codes.contains(last)) {
            w.removeLast()
        }
        while let last = w.last, isNoise(last) { w.removeLast() }
        // Only a full name ("english", "hrvatski"), and only with two words left after it
        // ("English Patient" keeps its first word).
        if leading, w.count >= 3, LanguageGuess.names[w[0]] != nil { w.removeFirst() }
        return w
    }

    /// How alike a subtitle file's name is to a video's: the share of the video's words in
    /// the file's name and of the file's words in the video's, averaged (1 = the same words).
    static func similarity(_ sub: Set<String>, _ video: Set<String>) -> Double {
        guard !sub.isEmpty, !video.isEmpty else { return 0 }
        let shared = Double(sub.intersection(video).count)
        return (shared / Double(video.count) + shared / Double(sub.count)) / 2
    }

    /// Each video's words without the ones every video has (a series' title, "the"): only
    /// what tells them apart counts. A video left with nothing keeps all its words.
    static func distinctive(_ stems: [Set<String>]) -> (stems: [Set<String>], common: Set<String>) {
        guard stems.count > 1, let first = stems.first else { return (stems, []) }
        let common = stems.dropFirst().reduce(first) { $0.intersection($1) }
        return (stems.map { $0.subtracting(common).isEmpty ? $0 : $0.subtracting(common) }, common)
    }

    // MARK: Episodes

    struct Episode: Equatable, Sendable {
        var season: Int?
        /// Nil when only the season is named ("Show - Season 4 - Brothers").
        var number: Int?

        /// Nothing contradicts: no different episode number, no different season.
        func agrees(_ other: Episode) -> Bool {
            if let a = number, let b = other.number, a != b { return false }
            if let a = season, let b = other.season, a != b { return false }
            return true
        }

        /// The same episode number on both, in no different season.
        func sameEpisode(_ other: Episode) -> Bool {
            number != nil && number == other.number && agrees(other)
        }
    }

    private static let episodeWordPattern =
        "(?:ep|episode|epizoda|epizode|folge|odcinek|episodio|aflevering|jakso|afsnit|avsnitt|part|pt|dio|del|teil|chapter)"
    private static let seasonWordPattern =
        "(?:season|seasons|sezona|staffel|saison|temporada|stagione|seizoen|sesong|sasong|kausi|sezon|series)"

    /// The episode a name gives: S01E03, 1x03, "Ep 3", "Episode.3", "Epizoda 03",
    /// "3. epizoda", E03, or a lone one-to-three-digit number ("Show 03"). "Season 4" (or
    /// Sezona, Staffel…) is the season, never the episode.
    static func episode(in name: String) -> Episode? {
        var n = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        func groups(_ pattern: String, removing: Bool = false) -> [Int?]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) else { return nil }
            let found: [Int?] = (1..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: n).flatMap { Int(n[$0]) }
            }
            if removing, let r = Range(m.range, in: n) { n.replaceSubrange(r, with: " ") }
            return found
        }
        if let g = groups("(?<![a-z0-9])s(\\d{1,2})[ ._-]*e(\\d{1,3})(?![0-9])"), let e = g[1] {
            return Episode(season: g[0], number: e)
        }
        if let g = groups("(?<![a-z0-9])(\\d{1,2})x(\\d{1,3})(?![0-9])"), let e = g[1] {
            return Episode(season: g[0], number: e)
        }
        // The season, taken out so its number isn't read as the episode's.
        var season: Int?
        if let g = groups("(?<![a-z])\(seasonWordPattern)[ ._-]*(\\d{1,2})(?![0-9])", removing: true) {
            season = g[0]
        } else if let g = groups("(?<![a-z0-9])s(\\d{1,2})(?![0-9a-z])", removing: true) {
            season = g[0]
        }
        let word = episodeWordPattern
        if let g = groups("(?<![a-z])\(word)[ ._-]*(\\d{1,3})(?![0-9])"), let e = g[0] {
            return Episode(season: season, number: e)
        }
        if let g = groups("(?<![0-9])(\\d{1,3})[ ._-]*\(word)(?![a-z])"), let e = g[0] {
            return Episode(season: season, number: e)
        }
        if let g = groups("(?<![a-z0-9])e(\\d{1,3})(?![0-9])"), let e = g[0] {
            return Episode(season: season, number: e)
        }
        // A lone number, not a picture size (480, 576, 720).
        let numbers = words(n).filter { $0.allSatisfy(\.isNumber) && $0.count <= 3 && !["480", "576", "720"].contains($0) }
        if numbers.count == 1, let e = Int(numbers[0]) { return Episode(season: season, number: e) }
        return season.map { Episode(season: $0, number: nil) }
    }

    // MARK: Project names

    /// What a set of names has in common at the start, cut at a whole word ("Show.S01E01",
    /// "Show.S01E02" → "Show"). Nil when that leaves fewer than three letters.
    static func commonName(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        var prefix = first
        for n in names.dropFirst() {
            prefix = String(prefix.commonPrefix(with: n, options: .caseInsensitive))
        }
        if prefix.count < first.count, let lastChar = prefix.last, lastChar.isLetter || lastChar.isNumber {
            let next = first[first.index(first.startIndex, offsetBy: prefix.count)]
            if next.isLetter || next.isNumber {
                // Cut back to the end of the last whole word.
                while let c = prefix.last, c.isLetter || c.isNumber { prefix.removeLast() }
            }
        }
        let separators = CharacterSet(charactersIn: " ._-–—([,")
        var trimmed = prefix.trimmingCharacters(in: separators)
        // "Show.Season.4.Episode" → "Show.Season.4": the word before the differing numbers goes.
        while let range = trimmed.range(of: "[A-Za-z]+$", options: .regularExpression),
              episodeOnlyWords.contains(trimmed[range].lowercased()) {
            trimmed = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: separators)
        }
        return trimmed.filter(\.isLetter).count >= 3 ? trimmed : nil
    }

    /// Words that only name an episode (not a season): dropped from the end of a common name.
    private static let episodeOnlyWords: Set<String> = [
        "ep", "episode", "epizoda", "epizode", "folge", "odcinek", "episodio", "aflevering", "jakso",
        "afsnit", "avsnitt", "part", "pt", "dio", "del", "teil", "chapter", "e"
    ]

    /// A name with dots or underscores for spaces, written with spaces ("Star.trek.season.4"
    /// → "Star trek season 4"). A name that already has spaces is kept as it is.
    static func readable(_ name: String) -> String {
        guard !name.contains(" "), name.contains(".") || name.contains("_") else { return name }
        return name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// A subtitle file's name without its language tag, keeping its own spelling
    /// ("Show.S01E02.en" → "Show.S01E02"): a name for a video that has no file yet.
    static func displayStem(_ name: String) -> String {
        let keep = withoutLanguageTag(words(name), leading: false).count
        guard keep > 0 else { return name }
        // Walk the original name to the end of its `keep`-th word.
        var count = 0, inWord = false
        var end = name.endIndex
        for i in name.indices {
            let isWord = name[i].isLetter || name[i].isNumber
            if isWord && !inWord {
                count += 1
                if count > keep { end = i; break }
            }
            inWord = isWord
        }
        let cut = String(name[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " ._-–—([,"))
        return cut.isEmpty ? name : cut
    }
}
