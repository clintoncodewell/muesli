import Foundation
import os

// Fork-owned (Cue coach port). Turns the live transcript into SAY (exact words to speak)
// + MOVE (strategy) per turn: one streamed LLM call, deterministic trigger, abort-on-supersede.

@MainActor
final class CoachEngine {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "Coach")

    let say = CoachCueStore()
    let move = CoachCueStore()
    let summary = CoachSummaryStore()

    private let transcript: CoachTranscriptStore
    private let makeConfig: () -> CoachConfig?

    private var timer: Timer?
    private var summaryTimer: Timer?
    private var streamTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var lastCueAt = Date.distantPast
    private var lastSeenThem = 0
    private var pendingThem = false
    private var pendingSince = Date.distantPast
    private var lastSeenYou = 0
    private var cooldown: Double = 15
    private var silence: Double = 1.8
    private let maxHold: Double = 8

    init(transcript: CoachTranscriptStore, makeConfig: @escaping () -> CoachConfig?) {
        self.transcript = transcript
        self.makeConfig = makeConfig
    }

    func setActive(_ active: Bool) {
        timer?.invalidate(); timer = nil
        summaryTimer?.invalidate(); summaryTimer = nil
        streamTask?.cancel()
        say.stopThinking(); move.stopThinking()
        guard active else {
            generateSummary()
            return
        }
        reset()

        if let cfg = makeConfig() { cooldown = cfg.cooldown; silence = cfg.silence }

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let minutes = max(1, makeConfig()?.summaryInterval ?? 5)
        let summaryTimer = Timer(timeInterval: minutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.generateSummary() }
        }
        RunLoop.main.add(summaryTimer, forMode: .common)
        self.summaryTimer = summaryTimer
    }

    func reset() {
        streamTask?.cancel()
        summaryTask?.cancel()
        say.reset(); move.reset(); summary.reset()
        lastSeenThem = transcript.themFinalCount
        lastSeenYou = transcript.youFinalCount
        lastCueAt = .distantPast
        pendingThem = false
        pendingSince = .distantPast
    }

    func coachNow() {
        lastCueAt = Date()
        pendingThem = false
        generate(userContent: transcriptWindow())
    }

    // MARK: - Trigger

    private func tick() {
        let now = Date()
        let themCount = transcript.themFinalCount
        if themCount > lastSeenThem {
            if !pendingThem { pendingSince = now }
            pendingThem = true
            lastSeenThem = themCount
        }
        let paused = now.timeIntervalSince(transcript.lastUpdateAt) >= silence
        let held = now.timeIntervalSince(pendingSince) >= maxHold
        if pendingThem, now.timeIntervalSince(lastCueAt) >= cooldown, paused || held {
            pendingThem = false
            lastCueAt = now
            let iSpoke = transcript.youFinalCount != lastSeenYou
            lastSeenYou = transcript.youFinalCount
            generate(userContent: transcriptWindow(), replace: !iSpoke)
        }
    }

    private func transcriptWindow() -> String {
        let window = transcript.rendered(limit: 24)
        return "Live meeting transcript (most recent):\n\(window.isEmpty ? "(no speech yet)" : window)\n\nCoach me now."
    }

    // MARK: - Generation

    private func generate(userContent: String, replace: Bool = false) {
        guard let cfg = makeConfig() else { say.fail(nil, "No model set — configure the coach in fork-config.json"); return }
        cooldown = cfg.cooldown; silence = cfg.silence
        guard !cfg.apiKey.isEmpty else { say.fail(nil, "No API key for the coach model"); return }

        var system = cfg.systemPrompt
        if !cfg.globalPrompt.isEmpty { system = cfg.globalPrompt + "\n\n" + system }
        if cfg.micOff { system += "\n\nNOTE: my microphone is currently OFF, so my own spoken replies do NOT appear as \"You\" in the transcript. Don't assume I've answered; if I clearly should be responding, say so and give me the words." }
        if !cfg.context.isEmpty { system += "\n\n# Context I've noted for this meeting (use it)\n\(cfg.context)" }
        if !cfg.knowledge.isEmpty { system += "\n\n# Reference (use only when relevant)\n\(cfg.knowledge)" }
        if cfg.humanize { system += "\n\n" + Self.humanizeInstruction }
        if let rule = cfg.cueLength.promptRule { system += "\n\n" + rule }
        system += """


        Answer in EXACTLY this format and nothing else, with the SAY: and MOVE: labels each starting \
        their own line (the persona prompt above decides the style and length of each — follow it):
        SAY: <what I should say next>
        MOVE: <what's going on and where to steer next>
        """
        let messages = [
            CoachChatMessage(role: "system", content: system),
            CoachChatMessage(role: "user", content: userContent),
        ]
        let client = CoachLLMClient(baseURL: cfg.baseURL, model: cfg.model, apiKey: cfg.apiKey,
                                    temperature: cfg.temperature, seed: cfg.seed, reasoningEffort: cfg.reasoningEffort)
        streamTask?.cancel()
        let sayID = replace ? say.replaceLast() : say.begin()
        let moveID = replace ? move.replaceLast() : move.begin()
        streamTask = Task {
            var text = ""
            do {
                for try await token in client.stream(messages) {
                    if Task.isCancelled { return }
                    text += token
                    let (s, m) = Self.split(text)
                    say.stream(sayID, s)
                    move.stream(moveID, m)
                }
                if Task.isCancelled { return }
                let (s, m) = Self.split(text)
                if s.isEmpty && m.isEmpty { Self.logger.notice("coach: empty reply (kept previous)") }
                say.finish(sayID, s)
                move.finish(moveID, m)
            } catch is CancellationError {
            } catch {
                Self.logger.error("coach: error \(error.localizedDescription, privacy: .public)")
                say.fail(sayID, error.localizedDescription)
                move.finish(moveID, "")
            }
        }
    }

    private func generateSummary() {
        guard let cfg = makeConfig(), !cfg.apiKey.isEmpty else { return }
        let transcriptText = transcript.rendered(limit: 400)
        guard !transcriptText.isEmpty else { return }
        var system = [cfg.globalPrompt, cfg.summaryPrompt].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !cfg.context.isEmpty { system += "\n\n# Meeting context\n\(cfg.context)" }
        let messages = [
            CoachChatMessage(role: "system", content: system),
            CoachChatMessage(role: "user", content: "Meeting transcript so far:\n\(transcriptText)\n\nUpdate the running summary."),
        ]
        let client = CoachLLMClient(baseURL: cfg.baseURL, model: cfg.model, apiKey: cfg.apiKey,
                                    temperature: cfg.temperature, seed: cfg.seed)
        summaryTask?.cancel()
        summary.begin()
        summaryTask = Task {
            var text = ""
            do {
                for try await token in client.stream(messages) {
                    if Task.isCancelled { return }
                    text += token
                    summary.stream(text)
                }
                if !Task.isCancelled { summary.done(text) }
            } catch is CancellationError {
            } catch {
                Self.logger.error("coach summary: \(error.localizedDescription, privacy: .public)")
                summary.fail()
            }
        }
    }

    static let humanizeInstruction = """
    Sound like a real person speaking, not an AI. Plain, natural spoken English. Avoid AI-tell words \
    and phrases: delve, leverage, robust, seamless, navigate, tapestry, testament, realm, foster, \
    underscore, pivotal, crucial, elevate, embark, unlock, harness, resonate, meticulous, "it's not \
    just X, it's Y", "in today's fast-paced world", "at the end of the day", and hollow hype. Short, \
    direct, concrete phrasing a confident person would actually say out loud.
    """

    nonisolated static func split(_ text: String) -> (say: String, move: String) {
        func strip(_ label: String, _ s: String) -> String {
            var r = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.uppercased().hasPrefix(label) { r = String(r.dropFirst(label.count)) }
            return r.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = text.range(of: "MOVE:", options: [.caseInsensitive]) {
            return (strip("SAY:", String(text[..<range.lowerBound])),
                    String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (strip("SAY:", text), "")
    }
}
