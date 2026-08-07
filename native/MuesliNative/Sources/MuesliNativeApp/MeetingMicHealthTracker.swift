import Foundation
import os

enum MeetingMicHealthState: String, Codable, Equatable {
    case healthy
    case waitingForAudio
    case micCallbacksMissing
    case micAllZeroWhileSystemActive
    case micLevelTooLow

    var userMessage: String? {
        switch self {
        case .healthy, .waitingForAudio:
            return nil
        case .micCallbacksMissing:
            return "Microphone audio is not reaching Muesli. This meeting transcript may miss your side."
        case .micAllZeroWhileSystemActive:
            return "Microphone audio is silent. This meeting transcript may miss your side."
        case .micLevelTooLow:
            return "Microphone level is very low — check you are recording from the right microphone. "
                + "This meeting transcript may miss your side."
        }
    }
}

struct MeetingMicHealthTransition: Codable, Equatable {
    let timestamp: Date
    let state: MeetingMicHealthState
    let reason: String
}

struct MeetingMicHealthSnapshot: Codable {
    let state: MeetingMicHealthState
    let rawMic: AudioSampleStatsSnapshot
    let systemAudio: AudioSampleStatsSnapshot
    let firstRawMicCallbackAt: Date?
    let firstNonZeroMicAt: Date?
    let firstSystemAudioAt: Date?
    let lastRawMicCallbackAt: Date?
    let lastNonZeroMicAt: Date?
    let lastSystemAudioAt: Date?
    let transitions: [MeetingMicHealthTransition]

    var warningMessage: String? {
        state.userMessage
    }
}

final class MeetingMicHealthTracker {
    private struct State {
        var healthState: MeetingMicHealthState = .waitingForAudio
        var rawMicStats = AudioSampleStats()
        var systemAudioStats = AudioSampleStats()
        var firstRawMicCallbackAt: Date?
        var firstNonZeroMicAt: Date?
        var firstSystemAudioAt: Date?
        var lastRawMicCallbackAt: Date?
        var lastNonZeroMicAt: Date?
        var lastSystemAudioAt: Date?
        var lastRawMicWasEffectivelyZero = true
        var activeSystemSamplesWhileMicMissing = 0
        var activeSystemSamplesWhileMicZero = 0
        var activeSystemSamplesWhileMicQuiet = 0
        var loudestMicPeak: Double = 0
        var transitions: [MeetingMicHealthTransition] = []
    }

    private static let sampleRate = 16_000
    private static let activeSystemPeakThreshold = 0.01
    private static let nonZeroMicPeakThreshold = 0.0001
    private static let zeroRatioThreshold = 0.999
    /// A mic whose loudest sample over a long stretch never reaches this is not going to
    /// transcribe. Real sessions here peak at 1.0; the failing ones peaked at 0.024 and 0.061,
    /// which is the built-in mic picking up a headset user from across the desk. Those still
    /// counted as "healthy" because the zeroRatio arm of `hasSignal` short-circuits the peak
    /// check — non-silence is not the same as usable level.
    private static let usableMicPeakThreshold = 0.08
    /// Only judge after this much *system-active* audio, so a long stretch where the other side
    /// is talking and the user simply is not does not trip it.
    private static let lowLevelConfirmationSamples = sampleRate * 300
    private static let degradedConfirmationSamples = sampleRate * 3
    private static let micCallbackStaleThreshold: TimeInterval = 1.0
    private static let maxTransitions = 32

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func noteRawMicSamples(_ samples: [Int16], now: Date = Date()) -> MeetingMicHealthSnapshot {
        lock.withLock { state in
            state.rawMicStats.addInt16(samples)
            state.firstRawMicCallbackAt = state.firstRawMicCallbackAt ?? now
            state.lastRawMicCallbackAt = now
            state.activeSystemSamplesWhileMicMissing = 0

            let stats = statsForSamples(samples)
            let zeroRatio = stats.sampleCount > 0
                ? Double(stats.zeroSampleCount) / Double(stats.sampleCount)
                : 1
            let hasSignal = stats.peak > Self.nonZeroMicPeakThreshold
                || zeroRatio < Self.zeroRatioThreshold
            state.lastRawMicWasEffectivelyZero = !hasSignal
            state.loudestMicPeak = max(state.loudestMicPeak, stats.peak)
            if state.loudestMicPeak > Self.usableMicPeakThreshold {
                state.activeSystemSamplesWhileMicQuiet = 0
            }
            if hasSignal {
                state.firstNonZeroMicAt = state.firstNonZeroMicAt ?? now
                state.lastNonZeroMicAt = now
                state.activeSystemSamplesWhileMicMissing = 0
                state.activeSystemSamplesWhileMicZero = 0
                // Recovery from a missing/silent mic still clears unconditionally. A quiet-but-
                // present mic is judged separately, in noteSystemSamples, once there has been
                // enough conversation to be sure the user simply was not silent.
                if state.healthState != .micLevelTooLow {
                    transitionLocked(&state, to: .healthy, reason: "raw_mic_signal_detected", now: now)
                }
            }
            return snapshotLocked(state)
        }
    }

    func noteSystemSamples(_ samples: [Int16], now: Date = Date()) -> MeetingMicHealthSnapshot {
        lock.withLock { state in
            state.systemAudioStats.addInt16(samples)
            let stats = statsForSamples(samples)
            guard stats.peak > Self.activeSystemPeakThreshold else {
                return snapshotLocked(state)
            }

            state.firstSystemAudioAt = state.firstSystemAudioAt ?? now
            state.lastSystemAudioAt = now

            if state.lastRawMicCallbackAt == nil {
                state.activeSystemSamplesWhileMicMissing += samples.count
                if state.activeSystemSamplesWhileMicMissing >= Self.degradedConfirmationSamples {
                    transitionLocked(&state, to: .micCallbacksMissing, reason: "system_audio_active_without_mic_callbacks", now: now)
                }
            } else if state.lastRawMicWasEffectivelyZero {
                state.activeSystemSamplesWhileMicZero += samples.count
                if state.activeSystemSamplesWhileMicZero >= Self.degradedConfirmationSamples {
                    transitionLocked(&state, to: .micAllZeroWhileSystemActive, reason: "system_audio_active_with_zero_mic", now: now)
                }
            } else if let lastRawMicCallbackAt = state.lastRawMicCallbackAt,
                      now.timeIntervalSince(lastRawMicCallbackAt) >= Self.micCallbackStaleThreshold {
                state.activeSystemSamplesWhileMicMissing += samples.count
                if state.activeSystemSamplesWhileMicMissing >= Self.degradedConfirmationSamples {
                    transitionLocked(&state, to: .micCallbacksMissing, reason: "system_audio_active_after_mic_callbacks_stopped", now: now)
                }
            } else {
                state.activeSystemSamplesWhileMicMissing = 0
                state.activeSystemSamplesWhileMicZero = 0
                // Mic is arriving and non-silent, but has it ever been loud enough to transcribe?
                if state.loudestMicPeak <= Self.usableMicPeakThreshold {
                    state.activeSystemSamplesWhileMicQuiet += samples.count
                    if state.activeSystemSamplesWhileMicQuiet >= Self.lowLevelConfirmationSamples {
                        transitionLocked(&state, to: .micLevelTooLow, reason: "mic_peak_below_usable_level", now: now)
                    }
                } else if state.healthState == .micLevelTooLow {
                    transitionLocked(&state, to: .healthy, reason: "mic_level_recovered", now: now)
                }
            }
            return snapshotLocked(state)
        }
    }

    func snapshot() -> MeetingMicHealthSnapshot {
        lock.withLock { snapshotLocked($0) }
    }

    private func transitionLocked(
        _ state: inout State,
        to nextState: MeetingMicHealthState,
        reason: String,
        now: Date
    ) {
        guard state.healthState != nextState else { return }
        state.healthState = nextState
        state.transitions.append(MeetingMicHealthTransition(timestamp: now, state: nextState, reason: reason))
        if state.transitions.count > Self.maxTransitions {
            state.transitions.removeFirst(state.transitions.count - Self.maxTransitions)
        }
    }

    private func snapshotLocked(_ state: State) -> MeetingMicHealthSnapshot {
        MeetingMicHealthSnapshot(
            state: state.healthState,
            rawMic: state.rawMicStats.snapshot(),
            systemAudio: state.systemAudioStats.snapshot(),
            firstRawMicCallbackAt: state.firstRawMicCallbackAt,
            firstNonZeroMicAt: state.firstNonZeroMicAt,
            firstSystemAudioAt: state.firstSystemAudioAt,
            lastRawMicCallbackAt: state.lastRawMicCallbackAt,
            lastNonZeroMicAt: state.lastNonZeroMicAt,
            lastSystemAudioAt: state.lastSystemAudioAt,
            transitions: state.transitions
        )
    }

    private func statsForSamples(_ samples: [Int16]) -> AudioSampleStatsSnapshot {
        var stats = AudioSampleStats()
        stats.addInt16(samples)
        return stats.snapshot()
    }
}
