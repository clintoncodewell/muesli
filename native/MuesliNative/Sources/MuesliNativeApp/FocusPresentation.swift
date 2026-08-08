import Foundation
import MuesliCore

// Fork-owned (Focus UI). Pure presentation logic for the minimal notes-first window:
// no AppKit, no state — everything here is unit-testable. The views in FocusRootView
// are thin renderings of these values.

struct FocusListItem: Identifiable, Equatable {
    let id: Int64
    let title: String
    let timeLabel: String        // "10:30"
    let preview: String          // one quiet line under the title
    let isActive: Bool           // recording or processing right now
}

struct FocusDayGroup: Identifiable, Equatable {
    let id: String               // stable key, e.g. "2026-08-08"
    let label: String            // "Today", "Yesterday", "Tuesday", "24 Jul"
    let items: [FocusListItem]
}

/// The single calendar line shown at the top of the home view, or nil for none.
struct FocusUpcomingLine: Equatable {
    let eventID: String
    let title: String
    let timeLabel: String        // "10:30" or "Now"
    let isJoinable: Bool         // show Join & Record only when there is a meeting URL
}

/// Debounced, conflict-aware autosave for the live manual-notes pad.
///
/// The naive shape — write the whole draft to the store on every keystroke — has two failure
/// modes: database churn at typing speed, and the lost-update where a draft initialised once
/// blindly overwrites an edit made in the full dashboard. This session writes at most once per
/// debounce interval, flushes on lifecycle boundaries (back, stop, disappear), and adopts an
/// external change instead of clobbering it whenever the local draft has no unsaved edits.
@MainActor
final class FocusNotesAutosave {
    private(set) var draft: String
    private(set) var lastSaved: String
    private let save: (String) -> Void
    private let debounce: Duration
    private var pending: Task<Void, Never>?

    var isDirty: Bool { draft != lastSaved }

    init(initial: String, debounce: Duration = .milliseconds(400), save: @escaping (String) -> Void) {
        self.draft = initial
        self.lastSaved = initial
        self.debounce = debounce
        self.save = save
    }

    /// The user typed. Schedule a save; earlier pending saves are superseded.
    func update(_ text: String) {
        guard text != draft else { return }
        draft = text
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    /// Write now if there is anything unsaved. Call on back / stop / disappear.
    func flush() {
        pending?.cancel()
        pending = nil
        guard isDirty else { return }
        lastSaved = draft
        save(draft)
    }

    /// The record changed underneath us (edited in the dashboard, or refreshed from the store).
    /// Adopt it only when we have nothing unsaved — a dirty local draft wins until it flushes.
    func syncExternal(_ text: String) {
        guard !isDirty, text != draft else { return }
        draft = text
        lastSaved = text
    }
}

enum FocusPresentation {

    // MARK: - Meeting list

    static func dayGroups(
        from meetings: [MeetingRecord],
        activeMeetingID: Int64? = nil,
        query: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [FocusDayGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = meetings
            .filter { meeting in
                guard !trimmedQuery.isEmpty else { return true }
                return meeting.title.lowercased().contains(trimmedQuery)
                    || meeting.formattedNotes.lowercased().contains(trimmedQuery)
                    || meeting.manualNotes.lowercased().contains(trimmedQuery)
            }
            .sorted { startDate($0) > startDate($1) }

        var groups: [FocusDayGroup] = []
        for meeting in sorted {
            let date = startDate(meeting)
            let key = dayKey(for: date, calendar: calendar)
            let item = FocusListItem(
                id: meeting.id,
                title: meeting.title.isEmpty ? "Untitled meeting" : meeting.title,
                timeLabel: Self.timeFormatter.string(from: date),
                preview: preview(for: meeting),
                isActive: meeting.id == activeMeetingID
                    || meeting.status == .recording
                    || meeting.status == .processing
            )
            if let last = groups.indices.last, groups[last].id == key {
                groups[last] = FocusDayGroup(id: key, label: groups[last].label, items: groups[last].items + [item])
            } else {
                groups.append(FocusDayGroup(id: key, label: dayLabel(for: date, now: now, calendar: calendar), items: [item]))
            }
        }
        return groups
    }

    /// One quiet line under a meeting title: first content line of the notes, else a
    /// transcript snippet, else a status hint. Markdown syntax is stripped, not rendered.
    static func preview(for meeting: MeetingRecord) -> String {
        switch meeting.status {
        case .recording: return "Recording…"
        case .processing: return "Transcribing…"
        case .failed: return "Transcription failed"
        case .noteOnly, .completed: break
        }
        for raw in meeting.formattedNotes.components(separatedBy: .newlines) {
            let stripped = strippedMarkdownLine(raw)
            if !stripped.isEmpty { return truncate(stripped) }
        }
        for raw in meeting.manualNotes.components(separatedBy: .newlines) {
            let stripped = strippedMarkdownLine(raw)
            if !stripped.isEmpty { return truncate(stripped) }
        }
        let transcript = flattenedTranscriptLine(meeting.rawTranscript)
        if !transcript.isEmpty { return truncate(transcript) }
        return "No notes yet"
    }

    static func strippedMarkdownLine(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["### ", "## ", "# ", "- [x] ", "- [X] ", "- [ ] ", "- ", "* ", "> "] {
            if line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                break
            }
        }
        line = line.replacingOccurrences(of: "**", with: "")
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Drop "[10:03:11] Speaker 1:" style prefixes so previews read as speech, not logs.
    static func flattenedTranscriptLine(_ transcript: String) -> String {
        for raw in transcript.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            if let colon = line.firstIndex(of: ":"),
               line.distance(from: line.startIndex, to: colon) <= 24 {
                line = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty { return line }
        }
        return ""
    }

    // MARK: - Upcoming line

    /// The one event worth a line at the top: currently running, or the next one starting
    /// within `windowHours`. Anything further away is noise here — the full app has the board.
    static func upcomingLine(
        from events: [UnifiedCalendarEvent],
        hiddenEventIDs: Set<String>,
        now: Date = Date(),
        windowHours: Double = 4
    ) -> FocusUpcomingLine? {
        let horizon = now.addingTimeInterval(windowHours * 3600)
        let candidates = events
            .filter { !$0.isAllDay && !hiddenEventIDs.contains($0.id) && $0.endDate > now && $0.startDate < horizon }
            .sorted { $0.startDate < $1.startDate }
        let active = candidates.first { $0.startDate <= now }
        guard let event = active ?? candidates.first else { return nil }
        return FocusUpcomingLine(
            eventID: event.id,
            title: event.title,
            timeLabel: event.startDate <= now ? "Now" : Self.timeFormatter.string(from: event.startDate),
            isJoinable: event.meetingURL != nil
        )
    }

    // MARK: - Helpers

    static func startDate(_ meeting: MeetingRecord) -> Date {
        // MeetingBrowserLogic already knows every stored startTime format.
        MeetingBrowserLogic.parseDate(meeting.startTime) ?? .distantPast
    }

    static func dayLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days < 7 { return Self.weekdayFormatter.string(from: date) }
        return Self.shortDateFormatter.string(from: date)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func truncate(_ text: String, limit: Int = 90) -> String {
        text.count <= limit ? text : String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}
