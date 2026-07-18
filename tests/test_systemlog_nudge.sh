#!/usr/bin/env bash
# Behavioral coverage for the handoff-time "System-log nudge" in write_handoff.sh
# (~L412-434), which had no tests. The nudge fires into the new handoff doc ONLY
# when, across this session's commits (prev_head..HEAD):
#   - the prior handoff recorded a parseable HEAD (prev_head non-empty), AND
#   - the system log file exists, AND
#   - at least one commit looks system-level (a sys path like install.sh /
#     AGENTS.md / .github/workflows, OR a subject matching secur|migrat|… ), AND
#   - none of the commits touched the system log itself.
# It is a nudge, not a gate: every gating condition gets a negative control here.
#
# Observable: presence/absence of the "## ⚠️ System-log nudge" section in the
# freshly written .claude/handoff_current.md.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# Build a repo, seed the prior handoff's HEAD line, make one "session" commit,
# run write_handoff, and echo the resulting handoff doc. Args:
#   <syscommit yes|no>  — commit subject is system-level (security:) vs docs:
#   <log_present yes|no>— whether SYSTEM_LOG.md exists at run time
#   <touch_log yes|no>  — whether the session commit also edits SYSTEM_LOG.md
nudge_doc() {
  local syscommit="$1" log_present="$2" touch_log="$3" repo c1 subj
  repo="$(mk_repo)"
  if [[ "$log_present" == yes ]]; then
    printf '# system log\n' > "$repo/SYSTEM_LOG.md"
    git -C "$repo" add SYSTEM_LOG.md && git -C "$repo" commit -qm "add system log"
  fi
  c1="$(git -C "$repo" rev-parse HEAD)"
  # Seed the prior handoff so write_handoff parses prev_head = c1 from its HEAD line.
  mkdir -p "$repo/.claude"
  # shellcheck disable=SC2016  # backticks are literal markdown, matching write_handoff's HEAD-line format
  printf '**HEAD:** `%s` — prior session\n' "$c1" > "$repo/.claude/handoff_current.md"
  # The session's commit (prev_head..HEAD).
  echo change > "$repo/feature.txt"; git -C "$repo" add feature.txt
  if [[ "$touch_log" == yes ]]; then
    printf 'entry\n' >> "$repo/SYSTEM_LOG.md"; git -C "$repo" add SYSTEM_LOG.md
  fi
  subj="docs: tweak wording"
  [[ "$syscommit" == yes ]] && subj="security: harden the auth path"
  git -C "$repo" commit -qm "$subj"
  ( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_HISTORY_KEEP=0 \
      bash "$WH" >/dev/null 2>&1; cat "$repo/.claude/handoff_current.md" )
  rm -rf "$repo"
}

echo "write_handoff.sh — system-log nudge (fires only when all gates hold)"

# --- Positive: system-level commit, log present, log untouched -> nudge ------
check "system commit + untouched log -> nudge" \
  yes "$(has "$(nudge_doc yes yes no)" "System-log nudge")"

# --- Negative: log file absent -> inert --------------------------------------
check "no system log file -> no nudge" \
  no  "$(has "$(nudge_doc yes no no)" "System-log nudge")"

# --- Negative: the session DID touch the system log -> suppressed ------------
check "system commit touched log -> no nudge" \
  no  "$(has "$(nudge_doc yes yes yes)" "System-log nudge")"

# --- Negative: commit isn't system-level (docs:, no sys path) -> no nudge ----
check "non-system commit -> no nudge" \
  no  "$(has "$(nudge_doc no yes no)" "System-log nudge")"

# --- Negative: no prior HEAD (no existing handoff) -> nudge skipped ----------
# Without a prev_head to diff against, the range is undefined; the guard skips.
repo="$(mk_repo)"
printf '# system log\n' > "$repo/SYSTEM_LOG.md"
git -C "$repo" add SYSTEM_LOG.md && git -C "$repo" commit -qm "add system log"
echo change > "$repo/feature.txt"; git -C "$repo" add feature.txt
git -C "$repo" commit -qm "security: harden the auth path"
# No .claude/handoff_current.md seeded -> prev_head stays empty.
doc="$( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_HISTORY_KEEP=0 \
        bash "$WH" >/dev/null 2>&1; cat "$repo/.claude/handoff_current.md" )"
check "no prior HEAD -> no nudge" no "$(has "$doc" "System-log nudge")"
rm -rf "$repo"

finish
