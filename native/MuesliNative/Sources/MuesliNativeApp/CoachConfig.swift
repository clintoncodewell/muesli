import Foundation

// Fork-owned (Cue coach port). Coach configuration, loaded from fork-config.json in the
// app support dir (same file as the calendar-context flag). Kept out of Muesli's own
// config/Settings so this stays new-files-only — conflict-light on the daily upstream merge.
//
// fork-config.json keys (all optional; coach is OFF unless coach_enabled is true):
//   "coach_enabled": false,
//   "coach_base_url": "https://api.groq.com/openai/v1",
//   "coach_model": "llama-3.3-70b-versatile",
//   "coach_api_key": "sk-...",
//   "coach_system_prompt": "...",        (defaults to the built-in coach prompt)
//   "coach_summary_prompt": "...",
//   "coach_context": "...",              (freeform context injected into every cue)
//   "coach_cue_length": "terse",         ("terse" | "normal")
//   "coach_cooldown_seconds": 15,
//   "coach_silence_seconds": 1.8,
//   "coach_summary_interval_min": 5,
//   "coach_humanize": true,
//   "coach_reasoning_effort": ""         ("" | "low" | "medium" | "high")

enum CoachCueLength: String {
    case terse, normal
    var promptRule: String? {
        self == .terse
            ? "Keep SAY to ONE short line I can say in a single breath — at most about 10 words, "
              + "just the exact words, no preamble, no lead-in, no options. Put any nuance, "
              + "alternatives, or reasoning in MOVE, never in SAY."
            : nil
    }
}

struct CoachConfig {
    let baseURL: String
    let model: String
    let apiKey: String
    let systemPrompt: String
    let globalPrompt: String
    let context: String
    let knowledge: String
    let summaryPrompt: String
    let summaryInterval: Double   // minutes
    let temperature: Double?
    let seed: Int?
    let reasoningEffort: String?
    let humanize: Bool
    let micOff: Bool
    let cooldown: Double
    let silence: Double
    let cueLength: CoachCueLength

    static let defaultSystemPrompt = """
    You are my real-time meeting coach, listening to a live call. The transcript is \
    labeled "Them" (the other person) and "You" (me). React to what was JUST said — be \
    specific, direct, and practical, never generic.

    For SAY, give me natural words I can speak verbatim right now (confident, concise, \
    in my own voice). For MOVE, give sharp observations on where the conversation really \
    is and how to steer it: objections to reframe, buying signals to advance on, what to \
    probe next, and what to avoid.
    """

    static let defaultSummaryPrompt = """
    You are keeping a running summary of a live meeting for me. From the transcript so far, write \
    a tight summary in Markdown: a one-line **TL;DR**, then **Key points**, **Decisions**, \
    **Action items** (who / what), and **Open questions**. Keep it current and concise, and omit \
    any section that has nothing in it.
    """
}

// Fork-owned. Non-coach fork switches that also live in fork-config.json.
enum ForkSettings {
    /// Neural echo cancellation on the meeting mic. On headphones there is no echo to cancel,
    /// and the CoreML fallback processor costs ~a full core for the whole meeting — so this
    /// exists to turn it off. Default true (upstream behaviour).
    ///
    ///   "meeting_aec_enabled": false
    ///
    /// Read on each MeetingNeuralAec init, so it takes effect on the next meeting rather than
    /// the next launch. Never re-read mid-meeting: the pass-through path skips the history
    /// buffers the model would need if it were switched back on partway through.
    static var meetingAecEnabled: Bool { (CoachSettings.dict()["meeting_aec_enabled"] as? Bool) ?? true }
}

enum CoachSettings {
    static var forkConfigURL: URL {
        AppIdentity.supportDirectoryURL.appendingPathComponent("fork-config.json")
    }

    fileprivate static func dict() -> [String: Any] {
        guard let data = try? Data(contentsOf: forkConfigURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    static func enabled() -> Bool { (dict()["coach_enabled"] as? Bool) ?? false }

    /// Load a config snapshot, or nil if the coach can't run (disabled / no model / no key).
    static func load() -> CoachConfig? {
        let d = dict()
        guard (d["coach_enabled"] as? Bool) == true else { return nil }
        let base = (d["coach_base_url"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = (d["coach_model"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (d["coach_api_key"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !base.isEmpty, !model.isEmpty, !key.isEmpty else { return nil }
        return CoachConfig(
            baseURL: base,
            model: model,
            apiKey: key,
            systemPrompt: (d["coach_system_prompt"] as? String) ?? CoachConfig.defaultSystemPrompt,
            globalPrompt: (d["coach_global_prompt"] as? String) ?? "",
            context: (d["coach_context"] as? String) ?? "",
            knowledge: (d["coach_knowledge"] as? String) ?? "",
            summaryPrompt: (d["coach_summary_prompt"] as? String) ?? CoachConfig.defaultSummaryPrompt,
            summaryInterval: (d["coach_summary_interval_min"] as? Double) ?? 5,
            temperature: d["coach_temperature"] as? Double,
            seed: d["coach_seed"] as? Int,
            reasoningEffort: d["coach_reasoning_effort"] as? String,
            humanize: (d["coach_humanize"] as? Bool) ?? true,
            micOff: (d["coach_mic_off"] as? Bool) ?? false,
            cooldown: (d["coach_cooldown_seconds"] as? Double) ?? 15,
            silence: (d["coach_silence_seconds"] as? Double) ?? 1.8,
            cueLength: CoachCueLength(rawValue: (d["coach_cue_length"] as? String) ?? "terse") ?? .terse
        )
    }
}
