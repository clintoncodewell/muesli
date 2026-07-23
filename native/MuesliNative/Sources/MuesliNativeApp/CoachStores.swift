import Foundation

// Fork-owned (Cue coach port). Observable stores backing the coach overlay.

/// Coaching cues shown in the overlay (most recent last). Written by id so a
/// superseded generation can never scribble onto a newer cue.
@MainActor
final class CoachCueStore: ObservableObject {
    struct Cue: Identifiable {
        let id = UUID()
        var text: String
        var streaming: Bool
        let at = Date()
    }

    @Published private(set) var cues: [Cue] = []
    @Published private(set) var thinking = false
    @Published private(set) var revision = 0
    private let keep = 50

    func begin() -> UUID {
        if let i = cues.indices.last, cues[i].streaming {
            if cues[i].text.isEmpty { cues.remove(at: i) } else { cues[i].streaming = false }
        }
        let cue = Cue(text: "", streaming: true)
        cues.append(cue)
        trim()
        thinking = true
        return cue.id
    }

    func replaceLast() -> UUID {
        guard let i = cues.indices.last else { return begin() }
        cues[i].streaming = true
        thinking = true
        return cues[i].id
    }

    func stream(_ id: UUID, _ text: String) {
        guard !text.isEmpty, let i = cues.firstIndex(where: { $0.id == id }) else { return }
        if cues[i].text.isEmpty { revision += 1 }
        cues[i].text = text
    }

    func finish(_ id: UUID, _ text: String) {
        thinking = false
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            cues[i].text = clean
            cues[i].streaming = false
        } else if cues[i].text.isEmpty {
            cues.remove(at: i)
        } else {
            cues[i].streaming = false
        }
    }

    func fail(_ id: UUID?, _ message: String) {
        thinking = false
        if let id, let i = cues.firstIndex(where: { $0.id == id }) {
            cues[i].text = "⚠︎ \(message)"
            cues[i].streaming = false
        } else {
            cues.append(Cue(text: "⚠︎ \(message)", streaming: false))
            trim()
        }
    }

    var latest: String { cues.last?.text ?? "" }

    func stopThinking() { thinking = false }
    func reset() { cues.removeAll(); thinking = false }
    private func trim() { if cues.count > keep { cues.removeFirst(cues.count - keep) } }
}

/// Running meeting summary, regenerated on an interval and once at session end.
@MainActor
final class CoachSummaryStore: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var updating = false
    @Published private(set) var updatedAt: Date?

    func begin() { updating = true }
    func stream(_ t: String) { text = t }
    func done(_ t: String) {
        let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { text = clean }
        updating = false
        updatedAt = Date()
    }
    func fail() { updating = false }
    func reset() { text = ""; updating = false; updatedAt = nil }
}
