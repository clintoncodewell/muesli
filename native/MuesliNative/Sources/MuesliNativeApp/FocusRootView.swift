import SwiftUI
import MuesliCore

// Fork-owned (Focus UI). The minimal notes-first surface: a quiet meeting list, a
// distraction-free note view, and a plain notes pad while recording. Everything else —
// folders, models, insights, settings — lives in the full app, one click away.

struct FocusRootView: View {
    let appState: AppState
    let controller: MuesliController

    // Initial selection is env-overridable (MUESLI_FOCUS_SELECT=<id>) for headless visual QA.
    @State private var selectedMeetingID: Int64? =
        ProcessInfo.processInfo.environment["MUESLI_FOCUS_SELECT"].flatMap(Int64.init)
    @State private var searchQuery = ""

    var body: some View {
        Group {
            if let id = selectedMeetingID,
               let meeting = appState.meetingRows.first(where: { $0.id == id }) {
                FocusNoteView(
                    meeting: meeting,
                    appState: appState,
                    controller: controller,
                    onBack: { selectedMeetingID = nil }
                )
            } else {
                homeView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuesliTheme.backgroundBase)
        .preferredColorScheme(appState.config.darkMode ? .dark : .light)
    }

    // MARK: - Home

    private var homeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            if let upcoming = FocusPresentation.upcomingLine(
                from: appState.upcomingCalendarEvents,
                hiddenEventIDs: appState.hiddenCalendarEventIDs
            ) {
                upcomingRow(upcoming)
            }
            if appState.isMeetingRecording, let active = controller.activeLiveMeetingRecord() {
                recordingBanner(active)
            }
            meetingList
        }
    }

    private var headerBar: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(MuesliTheme.textTertiary)
            TextField("Search meetings", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(MuesliTheme.callout())
            Spacer()
            Button {
                controller.openHistoryWindow()
            } label: {
                Text("Open Muesli")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Open the full Muesli window")
        }
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.top, MuesliTheme.spacing16)
        .padding(.bottom, MuesliTheme.spacing12)
    }

    private func upcomingRow(_ line: FocusUpcomingLine) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Text(line.timeLabel)
                .font(MuesliTheme.caption())
                .foregroundStyle(line.timeLabel == "Now" ? MuesliTheme.accent : MuesliTheme.textTertiary)
            Text(line.title)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            if line.isJoinable, !appState.isMeetingRecording,
               let event = appState.upcomingCalendarEvents.first(where: { $0.id == line.eventID }),
               let url = event.meetingURL {
                Button("Join & Record") {
                    controller.joinAndRecord(title: event.title, meetingURL: url, endDate: event.endDate)
                }
                .buttonStyle(.plain)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.accent)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.vertical, MuesliTheme.spacing8)
    }

    private func recordingBanner(_ meeting: MeetingRecord) -> some View {
        Button {
            selectedMeetingID = meeting.id
        } label: {
            HStack(spacing: MuesliTheme.spacing8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                Text(meeting.title.isEmpty ? "Recording" : meeting.title)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("Open note")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, MuesliTheme.spacing8)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.bottom, MuesliTheme.spacing8)
    }

    private var meetingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing4, pinnedViews: []) {
                let groups = FocusPresentation.dayGroups(
                    from: appState.meetingRows,
                    activeMeetingID: controller.activeLiveMeetingRecord()?.id,
                    query: searchQuery
                )
                if groups.isEmpty {
                    Text(searchQuery.isEmpty ? "Meetings you record will appear here." : "No matches.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.top, MuesliTheme.spacing24)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                ForEach(groups) { group in
                    Text(group.label)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.top, MuesliTheme.spacing16)
                        .padding(.bottom, MuesliTheme.spacing4)
                    ForEach(group.items) { item in
                        meetingRow(item)
                    }
                }
            }
            .padding(.horizontal, MuesliTheme.spacing24)
            .padding(.bottom, MuesliTheme.spacing24)
        }
    }

    private func meetingRow(_ item: FocusListItem) -> some View {
        Button {
            selectedMeetingID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MuesliTheme.spacing8) {
                    if item.isActive {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                    }
                    Text(item.title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(item.timeLabel)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Text(item.preview)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.vertical, MuesliTheme.spacing8)
            .padding(.horizontal, MuesliTheme.spacing8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Muesli") {
                controller.showMeetingDocument(id: item.id)
                controller.openHistoryWindow()
            }
        }
    }
}

// MARK: - Note view

struct FocusNoteView: View {
    let meeting: MeetingRecord
    let appState: AppState
    let controller: MuesliController
    let onBack: () -> Void

    @State private var showTranscript = false
    @State private var manualNotesDraft = ""
    @State private var autosave: FocusNotesAutosave?
    @State private var copied = false

    private var isLive: Bool {
        meeting.status == .recording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            noteHeader
            Divider().opacity(0.4)
            if isLive {
                liveNotesEditor
            } else {
                completedNote
            }
        }
        .onAppear {
            let session = FocusNotesAutosave(initial: meeting.manualNotes) { [weak controller] notes in
                controller?.updateMeetingManualNotes(id: meeting.id, notes: notes)
            }
            autosave = session
            manualNotesDraft = session.draft
        }
        .onChange(of: meeting.manualNotes) { _, external in
            // The record refreshed underneath us; adopt it only if we have nothing unsaved.
            autosave?.syncExternal(external)
            if let autosave { manualNotesDraft = autosave.draft }
        }
        .onDisappear { autosave?.flush() }
    }

    private var noteHeader: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)

            Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)

            if isLive {
                Circle().fill(Color.red).frame(width: 7, height: 7)
            }

            Spacer()

            if isLive {
                Button("Stop") {
                    // Flush before stopping so summarization sees the final draft.
                    autosave?.flush()
                    controller.toggleMeetingRecording()
                }
                .buttonStyle(.plain)
                .font(MuesliTheme.callout())
                .foregroundStyle(Color.red)
            } else {
                Button {
                    copyNotes()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(copied ? MuesliTheme.success : MuesliTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy notes")

                Menu {
                    Button(showTranscript ? "Hide Transcript" : "Show Transcript") {
                        showTranscript.toggle()
                    }
                    Button("Open in Muesli") {
                        controller.showMeetingDocument(id: meeting.id)
                        controller.openHistoryWindow()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.vertical, MuesliTheme.spacing12)
    }

    @ViewBuilder
    private var completedNote: some View {
        if showTranscript {
            ScrollView {
                Text(meeting.rawTranscript.isEmpty ? "No transcript." : meeting.rawTranscript)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MuesliTheme.spacing24)
            }
        } else if meeting.formattedNotes.isEmpty, !meeting.manualNotes.isEmpty {
            // The user's own notes are content, not an empty state.
            VStack(alignment: .leading, spacing: 0) {
                Text("Your notes")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.horizontal, MuesliTheme.spacing24)
                    .padding(.top, MuesliTheme.spacing12)
                ScrollView {
                    Text(meeting.manualNotes)
                        .font(MuesliTheme.body())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(MuesliTheme.spacing24)
                }
            }
        } else if meeting.formattedNotes.isEmpty {
            Text(meeting.status == .processing ? "Transcribing…" : "No notes for this meeting yet.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MeetingNotesView(markdown: meeting.formattedNotes)
        }
    }

    /// The Granola move: while the meeting records, this surface is just your own notes.
    private var liveNotesEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $manualNotesDraft)
                .font(MuesliTheme.body())
                .scrollContentBackground(.hidden)
                .padding(MuesliTheme.spacing16)
                .onChange(of: manualNotesDraft) { _, newValue in
                    autosave?.update(newValue)
                }
            Text("Type anything — Muesli is listening and will turn this into full notes when you stop.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .padding(.horizontal, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing12)
        }
    }

    private func copyNotes() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Match what the button says and what the view shows: notes first, the user's own
        // notes next, transcript only as the last resort.
        let content = [meeting.formattedNotes, meeting.manualNotes, meeting.rawTranscript]
            .first { !$0.isEmpty } ?? ""
        pasteboard.setString(content, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
