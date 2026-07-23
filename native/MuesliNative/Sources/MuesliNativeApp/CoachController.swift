import Foundation
import os

// Fork-owned (Cue coach port). The bridge Grok asked for: it owns the coach's lifecycle,
// transcript store, engine, and overlay, and it is the ONLY thing the hot meeting path
// touches (a couple of ingest calls). Nothing here runs unless coach_enabled is set in
// fork-config.json, so default builds are completely unaffected.
@MainActor
final class CoachController {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "Coach")

    private let transcript = CoachTranscriptStore()
    private let overlay = CoachOverlayController()
    private lazy var engine = CoachEngine(transcript: transcript) { CoachSettings.load() }
    private var active = false

    /// True only when the coach is switched on in fork-config.json. Cheap file read.
    static func isEnabled() -> Bool { CoachSettings.enabled() }

    /// Start coaching for a new meeting. Safe to call when disabled (no-op).
    func begin() {
        guard CoachSettings.isEnabledWithValidModel() else {
            Self.logger.notice("coach: begin skipped (disabled or no model configured)")
            return
        }
        guard !active else { return }
        active = true
        transcript.reset()
        engine.setActive(true)
        overlay.show(say: engine.say, move: engine.move)
        Self.logger.notice("coach: started")
    }

    /// Feed a finalized transcript chunk. speaker is Muesli's "You" / "Others".
    func ingestFinal(speaker: String, text: String) {
        guard active else { return }
        transcript.update(speaker: mapSpeaker(speaker), text: text, isFinal: true)
    }

    /// Feed a volatile partial tail (freshness / pause detection).
    func ingestPartial(speaker: String, tail: String) {
        guard active else { return }
        transcript.update(speaker: mapSpeaker(speaker), text: tail, isFinal: false)
    }

    /// Stop coaching and tear down the overlay. Safe to call unconditionally.
    func end() {
        guard active else { return }
        active = false
        engine.setActive(false)   // fires one last summary, cancels in-flight
        overlay.hide()
        Self.logger.notice("coach: stopped")
    }

    private func mapSpeaker(_ s: String) -> CoachSpeaker {
        s == "You" ? .you : .them
    }
}

extension CoachSettings {
    /// Enabled AND a usable model/key are configured — otherwise the coach can't do anything.
    static func isEnabledWithValidModel() -> Bool { load() != nil }
}
