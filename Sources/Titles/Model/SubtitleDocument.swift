import Foundation
import Combine

/// The list of titles, always kept sorted by start time, with undo/redo.
///
/// Two kinds of change:
/// - `perform` makes one undoable change (optionally coalesced, e.g. typing).
/// - `beginLive` / `live` / `commitLive` are for continuous gestures (drags, jogs,
///   spotting): many updates, one undo step, and `cancelLive` restores the original.
@MainActor
final class SubtitleDocument: ObservableObject {
    @Published private(set) var subtitles: [Subtitle] = [] {
        didSet { if subtitles != oldValue { onChange?() } }
    }
    /// Called after any change to the titles (edits, undo, live gestures, sync).
    var onChange: (() -> Void)?
    /// Called when a new undo step is recorded (not for undo/redo themselves), so the
    /// project can keep one undo history across all languages.
    var onUndoStep: (() -> Void)?
    @Published var selectedID: UUID?
    /// The playhead time, so a lost selection (after undo or delete) can fall back to the
    /// title just before the playhead rather than the first title.
    var playheadTime: (() -> Double)?
    @Published private(set) var isDirty = false

    private var undoStack: [[Subtitle]] = []
    private var redoStack: [[Subtitle]] = []
    private var lastCoalesceKey: String?
    private var liveSnapshot: [Subtitle]?
    private let undoLimit = 500

    // MARK: Lookup

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return subtitles.firstIndex { $0.id == id }
    }

    func subtitle(_ id: UUID?) -> Subtitle? {
        index(of: id).map { subtitles[$0] }
    }

    /// 1-based number, identical in the card list and on the timeline.
    func number(of id: UUID) -> Int? {
        index(of: id).map { $0 + 1 }
    }

    var selected: Subtitle? { subtitle(selectedID) }

    func previous(of id: UUID) -> Subtitle? {
        guard let i = index(of: id), i > 0 else { return nil }
        return subtitles[i - 1]
    }

    func next(of id: UUID) -> Subtitle? {
        guard let i = index(of: id), i + 1 < subtitles.count else { return nil }
        return subtitles[i + 1]
    }

    /// The title showing at time `t` (the latest-starting one if several overlap).
    func active(at t: Double) -> Subtitle? {
        subtitles.last { $0.start <= t && t < $0.end }
    }

    /// IDs of titles that overlap a neighbour.
    var overlappingIDs: Set<UUID> {
        var result = Set<UUID>()
        var maxEnd = -Double.infinity
        var maxEndID: UUID?
        for s in subtitles {
            if s.start < maxEnd - 0.0005, let other = maxEndID {
                result.insert(s.id)
                result.insert(other)
            }
            if s.end > maxEnd {
                maxEnd = s.end
                maxEndID = s.id
            }
        }
        return result
    }

    // MARK: Whole-document

    func replaceAll(_ subs: [Subtitle]) {
        subtitles = subs.sorted { $0.start < $1.start }
        undoStack.removeAll()
        redoStack.removeAll()
        liveSnapshot = nil
        lastCoalesceKey = nil
        selectedID = subtitles.first?.id
        isDirty = false
    }

    func markSaved() { isDirty = false }

    /// Replaces the titles without an undo step (locked languages following their master).
    func syncReplace(_ subs: [Subtitle]) {
        let sorted = subs.sorted { $0.start < $1.start }
        guard sorted != subtitles else { return }
        subtitles = sorted
        fixSelection()
    }

    // MARK: Undoable changes

    func perform(coalesce key: String? = nil, _ change: (inout [Subtitle]) -> Void) {
        commitLive()
        let before = subtitles
        var working = subtitles
        change(&working)
        working.sort { $0.start < $1.start }
        guard working != before else { return }
        if key == nil || key != lastCoalesceKey {
            pushUndo(before)
        }
        lastCoalesceKey = key
        redoStack.removeAll()
        subtitles = working
        isDirty = true
        fixSelection()
    }

    @discardableResult
    func add(start: Double, end: Double, text: String = "", link: UUID? = nil, select: Bool = true) -> UUID {
        let s = Subtitle(start: start, end: max(end, start + 0.1), text: text, link: link)
        perform { $0.append(s) }
        if select { selectedID = s.id }
        return s.id
    }

    func setText(_ id: UUID, _ text: String) {
        guard let i = index(of: id), subtitles[i].text != text else { return }
        perform(coalesce: "text-\(id.uuidString)") { subs in
            if let j = subs.firstIndex(where: { $0.id == id }) { subs[j].text = text }
        }
    }

    func update(_ id: UUID, _ mutate: @escaping (inout Subtitle) -> Void) {
        perform { subs in
            if let j = subs.firstIndex(where: { $0.id == id }) { mutate(&subs[j]) }
        }
    }

    func delete(_ id: UUID) {
        let next = self.next(of: id)?.id ?? previous(of: id)?.id
        perform { $0.removeAll { $0.id == id } }
        selectedID = next
    }

    // MARK: Live (gesture) changes

    var isLive: Bool { liveSnapshot != nil }

    func beginLive() {
        if liveSnapshot == nil {
            liveSnapshot = subtitles
            lastCoalesceKey = nil
        }
    }

    func live(_ change: (inout [Subtitle]) -> Void) {
        beginLive()
        var working = subtitles
        change(&working)
        working.sort { $0.start < $1.start }
        subtitles = working
    }

    func liveUpdate(_ id: UUID, _ mutate: (inout Subtitle) -> Void) {
        live { subs in
            if let j = subs.firstIndex(where: { $0.id == id }) { mutate(&subs[j]) }
        }
    }

    func commitLive() {
        guard let snapshot = liveSnapshot else { return }
        liveSnapshot = nil
        if snapshot != subtitles {
            pushUndo(snapshot)
            redoStack.removeAll()
            isDirty = true
        }
        fixSelection()
    }

    func cancelLive() {
        guard let snapshot = liveSnapshot else { return }
        liveSnapshot = nil
        subtitles = snapshot
        fixSelection()
    }

    // MARK: Undo / redo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        commitLive()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(subtitles)
        subtitles = prev
        lastCoalesceKey = nil
        isDirty = true
        fixSelection()
    }

    func redo() {
        commitLive()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(subtitles)
        subtitles = next
        lastCoalesceKey = nil
        isDirty = true
        fixSelection()
    }

    private func pushUndo(_ state: [Subtitle]) {
        onUndoStep?()
        undoStack.append(state)
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
    }

    private func fixSelection() {
        if let id = selectedID, index(of: id) == nil {
            let t = playheadTime?() ?? 0
            selectedID = (subtitles.last(where: { $0.start <= t + 0.001 }) ?? subtitles.first)?.id
        }
    }
}
