#!/usr/bin/env bash
# Test the vault worker against a fake muesli-cli that walks notesState missing -> ready.
# Pure bash + python3, no macOS deps -> runs on the VM. Run: ./test-muesli-to-vault.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- fake muesli-cli: first 2 calls return status=processing/notesState=missing, then ready
CLI="$WORK/muesli-cli"
COUNTER="$WORK/calls"
echo 0 >"$COUNTER"
cat >"$CLI" <<'STUB'
#!/usr/bin/env bash
# args: meetings get <id>
n=$(cat "$MUESLI_TEST_COUNTER"); n=$((n+1)); echo "$n" >"$MUESLI_TEST_COUNTER"
if [ "$n" -lt 3 ]; then
  st=processing; ns=missing; notes=""
else
  st=completed; ns=structured_notes; notes="- decision: ship it\n- owner: clinton"
fi
cat <<JSON
{"ok":true,"command":"muesli-cli meetings get","data":{
  "id":42,"title":"Brightlume sync","startTime":"2026-07-23T02:30:00Z",
  "durationSeconds":1830,"rawTranscript":"You: hi\nOthers: hello","formattedNotes":"$notes",
  "manualNotes":"","wordCount":6,"folderID":null,"status":"$st","notesState":"$ns",
  "calendarEventID":"evt-123","selectedTemplateName":"Default"}}
JSON
STUB
chmod +x "$CLI"

# --- run the worker fast (no real sleeps needed; it'll poll ~3x)
export MUESLI_CLI="$CLI" MUESLI_TEST_COUNTER="$COUNTER"
export MUESLI_VAULT_DIR="$WORK/vault" MUESLI_VAULT_SUBDIR="capture/muesli"
export MUESLI_POLL_CAP_SECONDS=30
"$HERE/muesli-to-vault-worker.py" 42 >"$WORK/worker.log" 2>&1 || { echo "FAIL: worker exit $?"; cat "$WORK/worker.log"; exit 1; }

NOTE="$WORK/vault/capture/muesli/2026-07-23-brightlume-sync-42.md"
fail(){ echo "FAIL: $1"; echo "--- worker.log:"; cat "$WORK/worker.log"; echo "--- note:"; cat "$NOTE" 2>/dev/null; exit 1; }

[ -f "$NOTE" ] || fail "expected note not written at $NOTE"
grep -q "^type: meeting"        "$NOTE" || fail "missing frontmatter type"
grep -q "^source: muesli"       "$NOTE" || fail "missing source"
grep -q "^meeting-id: 42"       "$NOTE" || fail "missing meeting-id"
grep -q "notes-state: structured_notes" "$NOTE" || fail "wrong notes-state"
grep -q "decision: ship it"     "$NOTE" || fail "notes body not written"
grep -q "## Transcript"         "$NOTE" || fail "transcript section missing"
[ "$(cat "$COUNTER")" -ge 3 ]   || fail "worker did not poll until ready (calls=$(cat "$COUNTER"))"

# --- idempotency: rerun (stub now returns ready immediately) -> same single file, overwritten
echo 3 >"$COUNTER"
"$HERE/muesli-to-vault-worker.py" 42 >>"$WORK/worker.log" 2>&1 || fail "second run exit"
[ "$(find "$WORK/vault/capture/muesli" -name '*.md' | wc -l | tr -d ' ')" = "1" ] || fail "idempotency: expected 1 file"

echo "PASS: polls until ready, writes valid vault note, idempotent"
