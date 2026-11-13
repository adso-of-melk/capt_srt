import Foundation
import AppKit

/// Spell check: project words, learning, and going from one misspelling to the next.
extension AppModel {

    /// The project's own words go to the spell checker (after opening or changing settings).
    func syncSpellingWords() {
        let words = project?.settings.spellingWords ?? [:]
        SpellService.shared.projectWords = words.mapValues { Set($0) }
        bump()
    }

    /// "Add to Project Words": right in this project only (names, places, made-up words).
    func addProjectWord(_ word: String, language code: String) {
        guard let project, !word.isEmpty else { return }
        var words = project.settings.spellingWords[code] ?? []
        guard !words.contains(word) else { return }
        words.append(word)
        words.sort()
        project.settings.spellingWords[code] = words
        syncSpellingWords()
        scheduleAutosave()
    }

    /// Language Options: a project word that shouldn't be there after all.
    func removeProjectWord(_ word: String, language code: String) {
        guard let project, var words = project.settings.spellingWords[code], words.contains(word) else { return }
        words.removeAll { $0 == word }
        project.settings.spellingWords[code] = words.isEmpty ? nil : words
        syncSpellingWords()
        scheduleAutosave()
    }

    /// "Learn Spelling": right in every project, from now on.
    func learnWord(_ word: String, language code: String) {
        SpellService.shared.learn(word, language: code)
        bump()
    }

    /// What spell check can do for a language, said plainly.
    func spellingNote(for language: Language) -> String? {
        if SpellService.shared.hasDictionary(for: language.code) { return nil }
        let base = language.code.split(separator: "-").first.map(String.init) ?? language.code
        if ["ja", "zh", "ko"].contains(base) { return "\(language.name) has no spell check." }
        return "No \(language.name) dictionary yet: add \(language.code).aff and \(language.code).dic to the Dictionaries folder (Edit ▸ Show Dictionaries Folder)."
    }

    /// One line for the language menu: which dictionary checks this language.
    func spellingStatus(for language: Language) -> String {
        switch SpellService.shared.engine(for: language.code) {
        case .system?: return "Spelling: Mac dictionary"
        case .hunspell?: return "Spelling: downloaded dictionary"
        case nil:
            let base = language.code.split(separator: "-").first.map(String.init) ?? language.code
            return ["ja", "zh", "ko"].contains(base) ? "Spelling: not checked (\(language.name))" : "Spelling: no dictionary yet"
        }
    }

    /// ⌘; : the next title (after the selected one) with a misspelled word in the focused
    /// language, wrapping round to the start.
    @discardableResult
    func nextMisspelling() -> UUID? {
        guard let track = focusedTrack else { return nil }
        if !track.spellCheck {
            flash("Spell check is off for \(track.language.name) (Language Options).")
            return nil
        }
        if let note = spellingNote(for: track.language) {
            flash(note)
            return nil
        }
        let subs = track.doc.subtitles
        guard !subs.isEmpty else { return nil }
        let startIndex = doc.selectedID.flatMap { id in subs.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        let spell = SpellService.shared
        for k in 0..<subs.count {
            let s = subs[(startIndex + k) % subs.count]
            let plain = Markup.plain(s.text)
            if let r = spell.misspelled(in: plain, language: track.language.code).first {
                select(s.id, seekToStart: true)
                cardScrollTarget = s.id
                flash("Not in the dictionary: “\((plain as NSString).substring(with: r))”. Right-click it for suggestions.")
                return s.id
            }
        }
        flash("No misspellings in \(track.language.name).")
        return nil
    }

    func showDictionariesFolder() {
        let folder = SpellService.dictionariesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// New dictionary files were added: look again.
    func reloadDictionaries() {
        SpellService.shared.reloadDictionaries()
        bump()
        flash("Dictionaries reloaded.")
    }
}
