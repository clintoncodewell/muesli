#!/usr/bin/env bash
# Muesli meeting.completed hook -> knowledge-base auto-save (Granola-style).
#
# Wired via config: meeting_hook_enabled=true, meeting_hook_path=<this file>.
# MeetingHookRunner pipes JSON {schemaVersion,event,kind,id,completedAt} on stdin,
# runs us with cwd = the app's support dir, and kills us at meeting_hook_timeout_seconds.
#
# Meeting NOTES are generated asynchronously AFTER the meeting stops, so we must NOT
# do the real work inline (it would blow the 30s hook timeout and capture empty notes).
# We grab the id, spawn the poll-worker fully detached, and return immediately.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${MUESLI_VAULT_LOG:-$HOME/Library/Logs/muesli-to-vault.log}"
mkdir -p "$(dirname "$LOG")"

payload="$(cat)"   # stdin JSON
id="$(printf '%s' "$payload" | /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"

if [ -z "$id" ]; then
  echo "$(date -Is) entrypoint: no meeting id in payload: $payload" >>"$LOG"
  exit 0   # never fail the hook
fi

# cwd is the app support dir (MuesliDev / Muesli) -> the CLI reads the right DB from it.
export MUESLI_SUPPORT_DIR="${MUESLI_SUPPORT_DIR:-$PWD}"

# Detach the worker: reparent to init, no shared fds with the hook's stderr pipe, so
# the hook completes in milliseconds while the worker polls for up to ~15 min.
nohup /usr/bin/python3 "$HERE/muesli-to-vault-worker.py" "$id" </dev/null >>"$LOG" 2>&1 &

echo "$(date -Is) entrypoint: spawned worker for meeting id=$id (support=$MUESLI_SUPPORT_DIR)" >>"$LOG"
exit 0
