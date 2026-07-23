import Foundation

// Fork-owned (Cue coach port). The running transcript the coach reads from, fed by
// Muesli's meeting You/Others streams via CoachController.

enum CoachSpeaker: String, Sendable {
    case them, you
    var label: String { self == .them ? "Them" : "You" }
}

struct CoachTranscriptSegment: Identifiable, Sendable {
    let id = UUID()
    let speaker: CoachSpeaker
    var text: String
    let at: Date
}

@MainActor
final class CoachTranscriptStore: ObservableObject {
    @Published private(set) var committed: [CoachTranscriptSegment] = []
    @Published private(set) var volatile: [CoachSpeaker: String] = [:]
    /// Wall-clock of the last update (any speaker). Coach uses it to detect a pause.
    private(set) var lastUpdateAt = Date()
    /// Monotonic counts — the coach's new-input signal, immune to history capping.
    private(set) var themFinalCount = 0
    private(set) var youFinalCount = 0
    private let maxCommitted = 400

    func update(speaker: CoachSpeaker, text: String, isFinal: Bool) {
        lastUpdateAt = Date()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !clean.isEmpty {
                committed.append(CoachTranscriptSegment(speaker: speaker, text: clean, at: Date()))
                if speaker == .them { themFinalCount += 1 } else { youFinalCount += 1 }
                if committed.count > maxCommitted { committed.removeFirst(committed.count - maxCommitted) }
            }
            volatile[speaker] = nil
        } else {
            volatile[speaker] = clean
        }
    }

    func reset() {
        committed.removeAll()
        volatile.removeAll()
        lastUpdateAt = Date()
        themFinalCount = 0
        youFinalCount = 0
    }

    func rendered(limit: Int = 12) -> String {
        var lines = committed.suffix(limit).map { "\($0.speaker.label): \($0.text)" }
        for speaker in [CoachSpeaker.them, .you] {
            if let tail = volatile[speaker], !tail.isEmpty { lines.append("\(speaker.label): \(tail)…") }
        }
        return lines.joined(separator: "\n")
    }
}
