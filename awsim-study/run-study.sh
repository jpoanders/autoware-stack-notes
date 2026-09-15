#!/usr/bin/env bash
#
# run-study.sh — Orchestrates the AWSIM / Autoware / Cyclone DDS fault-injection
# study as a sequence of HEADLESS Claude Code runs: one report per invocation,
# fresh context each time, dependencies respected, outputs never clobbered, and
# TRUNCATION HANDLED — a report that runs out of context mid-write is detected
# and continued in a fresh run until it finishes.
#
#   A) foundation      — built once, then YOU review it (the one human gate)
#   B) five reports     — one Claude run each, in dependency order 1,2,5,3,4
#   C) consolidation    — index + shared glossary + cross-reference check
#
# HOW CONTEXT LIMITS ARE HANDLED
#   * Between runs: nothing to reset. Each report is its own `claude -p` with a
#     fresh context; all that crosses runs are the .md files on disk, which every
#     run re-reads. A whole run failing just means the script retries it.
#   * Within a run: a DEEP report can exhaust context mid-write. In headless that
#     ends with exit 0 but a half-written file. So completion is signalled by a
#     marker the agent writes ONLY when the deliverable is finished:
#         <!-- REPORT-COMPLETE -->
#     Its presence = done (used for BOTH truncation detection and cross-run skip).
#     If a run ends without it, the script relaunches THE SAME report in a fresh
#     context, feeds it the partial file (+ any '<!-- RESUME: ... -->' hint the
#     agent left), and tells it to APPEND the remainder — up to MAX_CONT times.
#     A fresh context re-reading the partial from disk is what actually frees the
#     window (this is why we do NOT use claude --continue/--resume, which would
#     reload the same full context that overflowed).
#
# PREREQUISITES
#   1. Claude Code installed and authenticated (`claude` on PATH; logged in, or
#      ANTHROPIC_API_KEY exported).
#   2. The source repos cloned under $SRC (rclcpp/rcl/rmw/rmw_cyclonedds @humble;
#      cyclonedds @releases/0.10.x; the message packages; etc.).
#   3. The study prompt and setup guide present at $PROMPT_FILE and $GUIDE.
#
# USAGE
#   ./run-study.sh                 # normal run, with the foundation review gate
#   SKIP_REVIEW=1 ./run-study.sh   # unattended (skips the gate — see caveat)
#   PAUSE_BETWEEN_TASKS=1 ./...    # also pause to review after every task
#   FORCE=1 ./run-study.sh         # redo reports even if already complete
#   MODEL=sonnet ./run-study.sh    # cheaper/faster; opus is the default
#   MAX_TURNS=120 MAX_CONT=4 ./... # give big reports more room
#
# Re-running is safe and resumes: complete reports are skipped, incomplete ones
# are continued. To redo one report, delete its file and run again.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — edit these paths, then run ./run-study.sh
# ---------------------------------------------------------------------------
PROJECT_ROOT="${PROJECT_ROOT:-.}"
SRC="${SRC:-$PROJECT_ROOT/src}"                                    # cloned repos
PROMPT_FILE="${PROMPT_FILE:-prompts/awsim-fault-injection-five-tasks-prompt.md}"
GUIDE="${GUIDE:-prompts/autoware-core-awsim-setup-guide.md}"
REPORTS_DIR="${REPORTS_DIR:-reports}"
LOG_DIR="${LOG_DIR:-logs}"
MODEL="${MODEL:-opus}"
MAX_TURNS="${MAX_TURNS:-80}"                                       # per invocation
MAX_CONT="${MAX_CONT:-3}"                                          # continuation attempts per report
TOOLS="${TOOLS:-Bash,Read,Grep,Glob,Write,Edit}"                  # pre-authorized (no prompts)
PERM_MODE="${PERM_MODE:-acceptEdits}"                              # auto-accept file writes
FORCE="${FORCE:-0}"
SKIP_REVIEW="${SKIP_REVIEW:-0}"
PAUSE_BETWEEN_TASKS="${PAUSE_BETWEEN_TASKS:-0}"

# Broad `Bash` is the robust headless choice — too-narrow allowedTools makes the
# agent FREEZE on an unlisted command. To scope it, run against a read-only copy
# of $SRC, or set TOOLS to a Bash(cmd:*) allowlist (accepting possible stalls).

# ---------------------------------------------------------------------------
cd "$PROJECT_ROOT"
mkdir -p "$REPORTS_DIR" "$LOG_DIR"
: > "$LOG_DIR/incomplete.txt"

command -v claude >/dev/null || { echo "ERROR: 'claude' not on PATH — install Claude Code."; exit 1; }
[[ -f "$PROMPT_FILE" ]] || { echo "ERROR: prompt not found: $PROMPT_FILE"; exit 1; }
[[ -f "$GUIDE" ]]       || { echo "ERROR: setup guide not found: $GUIDE"; exit 1; }
[[ -d "$SRC" ]]         || { echo "ERROR: source dir not found: $SRC (clone the repos first)"; exit 1; }

# Shared preamble injected into every run, incl. the completion-marker contract.
COMMON="Study instructions: read the file '$PROMPT_FILE' in full and follow it exactly.
Setup guide (AUTHORITATIVE record of the runtime configuration, since the simulation cannot be executed): read '$GUIDE' and cite it as 'setup-guide' where you rely on it.
Source repositories are under '$SRC/' — open real files there and cite every non-obvious claim as path:line.
The DDS vendor is Eclipse Cyclone DDS: target eclipse-cyclonedds/cyclonedds and rmw_cyclonedds, never carry over Fast DDS assumptions.
Apply the evidence rules, writing standards, and quality floors from the instructions. Tag spec/vendor claims, and anything that would require running the sim or a packet capture, as [UNVERIFIED].
COMPLETION CONTRACT: when the deliverable for THIS run is fully complete per the instructions, append as the final line of the file exactly this and nothing after it:
<!-- REPORT-COMPLETE -->
If you must stop early because you are running low on context/budget, do NOT write that marker; instead append a single final line of the form '<!-- RESUME: <what remains, and the section/point where you stopped> -->' so the next run can continue."

is_complete() { [[ -f "$1" ]] && grep -q 'REPORT-COMPLETE' "$1"; }
fsize() { wc -c <"$1" 2>/dev/null || echo 0; }

# _invoke <output> <prompt> — one fresh-context headless run; logs to $LOG_DIR.
_invoke() {
  local out="$1" prompt="$2" name log
  name="$(basename "$out" .md)"; log="$LOG_DIR/$name.$(date +%s).json"
  claude -p "$prompt" \
    --model "$MODEL" \
    --allowedTools "$TOOLS" \
    --permission-mode "$PERM_MODE" \
    --add-dir "$SRC" \
    --max-turns "$MAX_TURNS" \
    --output-format json \
    >"$log" 2>"${log%.json}.err"
}

# run_report <output> <base_prompt> — returns 0 if the report completes, else 1.
run_report() {
  local out="$1" base="$2" name; name="$(basename "$out" .md)"

  if is_complete "$out" && [[ "$FORCE" != "1" ]]; then
    echo "== SKIP  $out (complete; FORCE=1 to redo)"; return 0
  fi
  [[ "$FORCE" == "1" ]] && rm -f "$out"

  # First pass: generate — but only if there is no partial already on disk.
  # A pre-existing partial (from an earlier script run) goes straight to
  # continuation so we never clobber progress with a fresh generation.
  if [[ ! -s "$out" ]]; then
    echo "== RUN   $name  ->  $out   (model=$MODEL)"
    _invoke "$out" "$base" || echo "   (nonzero exit on first pass — see logs; will attempt to continue)"
  else
    echo "== CONT  $name  ->  $out   (resuming existing partial)"
  fi

  # Continuation loop until the completion marker appears or attempts run out.
  local attempt=0
  while ! is_complete "$out" && (( attempt < MAX_CONT )); do
    attempt=$((attempt+1))
    echo "   .. incomplete; continuation attempt $attempt/$MAX_CONT"
    cp "$out" "$out.bak" 2>/dev/null || true
    _invoke "$out" "$base

CONTINUATION: The file '$out' already holds a PARTIAL version of this deliverable from a run that stopped early. Do NOT start over and do NOT rewrite or reproduce any text already in the file. Read '$out' only to find where it stops; if its last line is a '<!-- RESUME: ... -->' comment, follow it as your guide and delete that one comment line. Then APPEND the remaining content to the end of the file — using the Edit tool anchored on the file's current final lines, or a shell append ('>>') — continuing seamlessly from where it stops. Honor the COMPLETION CONTRACT above (write '<!-- REPORT-COMPLETE -->' only when the whole deliverable is finished)." \
      || echo "   (nonzero exit on continuation $attempt — see logs)"

    # Regression guard: never let a bad continuation shrink the partial.
    if ! is_complete "$out" && [[ -f "$out.bak" ]] && (( $(fsize "$out") < $(fsize "$out.bak") )); then
      echo "   (continuation regressed the file; restoring previous partial)"
      mv -f "$out.bak" "$out"
    else
      rm -f "$out.bak"
    fi
  done

  if is_complete "$out"; then
    echo "   OK   complete ($(fsize "$out") bytes)"
    return 0
  fi
  echo "   INCOMPLETE after $MAX_CONT continuation attempts: $out"
  return 1
}

# require  = blocking prerequisite: abort the script if it cannot complete.
# optional = leaf report: record it and keep going.
require()  { run_report "$1" "$2" || { echo; echo "ABORT: '$(basename "$1" .md)' feeds later reports and did not complete. Fix it (or raise MAX_TURNS / MAX_CONT) and re-run — complete reports are skipped, this one resumes from its partial."; exit 1; }; }
optional() { run_report "$1" "$2" || { echo "$(basename "$1" .md)" >> "$LOG_DIR/incomplete.txt"; echo "   -> recorded as incomplete (not a prerequisite); continuing."; }; }

# gate <what-to-review> — the one human checkpoint that matters
gate() {
  [[ "$SKIP_REVIEW" == "1" ]] && return 0
  echo
  echo "----------------------------------------------------------------------"
  echo "REVIEW: $1"
  echo "Check: Cyclone (not Fast DDS) confirmed and cyclonedds source present?"
  echo "       DEEP/MEDIUM/MENTION ranking right? reading order sound?"
  echo "       anchored on the real command topics? Humble type-NAME matching noted?"
  read -r -p "  Enter to continue, Ctrl-C to stop and fix it > " _ || true
  echo "----------------------------------------------------------------------"
}

# task_prompt <N> <title> [prereq_report ...]
task_prompt() {
  local n="$1" title="$2"; shift 2
  local reads="$REPORTS_DIR/foundation.md"
  local p; for p in "$@"; do reads="$reads, $p"; done
  cat <<EOF
$COMMON

Read first and reuse by reference (do NOT re-derive their content): $reads

TASK FOR THIS RUN: produce ONLY the report for Task $n ($title), exactly as specified under <the_five_tasks> in the instructions. Reuse the shared foundation by reference as described in <the_foundation_first>: do not re-derive the stack, publish path, matching rules, or discovery — cite the foundation instead. Open only the new-territory source files this task needs. Ground the report in the real command topics (/system/operation_mode/state and /control/command/gear_cmd) and end with the SEU implications drawn from the mechanism. Write the report to '$REPORTS_DIR/task-$n-report.md'.
EOF
}

echo "############ PHASE A — FOUNDATION (built once, then reviewed) ############"
FOUNDATION_PROMPT="$COMMON

TASK FOR THIS RUN: execute Phase 0 (reconnaissance) and Phase 1 (scoping gate), then build ONLY the shared foundation described under <the_foundation_first>: the layer map (rclcpp -> rcl -> rmw -> rmw_cyclonedds_cpp -> Cyclone ddsi -> RTPS), the publish path to the wire, the delivery-matching rules (topic-name mangling, type matching, and QoS compatibility including the transient_local durability rule the command topics require), discovery (SPDP/SEDP on multicast over lo, domain 0, GUIDs), and a seed glossary. At the very TOP of the file, present the DEEP/MEDIUM/MENTION ranking of all five tasks and the proposed reading order, so a human can review the scope. Write everything to '$REPORTS_DIR/foundation.md'. Do NOT produce any of the five task reports."
require "$REPORTS_DIR/foundation.md" "$FOUNDATION_PROMPT"
gate "the foundation and scope are in $REPORTS_DIR/foundation.md"

echo "############ PHASE B — TASK REPORTS (dependency order 1,2,5,3,4) ############"
# task-1, task-2, task-5 feed later reports -> blocking (require).
# task-3, task-4 are leaves -> non-blocking (optional).
require  "$REPORTS_DIR/task-1-report.md" "$(task_prompt 1 'configurable elements and element shutdown')"
[[ "$PAUSE_BETWEEN_TASKS" == "1" ]] && gate "$REPORTS_DIR/task-1-report.md" || true

require  "$REPORTS_DIR/task-2-report.md" "$(task_prompt 2 'data injection from a third-party element')"
[[ "$PAUSE_BETWEEN_TASKS" == "1" ]] && gate "$REPORTS_DIR/task-2-report.md" || true

require  "$REPORTS_DIR/task-5-report.md" "$(task_prompt 5 'QoS configuration in Cyclone DDS for prioritization')"
[[ "$PAUSE_BETWEEN_TASKS" == "1" ]] && gate "$REPORTS_DIR/task-5-report.md" || true

optional "$REPORTS_DIR/task-3-report.md" "$(task_prompt 3 'replay / over-publication' "$REPORTS_DIR/task-2-report.md" "$REPORTS_DIR/task-5-report.md")"
[[ "$PAUSE_BETWEEN_TASKS" == "1" ]] && gate "$REPORTS_DIR/task-3-report.md" || true

optional "$REPORTS_DIR/task-4-report.md" "$(task_prompt 4 'alternatives to shutdown at three layers' "$REPORTS_DIR/task-1-report.md" "$REPORTS_DIR/task-2-report.md" "$REPORTS_DIR/task-5-report.md")"

echo "############ PHASE C — CONSOLIDATION (index + glossary) ############"
CONSOLIDATE_PROMPT="$COMMON

TASK FOR THIS RUN: the Phase 3 cross-report pass. Read '$REPORTS_DIR/foundation.md' and every '$REPORTS_DIR/task-*.md'. Build the shared glossary (every internal term defined once), verify cross-references resolve, check that terminology is consistent and nothing is re-derived across reports, and write the index to '$REPORTS_DIR/00-index.md' containing: the objective and threat model (the AWSIM/Cyclone/loopback topology; the external element; the SEU defending a real vehicular network the sim stands in for), the task list with one-line summaries and dependencies, the shared glossary, and a pointer to the foundation. Do NOT rewrite the task reports; only fix a genuinely broken cross-reference, and record any inconsistency you cannot fix in the index."
optional "$REPORTS_DIR/00-index.md" "$CONSOLIDATE_PROMPT"

echo
if [[ -s "$LOG_DIR/incomplete.txt" ]]; then
  echo "== DONE, with incomplete (non-prerequisite) reports:"
  sed 's/^/   - /' "$LOG_DIR/incomplete.txt"
  echo "   Re-run to resume them (complete reports are skipped), or raise MAX_TURNS / MAX_CONT."
else
  echo "== DONE. All reports complete."
fi
echo "Reports in $REPORTS_DIR/ :"
ls -1 "$REPORTS_DIR"
