import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("CoachEngine")
struct CoachEngineTests {
    @Test("split parses a full SAY/MOVE reply")
    func splitFull() {
        let (say, move) = CoachEngine.split("SAY: Ask about their timeline.\nMOVE: They're stalling — probe budget.")
        #expect(say == "Ask about their timeline.")
        #expect(move == "They're stalling — probe budget.")
    }

    @Test("split tolerates a still-streaming reply with no MOVE yet")
    func splitPartial() {
        let (say, move) = CoachEngine.split("SAY: Let me confirm the sc")
        #expect(say == "Let me confirm the sc")
        #expect(move == "")
    }

    @Test("split is case-insensitive on the MOVE label")
    func splitCaseInsensitive() {
        let (say, move) = CoachEngine.split("say: hi\nmove: steer to close")
        #expect(say == "hi")
        #expect(move == "steer to close")
    }
}

@Suite("CoachTranscriptStore")
struct CoachTranscriptStoreTests {
    @MainActor
    @Test("final segments bump per-speaker counts; volatile does not")
    func counts() {
        let t = CoachTranscriptStore()
        t.update(speaker: .them, text: "hello", isFinal: true)
        t.update(speaker: .you, text: "hi there", isFinal: true)
        t.update(speaker: .them, text: "partial…", isFinal: false)
        #expect(t.themFinalCount == 1)
        #expect(t.youFinalCount == 1)
        #expect(t.rendered().contains("Them: hello"))
        #expect(t.rendered().contains("Them: partial……") || t.rendered().contains("Them: partial…"))
    }
}
