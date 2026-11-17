import Foundation

/// Dropping a mix of videos and subtitle files: works out which video each subtitle file
/// belongs to. In order of trust:
///  1. Episode: S01E03, 1x03, "Ep 3", "Epizoda 3" or a lone number in both names, and the same.
///     Different episode numbers are never matched.
///  2. Name: the subtitle file's name without its language tag and without the usual extras
///     (final, v2, SDH, 1080p, x264, a year) compared word by word with the video's.
///  3. Folder: the only video in the subtitle file's folder.
///  4. Timing: translations of one film share most of their start times, so a file timed like
///     a file already matched goes with it.
///  5. Length: what's still open goes to the video whose length its titles fit. A subtitle
///     file whose titles run past a video's end never belongs to that video.
/// Pure and quick: the dialog shows each match's reason and everything can be moved.
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
        /// When its last title ends.
        let lastEnd: Double

        init(id: UUID = UUID(), name: String, folder: String? = nil, subtitles: [Subtitle]) {
            self.id = id
            self.name = name
            self.folder = folder
            starts = subtitles.map(\.start).sorted()
            lastEnd = subtitles.map(\.end).max() ?? 0
        }
    }

    enum Reason: String, Sendable, Equatable, CaseIterable {
        case episode, name, folder, timing, length, single, moved

        /// The word on the chip in the dialog (nil: no chip).
        var chip: String? {
            switch self {
            case .episode: return "EPISODE"
            case .name: return "NAME"
            case .folder: return "FOLDER"
            case .timing: return "TIMING"
            case .length: return "LENGTH"
            case .single, .moved: return nil
            }
        }

        var explanation: String {
            switch self {
            case .episode: return "Same episode number as the video"
            case .name: return "Its name matches the video's"
            case .folder: return "The only video in its folder"
            case .timing: return "Timed like the other files matched to this video"
            case .length: return "A guess: its titles fit this video's length. Check it."
            case .single: return "The only video"
            case .moved: return "Moved here by you"
            }
        }

        /// Less certain: shown in a warning colour.
        var isGuess: Bool { self == .length }
    }

    struct Match: Sendable, Equatable {
        var video: UUID?
        var reason: Reason?
        /// Files timed alike share a group (translations of the same cut).
        var group: Int
    }

    // MARK: Matching

    static func match(videos: [Video], subs: [SubFile]) -> [UUID: Match] {
        let (videoStems, common) = distinctive(videos.map { Set(videoStem($0.name)) })
        let videoEpisodes = videos.map { episode(in: $0.name) }
        let groups = timingGroups(subs)
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
            for m in list where out[subs[m].id]?.video == nil && sameCut[m].contains(j) {
                out[subs[m].id]?.video = v
                out[subs[m].id]?.reason = .timing
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
    static func timingGroups(_ subs: [SubFile]) -> [Int] {
        var parent = Array(subs.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in subs.indices {
            for j in subs.indices where j > i && root(i) != root(j) {
                if sameTiming(subs[i].starts, subs[j].starts) { parent[root(j)] = root(i) }
            }
        }
        var numbers: [Int: Int] = [:]
        return subs.indices.map { i in
            let r = root(i)
            if let n = numbers[r] { return n }
            numbers[r] = numbers.count
            return numbers.count - 1
        }
    }

    /// True when at least half the titles of the smaller file start within a quarter second
    /// of a title in the other, well above what chance gives for files this busy.
    static func sameTiming(_ a: [Double], _ b: [Double]) -> Bool {
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        guard small.count >= 5, small.count * 3 >= large.count,
              let first = large.first, let last = large.last else { return false }
        let window = 0.25
        var j = 0, hits = 0
        for t in small {
            while j < large.count && large[j] < t - window { j += 1 }
            if j < large.count && abs(large[j] - t) <= window { hits += 1 }
        }
        let share = Double(hits) / Double(small.count)
        let chance = min(1, Double(large.count) * 2 * window / max(1, last - first))
        return share >= max(0.5, chance + 0.3)
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
