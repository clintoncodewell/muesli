import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingMicHealthTracker")
struct MeetingMicHealthTrackerTests {
    @Test("all-zero raw mic with active system audio raises degraded warning")
    func allZeroRawMicWithActiveSystemAudioRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000), now: now)
        var snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(1))
        #expect(snapshot.state == .waitingForAudio)

        snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        #expect(snapshot.state == .waitingForAudio)

        snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        #expect(snapshot.state == .micAllZeroWhileSystemActive)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("a present but unusably quiet mic is flagged, not reported healthy")
    func quietMicIsFlagged() {
        // Regression: real sessions recorded at peak 0.024 (built-in mic while wearing a headset)
        // were reported healthy, because hasSignal passes on any non-silence via zeroRatio.
        let tracker = MeetingMicHealthTracker()
        let now = Date()
        let quietMic = Array(repeating: Int16(800), count: 16_000)   // peak ~0.024
        let loudSystem = Array(repeating: Int16(6_000), count: 16_000)

        var snapshot = tracker.noteRawMicSamples(quietMic, now: now)
        for second in 1...320 {
            let t = now.addingTimeInterval(TimeInterval(second))
            _ = tracker.noteRawMicSamples(quietMic, now: t)
            snapshot = tracker.noteSystemSamples(loudSystem, now: t)
        }

        #expect(snapshot.state == .micLevelTooLow)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("a mic at a normal level is never flagged as too quiet")
    func normalLevelMicIsNotFlagged() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()
        let normalMic = Array(repeating: Int16(9_000), count: 16_000)   // peak ~0.27
        let loudSystem = Array(repeating: Int16(6_000), count: 16_000)

        var snapshot = tracker.noteRawMicSamples(normalMic, now: now)
        for second in 1...320 {
            let t = now.addingTimeInterval(TimeInterval(second))
            _ = tracker.noteRawMicSamples(normalMic, now: t)
            snapshot = tracker.noteSystemSamples(loudSystem, now: t)
        }

        #expect(snapshot.state == .healthy)
        #expect(snapshot.warningMessage == nil)
    }

    @Test("system audio without mic callbacks is distinguishable from all-zero mic")
    func systemAudioWithoutMicCallbacksIsMissingCallbacks() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(1))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("mid-meeting mic callback loss after healthy input raises warning")
    func midMeetingMicCallbackLossRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(4))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("mid-meeting mic callback loss still warns when system audio starts during grace window")
    func midMeetingMicCallbackLossWithGraceWindowRaisesWarning() {
        let tracker = MeetingMicHealthTracker()
        let now = Date()

        _ = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000), now: now)
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 1_600), now: now.addingTimeInterval(0.5))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(2))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(3))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000), now: now.addingTimeInterval(4))

        #expect(snapshot.state == .micCallbacksMissing)
        #expect(snapshot.warningMessage != nil)
    }

    @Test("silence without active system audio does not warn")
    func silenceWithoutActiveSystemAudioDoesNotWarn() {
        let tracker = MeetingMicHealthTracker()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))
        let snapshot = tracker.noteSystemSamples(Array(repeating: 0, count: 16_000))

        #expect(snapshot.state == .waitingForAudio)
        #expect(snapshot.warningMessage == nil)
    }

    @Test("non-zero raw mic clears degraded warning")
    func nonZeroRawMicClearsWarning() {
        let tracker = MeetingMicHealthTracker()

        _ = tracker.noteRawMicSamples(Array(repeating: 0, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        _ = tracker.noteSystemSamples(Array(repeating: 6_000, count: 16_000))
        let recovered = tracker.noteRawMicSamples(Array(repeating: 400, count: 1_000))

        #expect(recovered.state == .healthy)
        #expect(recovered.warningMessage == nil)
        #expect(recovered.firstNonZeroMicAt != nil)
    }
}
