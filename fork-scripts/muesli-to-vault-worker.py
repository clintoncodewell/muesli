#!/usr/bin/env python3
"""Poll a completed Muesli meeting until its notes are ready, then write a vault note.

Notes/diarization/summary run async after a meeting stops, so we poll `muesli-cli
meetings get <id>` with backoff until the notes reach a terminal state (or a cap),
then write markdown into the git-synced knowledge vault at capture/muesli/. gbrain
is re-indexed nightly off the synced vault, so we do NOT call gbrain here (it lives
on the VM, this runs on the Mac).

Idempotent: same meeting id -> same file path, overwritten.

Env:
  MUESLI_CLI          path to muesli-cli (default: MuesliDev bundle)
  MUESLI_SUPPORT_DIR  app support dir -> selects the DB (passed by the entrypoint)
  MUESLI_VAULT_DIR    vault root (default: ~/knowledge)
  MUESLI_VAULT_SUBDIR relative capture dir (default: capture/muesli)
  MUESLI_POLL_CAP_SECONDS  give-up cap (default: 900)
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

CLI = os.environ.get("MUESLI_CLI", "/Applications/MuesliDev.app/Contents/MacOS/muesli-cli")
SUPPORT_DIR = os.environ.get("MUESLI_SUPPORT_DIR", "")
VAULT_DIR = os.path.expanduser(os.environ.get("MUESLI_VAULT_DIR", "~/knowledge"))
VAULT_SUBDIR = os.environ.get("MUESLI_VAULT_SUBDIR", "capture/muesli")
POLL_CAP = int(os.environ.get("MUESLI_POLL_CAP_SECONDS", "900"))

# notesState terminal values (MeetingNotesState): structured_notes = AI notes ready;
# raw_transcript_fallback = LLM unavailable, transcript is the note. `missing` = still pending.
# status terminal (MeetingStatus): completed / note_only / failed -> notes won't improve.
NOTES_DONE = {"structured_notes", "raw_transcript_fallback"}
STATUS_TERMINAL = {"completed", "note_only", "failed"}


def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat()} worker: {msg}", flush=True)


def fetch(meeting_id):
    env = dict(os.environ)
    if SUPPORT_DIR:
        env["MUESLI_SUPPORT_DIR"] = SUPPORT_DIR
    out = subprocess.run(
        [CLI, "meetings", "get", str(meeting_id)],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if out.returncode != 0:
        return None, out.stderr.strip()
    doc = json.loads(out.stdout)
    return doc.get("data", doc), None


def is_ready(rec):
    return rec.get("notesState") in NOTES_DONE or rec.get("status") in STATUS_TERMINAL


def slugify(title):
    s = re.sub(r"[^a-z0-9]+", "-", (title or "meeting").lower()).strip("-")
    return (s or "meeting")[:60]


def build_note(rec, meeting_id):
    title = (rec.get("title") or "Untitled meeting").strip()
    start = rec.get("startTime") or ""
    date = start[:10] if len(start) >= 10 else datetime.now(timezone.utc).strftime("%Y-%m-%d")
    dur_min = round((rec.get("durationSeconds") or 0) / 60)
    notes = (rec.get("formattedNotes") or "").strip()
    manual = (rec.get("manualNotes") or "").strip()
    transcript = (rec.get("rawTranscript") or "").strip()
    cal_id = rec.get("calendarEventID") or ""

    fm = [
        "---",
        "type: meeting",
        f"updated: {datetime.now(timezone.utc).strftime('%Y-%m-%d')}",
        "source: muesli",
        f"meeting-id: {meeting_id}",
        f'title: "{title.replace(chr(34), chr(39))}"',
        f"date: {date}",
        f"duration-min: {dur_min}",
        f"notes-state: {rec.get('notesState', 'missing')}",
        f"word-count: {rec.get('wordCount', 0)}",
    ]
    if cal_id:
        fm.append(f"calendar-event-id: {cal_id}")
    fm.append("---")

    body = [f"# {title}", ""]
    if notes:
        body += ["## Notes", "", notes, ""]
    if manual:
        body += ["## My notes", "", manual, ""]
    if transcript:
        body += ["## Transcript", "", transcript, ""]
    if not notes and not transcript:
        body += ["_No notes or transcript were available for this meeting._", ""]
    return "\n".join(fm) + "\n\n" + "\n".join(body)


def write_note(rec, meeting_id):
    dest_dir = os.path.join(VAULT_DIR, VAULT_SUBDIR)
    os.makedirs(dest_dir, exist_ok=True)
    date = (rec.get("startTime") or "")[:10] or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    path = os.path.join(dest_dir, f"{date}-{slugify(rec.get('title'))}-{meeting_id}.md")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(build_note(rec, meeting_id))
    os.replace(tmp, path)   # atomic
    return path


def main():
    if len(sys.argv) < 2:
        log("no meeting id argument")
        return 2
    meeting_id = sys.argv[1]

    deadline = time.monotonic() + POLL_CAP
    delay = 5
    last_rec = None
    while True:
        rec, err = fetch(meeting_id)
        if err:
            log(f"cli error id={meeting_id}: {err}")
        elif rec:
            last_rec = rec
            if is_ready(rec):
                path = write_note(rec, meeting_id)
                log(f"saved id={meeting_id} state={rec.get('notesState')} -> {path}")
                return 0
        if time.monotonic() >= deadline:
            break
        time.sleep(min(delay, max(1, deadline - time.monotonic())))
        delay = min(delay * 1.5, 60)   # backoff, cap 60s

    # Cap hit. Save whatever we last had (transcript beats nothing); notify a human.
    if last_rec is not None:
        path = write_note(last_rec, meeting_id)
        log(f"cap hit id={meeting_id}; saved partial state={last_rec.get('notesState')} -> {path}")
        _notify(f"Muesli: meeting {meeting_id} saved to vault without final notes (timed out).")
        return 0
    log(f"cap hit id={meeting_id}; meeting never fetchable, nothing saved")
    _notify(f"Muesli: could not save meeting {meeting_id} to vault (not found).")
    return 1


def _notify(text):
    try:
        subprocess.run(
            ["osascript", "-e", f'display notification "{text}" with title "Muesli → vault"'],
            capture_output=True, timeout=10,
        )
    except Exception:
        pass


if __name__ == "__main__":
    sys.exit(main())
