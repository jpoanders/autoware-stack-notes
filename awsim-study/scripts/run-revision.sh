#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-revision.sh — SAFETY-reframe sweep over the existing study corpus.
#
# Mirrors run-study.sh's fresh-context, marker-driven loop, but instead of
# GENERATING reports it REVISES the existing ones IN PLACE under the corrected
# premise: SEU = Safety Enforcement Unit (STL runtime verification of temporal /
# freshness constraints), not Security. Base instructions:
#   prompts/awsim-safety-revision-sweep-prompt.md
#
# Marker scheme (distinct from generation, since every file already ends with
# <!-- REPORT-COMPLETE --> from its original run):
#   * a file is "revised" only when it ends with <!-- SAFETY-REVISION-COMPLETE -->
#   * a run that stops early appends <!-- RESUME: ... --> instead; next run continues
# Re-running is safe: revised files are skipped, partials are continued.
# Originals are recoverable from git (corpus is committed).
#
#   ./run-revision.sh                 # normal run (dependency order)
#   FORCE=1 ./run-revision.sh         # re-revise even already-revised files (from git-clean originals)
#   MODEL=sonnet ./run-revision.sh    # cheaper/faster; opus is the default
#   MAX_TURNS=120 MAX_CONT=4 ./...    # give big files (wiki.md) more room
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-.}"
SRC="${SRC:-$PROJECT_ROOT/src}"
PROMPT_FILE="${PROMPT_FILE:-prompts/awsim-safety-revision-sweep-prompt.md}"
GUIDE="${GUIDE:-prompts/autoware-core-awsim-setup-guide.md}"
REPORTS_DIR="${REPORTS_DIR:-reports}"
LOG_DIR="${LOG_DIR:-logs}"
MODEL="${MODEL:-opus}"
MAX_TURNS="${MAX_TURNS:-100}"
MAX_CONT="${MAX_CONT:-4}"
TOOLS="${TOOLS:-Bash,Read,Grep,Glob,Write,Edit}"
PERM_MODE="${PERM_MODE:-acceptEdits}"
FORCE="${FORCE:-0}"

cd "$PROJECT_ROOT"
mkdir -p "$REPORTS_DIR" "$LOG_DIR"
: > "$LOG_DIR/revision-incomplete.txt"

command -v claude >/dev/null || { echo "ERROR: 'claude' not on PATH."; exit 1; }
[[ -f "$PROMPT_FILE" ]] || { echo "ERROR: revision prompt not found: $PROMPT_FILE"; exit 1; }
[[ -f "$GUIDE" ]]       || { echo "ERROR: setup guide not found: $GUIDE"; exit 1; }
[[ -d "$SRC" ]]         || { echo "ERROR: source dir not found: $SRC"; exit 1; }

DONE_MARK='SAFETY-REVISION-COMPLETE'
# new-framing evidence: the reframe must introduce the safety/STL vocabulary.
REFRAME_RE='STL|Signal Temporal|freshness|safe-stop|Safety Enforcement|temporal constraint|runtime verification|LSEU'

# marker present?
has_marker() { [[ -f "$1" ]] && grep -q "$DONE_MARK" "$1"; }
# reframe content actually landed? (>=4 hits of the new vocabulary)
has_reframe() { [[ -f "$1" ]] && [[ "$(grep -ciE "$REFRAME_RE" "$1")" -ge 4 ]]; }
# a file counts as revised only if BOTH the marker and real reframe content are present.
is_revised() { has_marker "$1" && has_reframe "$1"; }
# strip completion markers (NOT resume hints — the agent consumes those itself).
strip_markers() { [[ -f "$1" ]] && sed -i -E '/<!-- (REPORT-COMPLETE|SAFETY-REVISION-COMPLETE) -->/d' "$1"; }

COMMON="Study instructions: read the file '$PROMPT_FILE' in full and follow it exactly. This is a REVISION SWEEP: you are reframing an EXISTING report in place, not writing a new one.
Setup guide (AUTHORITATIVE runtime-config record, since the sim cannot be executed): read '$GUIDE' and cite it as 'setup-guide' where you rely on it.
Source repositories are under '$SRC/' — every non-obvious claim stays cited as path:line. The DDS vendor is Eclipse Cyclone DDS; never reintroduce Fast DDS assumptions.
Preserve every still-accurate path:line citation; replace the security framing with the safety/STL framing per the prompt. Do not fabricate the LSEU abstract's HIL measurements; cite them [LSEU-abstract].
COMPLETION CONTRACT for this sweep: the runner has ALREADY removed the file's old '<!-- REPORT-COMPLETE -->' line, so the file currently has NO trailing marker. Do NOT add any completion marker until the ENTIRE file is genuinely reframed — appending it early falsely signals done. Only as your VERY LAST action, once the whole file carries the safety/STL framing, append as the final line exactly this and nothing after it:
<!-- $DONE_MARK -->
If you must stop early, do NOT write that marker; instead append a single final line '<!-- RESUME: <the heading the reframe reached, and what is still in the OLD framing below it> -->' so the next run continues.
This is a SUBSTANTIVE reframe, not a marker swap: the finished file MUST replace the security framing (attacks/enforcement/threat) with the safety/STL framing (temporal & freshness constraints, STL properties, trace events, safe-stop) and MUST end each mechanism with the property/trace-event/safe-stop closing."

# _invoke <file> <prompt>
_invoke() {
  local out="$1" prompt="$2" name log
  name="$(basename "$out" .md)"; log="$LOG_DIR/revise-$name.$(date +%s).json"
  claude -p "$prompt" \
    --model "$MODEL" \
    --allowedTools "$TOOLS" \
    --permission-mode "$PERM_MODE" \
    --add-dir "$SRC" \
    --max-turns "$MAX_TURNS" \
    --output-format json \
    >"$log" 2>"${log%.json}.err"
}

# revise <file> <reframe-hint>
revise() {
  local out="$1" hint="$2" name attempt=0
  name="$(basename "$out" .md)"

  if is_revised "$out" && [[ "$FORCE" != "1" ]]; then
    echo "== SKIP  $out (already revised; FORCE=1 to redo)"; return 0
  fi
  if [[ "$FORCE" == "1" ]] && is_revised "$out"; then
    echo "== FORCE $out — restoring original from git before re-revising"
    git checkout -- "$out" 2>/dev/null || true
  fi
  [[ -f "$out" ]] || { echo "   MISSING: $out (nothing to revise)"; echo "$out (missing)" >>"$LOG_DIR/revision-incomplete.txt"; return 1; }

  # Clean the tail so the agent appends the completion marker only when truly done.
  # (Leaves a RESUME hint in place for a genuine partial from an earlier run.)
  if ! grep -q '<!-- RESUME:' "$out"; then strip_markers "$out"; fi

  local base="$COMMON

TASK FOR THIS RUN: revise ONLY the file '$out', in place, per the revision-sweep prompt.
REFRAME TARGET for this file: $hint
Read '$out' now to see its current (security-framed) content and to find any '<!-- RESUME: ... -->' hint from an earlier run; if present, delete that line and continue the reframe from there rather than restarting. Reuse reports/foundation.md by reference; do not re-derive the stack."

  echo "== RUN   $name  ->  $out   (model=$MODEL, max-turns=$MAX_TURNS)"
  _invoke "$out" "$base"

  while ! is_revised "$out" && (( attempt < MAX_CONT )); do
    attempt=$((attempt+1))
    # If the agent stamped the completion marker without doing the reframe,
    # the content guard failed: remove that false marker before continuing.
    if has_marker "$out" && ! has_reframe "$out"; then
      echo "   !! premature/no-op marker with no reframe content — stripping it"
      strip_markers "$out"
    fi
    echo "   .. incomplete; continuation attempt $attempt/$MAX_CONT"
    local cont="$COMMON

CONTINUATION: '$out' already holds a PARTIAL revision (top reframed, lower sections may still be in the OLD security framing). Do NOT restart and do NOT re-reframe sections already done. Read '$out' to find how far the reframe reached; if its last line is a '<!-- RESUME: ... -->' comment, follow it and delete that one line, then continue reframing the still-original sections below to the end of the file. REFRAME TARGET: $hint. Honor the COMPLETION CONTRACT (append '<!-- $DONE_MARK -->' only when the WHOLE file is reframed)."
    _invoke "$out" "$cont"
  done

  if is_revised "$out"; then
    echo "   OK: $out revised."
  else
    echo "   INCOMPLETE after $MAX_CONT continuations: $out"
    echo "$out" >>"$LOG_DIR/revision-incomplete.txt"
    return 1
  fi
}

echo "############ SAFETY-REFRAME SWEEP (dependency order) ############"

# foundation first — it seeds the new north-star layer every other file reuses.
revise "$REPORTS_DIR/foundation.md" \
  "add the data-dependency -> temporal-constraint (actuation freq + freshness) -> STL -> trace -> safe-stop layer ABOVE the existing stack material; re-point the DEEP/MEDIUM/MENTION ranking at how much each task informs the STL monitor." \
  || { echo "ABORT: foundation feeds every file and did not complete. Raise MAX_TURNS/MAX_CONT and re-run (revised files are skipped)."; exit 1; }

[[ "${STOP_AFTER:-}" == "foundation" ]] && { echo "STOP_AFTER=foundation — halting for inspection."; exit 0; }

revise "$REPORTS_DIR/task-1-report.md" \
  "LIVENESS / FRESHNESS LOSS: a silent source is the archetypal critical fault -> safe-stop; cover how absence manifests (deadline/liveliness) and how transient_local last-sample latching can MASK a dead publisher from a naive freshness monitor."

revise "$REPORTS_DIR/task-2-report.md" \
  "THE FAULT-INJECTION HARNESS: the injector is the study's TEST INSTRUMENT for feeding off-nominal timing/value traces to EXERCISE the monitor, not an attack."

revise "$REPORTS_DIR/task-5-report.md" \
  "TIMING DETERMINISM & MIXED-CRITICALITY: how Cyclone QoS (deadline, latency budget, priority, history/WHC) shapes latency/jitter and whether temporal constraints can be met on a resource-constrained multicore RISC-V without disturbing RT tasks [LSEU-abstract]."

revise "$REPORTS_DIR/task-3-report.md" \
  "FLAGSHIP over-publication: the abstract's 100x network over-publication stress case; actuation-frequency constraint violated; tie WHC/seqno/reorder to what the monitor sees and why evaluation stays linear [LSEU-abstract]." \
  || true

revise "$REPORTS_DIR/task-4-report.md" \
  "SILENT FRESHNESS LOSS + SAFE-STOP ACTUATION: the three layers as (a) freshness lost without a clean shutdown signal (hardest case for a monitor) and (b) candidate mechanisms to halt a data flow." \
  || true

revise "$REPORTS_DIR/00-index.md" \
  "recast the 'threat model' as a SAFETY/TEMPORAL-CONSTRAINT model; make the central artifact a catalog of the temporal/freshness (STL-shaped) properties cross-referenced to the mechanism that establishes each; append the explicit OUT-OF-SCOPE follow-on list (teach/, poc-roadmap+poc-recon.md, CLAUDE.md, master prompt, run-study.sh)." \
  || true

revise "$REPORTS_DIR/wiki.md" \
  "the ~1060-line source-of-record narrative: full safety/STL reframe, keeping every accurate citation; replace every 'what it means for the SEU' with property / trace-event / safe-stop." \
  || true

revise "$REPORTS_DIR/wiki_summary.md" \
  "condensed quick-read: reframe to safety/STL, consistent with the revised wiki.md." \
  || true

revise "source-code-study-summary.md" \
  "top-level English summary: rewrite the premise to the Safety Enforcement Unit / STL runtime-verification purpose." \
  || true

echo
if [[ -s "$LOG_DIR/revision-incomplete.txt" ]]; then
  echo "SWEEP DONE with incompletes:"; cat "$LOG_DIR/revision-incomplete.txt"
  echo "Re-run to resume them (revised files are skipped), or raise MAX_TURNS/MAX_CONT."
else
  echo "SWEEP COMPLETE — every file carries <!-- $DONE_MARK -->."
fi
