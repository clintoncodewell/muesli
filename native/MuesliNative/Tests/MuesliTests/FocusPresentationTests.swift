import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("FocusPresentation")
struct FocusPresentationTests {

    private func record(
        id: Int64,
        title: String = "Weekly sync",
        start: String,
        notes: String = "",
        manualNotes: String = "",
        transcript: String = "",
        status: MeetingStatus = .completed
    ) -> MeetingRecord {
        MeetingRecord(
            id: id, title: title, startTime: start, durationSeconds: 600,
            rawTranscript: transcript, formattedNotes: notes, wordCount: 0,
            folderID: nil, calendarEventID: nil, calendarOccurrence: nil,
            micAudioPath: nil, systemAudioPath: nil, savedRecordingPath: nil,
            status: status, manualNotes: manualNotes,
            selectedTemplateID: nil, selectedTemplateName: nil,
            selectedTemplateKind: nil, selectedTemplatePrompt: nil,
            source: .meeting, followUpToID: nil, followUpToRecordName: nil
        )
    }

    private func event(
        id: String, title: String, start: Date, end: Date,
        url: String? = nil, allDay: Bool = false
    ) -> UnifiedCalendarEvent {
        UnifiedCalendarEvent(
            id: id, title: title, startDate: start, endDate: end,
            isAllDay: allDay, source: .eventKit,
            meetingURL: url.flatMap(URL.init(string:))
        )
    }

    // MARK: - Day grouping

    @Test("groups meetings by day with human labels, newest first")
    func dayGrouping() {
        let now = ISO8601DateFormatter().date(from: "2026-08-08T10:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let groups = FocusPresentation.dayGroups(
            from: [
                record(id: 1, start: "2026-08-08T08:00:00Z"),
                record(id: 2, start: "2026-08-07T15:00:00Z"),
                record(id: 3, start: "2026-08-01T09:00:00Z"),
            ],
            now: now,
            calendar: calendar
        )

        #expect(groups.count == 3)
        #expect(groups[0].label == "Today")
        #expect(groups[0].items.map(\.id) == [1])
        #expect(groups[1].label == "Yesterday")
        // A week or more back falls through to a short date, not a weekday.
        #expect(groups[2].label == "1 Aug")
    }

    @Test("same-day meetings stay in one group, newest first")
    func sameDayGrouping() {
        // Pin the calendar to UTC: with the machine's local calendar these fixture
        // times can straddle midnight (they did, in AEST).
        let now = ISO8601DateFormatter().date(from: "2026-08-08T20:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let groups = FocusPresentation.dayGroups(
            from: [
                record(id: 1, start: "2026-08-08T08:00:00Z"),
                record(id: 2, start: "2026-08-08T14:00:00Z"),
            ],
            now: now,
            calendar: calendar
        )
        #expect(groups.count == 1)
        #expect(groups[0].items.map(\.id) == [2, 1])
    }

    @Test("search filters on title and notes, case-insensitively")
    func searchFilter() {
        let meetings = [
            record(id: 1, title: "Genesis Care strategy", start: "2026-08-08T08:00:00Z"),
            record(id: 2, title: "Weekly sync", start: "2026-08-08T09:00:00Z", notes: "## Genesis follow-ups"),
            record(id: 3, title: "1:1", start: "2026-08-08T10:00:00Z"),
        ]
        let groups = FocusPresentation.dayGroups(from: meetings, query: "genesis")
        #expect(groups.flatMap(\.items).map(\.id).sorted() == [1, 2])
    }

    // MARK: - Preview

    @Test("preview prefers first content line of notes, stripped of markdown")
    func previewFromNotes() {
        // Headings are content-free ceremony — every generated note opens with
        // "# Meeting Summary" — so the preview must skip them for actual content.
        let meeting = record(
            id: 1, start: "2026-08-08T08:00:00Z",
            notes: "\n# Meeting Summary\n\n- **Decision**: ship it\n"
        )
        #expect(FocusPresentation.preview(for: meeting) == "Decision: ship it")

        // Notes that are headings only still produce something rather than nothing.
        let headingsOnly = record(id: 2, start: "2026-08-08T08:00:00Z", notes: "# Meeting Summary\n## Topics\n")
        #expect(FocusPresentation.preview(for: headingsOnly) == "Meeting Summary")
    }

    @Test("preview falls back to transcript speech without timestamps or speaker labels")
    func previewFromTranscript() {
        let meeting = record(
            id: 1, start: "2026-08-08T08:00:00Z",
            transcript: "[10:03:11] Speaker 1: We agreed to move the launch to March.\n"
        )
        #expect(FocusPresentation.preview(for: meeting) == "We agreed to move the launch to March.")
    }

    @Test("preview reflects status for in-flight meetings")
    func previewStatus() {
        #expect(FocusPresentation.preview(for: record(id: 1, start: "2026-08-08T08:00:00Z", status: .recording)) == "Recording…")
        #expect(FocusPresentation.preview(for: record(id: 2, start: "2026-08-08T08:00:00Z", status: .processing)) == "Transcribing…")
        #expect(FocusPresentation.preview(for: record(id: 3, start: "2026-08-08T08:00:00Z")) == "No notes yet")
    }

    @Test("long previews truncate with an ellipsis")
    func previewTruncation() {
        let long = String(repeating: "word ", count: 40)
        let meeting = record(id: 1, start: "2026-08-08T08:00:00Z", notes: long)
        let preview = FocusPresentation.preview(for: meeting)
        #expect(preview.hasSuffix("…"))
        #expect(preview.count < 100)
    }

    @Test("search matches manual notes too, since they can supply the visible preview")
    func searchIncludesManualNotes() {
        let meetings = [
            record(id: 1, title: "1:1", start: "2026-08-08T08:00:00Z", manualNotes: "ask about the Zurich office"),
            record(id: 2, title: "Sync", start: "2026-08-08T09:00:00Z"),
        ]
        let groups = FocusPresentation.dayGroups(from: meetings, query: "zurich")
        #expect(groups.flatMap(\.items).map(\.id) == [1])
    }

    // MARK: - Upcoming line

    @Test("upcoming line picks the active event over a later one and labels it Now")
    func upcomingActiveEvent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let line = FocusPresentation.upcomingLine(
            from: [
                event(id: "later", title: "Later", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200)),
                event(id: "active", title: "Standup", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600), url: "https://zoom.us/j/123"),
            ],
            hiddenEventIDs: [],
            now: now
        )
        #expect(line?.eventID == "active")
        #expect(line?.timeLabel == "Now")
        #expect(line?.isJoinable == true)
    }

    @Test("upcoming line ignores hidden, all-day, and far-future events")
    func upcomingFilters() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let line = FocusPresentation.upcomingLine(
            from: [
                event(id: "hidden", title: "Hidden", start: now.addingTimeInterval(300), end: now.addingTimeInterval(3600)),
                event(id: "allday", title: "Birthday", start: now.addingTimeInterval(600), end: now.addingTimeInterval(86400), allDay: true),
                event(id: "far", title: "Tomorrow", start: now.addingTimeInterval(6 * 3600), end: now.addingTimeInterval(7 * 3600)),
            ],
            hiddenEventIDs: ["hidden"],
            now: now
        )
        #expect(line == nil)
    }

    // MARK: - Autosave session

    @Test("autosave writes once per debounce window, not per keystroke")
    @MainActor
    func autosaveDebounces() async throws {
        var saves: [String] = []
        let session = FocusNotesAutosave(initial: "", debounce: .milliseconds(40)) { saves.append($0) }

        session.update("h")
        session.update("he")
        session.update("hello")
        #expect(saves.isEmpty)   // nothing written at typing speed

        // Poll rather than trust a single fixed sleep: under full-suite load the
        // debounce task can be scheduled late, which is fine — what matters is that
        // exactly one save eventually lands with the final text.
        for _ in 0..<50 where saves.isEmpty {
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(saves == ["hello"])
        #expect(!session.isDirty)
    }

    @Test("flush writes a dirty draft immediately and is a no-op when clean")
    @MainActor
    func autosaveFlush() {
        var saves: [String] = []
        let session = FocusNotesAutosave(initial: "start", debounce: .seconds(60)) { saves.append($0) }

        session.flush()
        #expect(saves.isEmpty)

        session.update("start amended")
        session.flush()
        #expect(saves == ["start amended"])

        session.flush()
        #expect(saves == ["start amended"])   // still once
    }

    @Test("an external change is adopted when clean but never clobbers unsaved edits")
    @MainActor
    func autosaveExternalSync() {
        var saves: [String] = []
        let session = FocusNotesAutosave(initial: "original", debounce: .seconds(60)) { saves.append($0) }

        // Clean: adopt the dashboard's edit.
        session.syncExternal("edited in dashboard")
        #expect(session.draft == "edited in dashboard")
        #expect(!session.isDirty)

        // Dirty: the local draft wins until it flushes.
        session.update("local unsaved edit")
        session.syncExternal("another dashboard edit")
        #expect(session.draft == "local unsaved edit")

        session.flush()
        #expect(saves == ["local unsaved edit"])
    }

    @Test("an event with no meeting link shows but is not joinable")
    func upcomingLinklessEvent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let line = FocusPresentation.upcomingLine(
            from: [event(id: "e", title: "In-person catchup", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(5400))],
            hiddenEventIDs: [],
            now: now
        )
        #expect(line != nil)
        #expect(line?.isJoinable == false)
    }
}
