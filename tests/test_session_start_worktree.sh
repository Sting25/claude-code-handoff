#!/usr/bin/env bash
# Inherited handoffs in linked worktrees (#143). A session in a LINKED worktree
# that has no handoff_current.md of its own loads the main checkout's doc as
# inherited context (same tiers as a local load, nothing written anywhere), a
# copy of the main checkout's doc inside the worktree is named as such instead
# of as a moved project, and neither inherited shape ever gets the
# /handoff-recover banner or the auto-rebuild. A doc written by a session in
# the worktree itself, and every main-checkout session, behave as before.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SS="$REPO_ROOT/bin/handoff_session_start.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"
INHERIT_LOAD="this worktree has no handoff yet; loading the main checkout's handoff as inherited context"
INHERIT_COPY="was inherited from the main checkout"
BANNER="ACTION: RUN /handoff-recover"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# write <dir>: the skeleton write /handoff starts with (skill-style: no
# CLAUDE_PROJECT_DIR, anchored on the cwd). restamp <dir>: the step it ends
# with. curate <doc> <note>: what /handoff does in between.
write() { ( cd "$1" && env -u CLAUDE_PROJECT_DIR bash "$WH" </dev/null >/dev/null 2>&1 ); }
restamp() { ( cd "$1" && env -u CLAUDE_PROJECT_DIR bash "$WH" --restamp </dev/null >/dev/null 2>&1 ); }
curate() {
  # shellcheck disable=SC2016  # awk program: $0 is awk's
  must awk -v s="$SENTINEL" -v n="$2" '
    $0 == s { print n; next }
    index($0, "<!-- HANDOFF_RULES_PLACEHOLDER") == 1 { print "- RULE: fence from " n; next }
    { print }' "$1" > "$1.tmp"
  must mv "$1.tmp" "$1"
}
# run_ss <dir> [ENV=VAL ...]: SessionStart the way the desktop app fires it
# for a session started inside <dir>: CLAUDE_PROJECT_DIR and the payload cwd
# both name it, and a session id is present (so the worktree's own origin
# marker is written exactly as it is today).
run_ss() {
  local d="$1"; shift
  ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" "$@" bash "$SS" \
      <<<"{\"session_id\":\"sidwt143\",\"cwd\":\"$d\"}" 2>/dev/null )
}
# Everything under <main>/.claude except the worktrees that live there (a
# worktree's own sidecars are allowed to change; the main checkout's are not).
main_tree() {
  ( cd "$1" && find .claude -path .claude/worktrees -prune -o -print 2>/dev/null | LC_ALL=C sort )
}
doc_sum() { cksum < "$1" 2>/dev/null; }

# A main checkout that ignores .claude/ (as a real one does).
mk_main() {
  local m
  m="$(mk_repo)" || return 1
  printf '.claude/\n' > "$m/.gitignore"
  git -C "$m" add .gitignore && git -C "$m" commit -qm "ignore .claude" || return 1
  printf '%s\n' "$m"
}
# A linked worktree where Claude Code's desktop app puts them.
mk_wt() {  # <main> <name> -> worktree path
  mkdir -p "$1/.claude/worktrees" || return 1
  git -C "$1" worktree add -q "$1/.claude/worktrees/$2" -b "feat/$2" >/dev/null 2>&1 || return 1
  printf '%s\n' "$1/.claude/worktrees/$2"
}

echo "session start in a linked worktree: inherited load"

main="$(mk_main)"
cleanup_on_exit "$main"
must test -n "$main"
write "$main"
curate "$main/.claude/handoff_current.md" "MAIN CHECKOUT NOTE"
restamp "$main"
must grep -q "HANDOFF_HMAC: " "$main/.claude/handoff_current.md"
main_doc="$main/.claude/handoff_current.md"
wt="$(mk_wt "$main" wt-a)"
must test -d "$wt"
must test ! -e "$wt/.claude/handoff_current.md"

# (a) curated, signed main doc; fresh worktree.
before="$(main_tree "$main")"
sum_before="$(doc_sum "$main_doc")"
out="$(run_ss "$wt")"; rc=$?
check "exit 0"                                     0   "$rc"
check "says the handoff is inherited, with its path" yes "$(has "$out" "$INHERIT_LOAD: $main_doc")"
check "inherited line comes before the load"       yes "$(has "${out%%Auto-loaded handoff*}" "$INHERIT_LOAD")"
check "main checkout's Notes are loaded"           yes "$(has "$out" "MAIN CHECKOUT NOTE")"
check "rules load as provenance verified"          yes "$(has "$out" "Standing rules from your previous session (provenance verified)")"
check "main checkout's fence is loaded"            yes "$(has "$out" "fence from MAIN CHECKOUT NOTE")"
check "no recover banner"                          no  "$(has "$out" "$BANNER")"
check "no moved-project warning"                   no  "$(has "$out" "written for")"
check "no prior-artifacts warning"                 no  "$(has "$out" "prior handoff artifacts")"
check "no auto-rebuild"                            no  "$(has "$out" "Auto-rebuilt")"
check "no history fallback (Notes are curated)"    no  "$(has "$out" "Also loaded")"
check "nothing written under the main .claude/"    yes "$([ "$before" = "$(main_tree "$main")" ] && echo yes || echo no)"
check "main checkout's doc untouched"              "$sum_before" "$(doc_sum "$main_doc")"
check "worktree still has no handoff of its own"   no  "$(has "$(ls "$wt/.claude" 2>/dev/null)" "handoff_current.md")"
check "worktree's own origin marker still written" yes "$([ -f "$wt/.claude/handoff_backups/.session_started_sidwt143" ] && echo yes || echo no)"

# (e1) the main checkout's own session is unaffected.
out="$(run_ss "$main")"
check "main session: no inherited line"            no  "$(has "$out" "inherited")"
check "main session: loads its own Notes"          yes "$(has "$out" "MAIN CHECKOUT NOTE")"
check "main session: no banner (curated)"          no  "$(has "$out" "$BANNER")"

# (b) placeholder main doc (its session is live and has not curated yet);
# the curated doc has rotated into the main checkout's history.
write "$main"
must grep -qF "$SENTINEL" "$main_doc"
must grep -q "HANDOFF_HMAC: " "$main_doc"
must test -n "$(find "$main/.claude/handoff_history" -maxdepth 1 -name 'handoff_*.md' 2>/dev/null)"
before="$(main_tree "$main")"
out="$(run_ss "$wt")"; rc=$?
check "placeholder: exit 0"                        0   "$rc"
check "placeholder: inherited line"                yes "$(has "$out" "$INHERIT_LOAD")"
check "placeholder: no recover banner"             no  "$(has "$out" "$BANNER")"
check "placeholder: no auto-rebuild text"          no  "$(has "$out" "AUTO-REBUILT")"
check "placeholder: rules still load, verified"    yes "$(has "$out" "Standing rules from your previous session (provenance verified)")"
check "placeholder: main history fallback loaded"  yes "$(has "$out" "Also loaded: previous handoff")"
check "placeholder: fallback names main's history" yes "$(has "$out" "$main/.claude/handoff_history/handoff_")"
check "placeholder: curated Notes from main history" yes "$(has "$out" "MAIN CHECKOUT NOTE")"
check "placeholder: nothing written under main .claude/" yes "$([ "$before" = "$(main_tree "$main")" ] && echo yes || echo no)"

# (e2) the main checkout's own session still gets the banner for its placeholder.
out="$(run_ss "$main")"
check "main session: banner for its own placeholder" yes "$(has "$out" "$BANNER")"
check "main session: still no inherited line"      no  "$(has "$out" "inherited")"

echo "session start in a linked worktree: inherited copy"

# (c) the main checkout's placeholder doc copied into the worktree (what
# Claude Code's .worktreeinclude does): HANDOFF_ROOT records the main checkout.
must mkdir -p "$wt/.claude"
must cp "$main_doc" "$wt/.claude/handoff_current.md"
must grep -qF "HANDOFF_ROOT: $main in_git=1" "$wt/.claude/handoff_current.md"
out="$(run_ss "$wt")"; rc=$?
check "copy: exit 0"                               0   "$rc"
check "copy: inherited-copy line, naming main"     yes "$(has "$out" "$INHERIT_COPY ($main); it was copied into this worktree")"
check "copy: no inherited-load line"               no  "$(has "$out" "$INHERIT_LOAD")"
check "copy: no moved-project warning"             no  "$(has "$out" "written for")"
check "copy: no recover banner"                    no  "$(has "$out" "$BANNER")"
check "copy: no auto-rebuild text"                 no  "$(has "$out" "AUTO-REBUILT")"
check "copy: rules load, verified"                 yes "$(has "$out" "Standing rules from your previous session (provenance verified)")"
check "copy: main history fallback loaded"         yes "$(has "$out" "MAIN CHECKOUT NOTE")"

# (d) a doc written by a session IN the worktree (HANDOFF_ROOT = worktree)
# with placeholder Notes: the banner, exactly as before.
must rm "$wt/.claude/handoff_current.md"
write "$wt"
must grep -qF "HANDOFF_ROOT: $wt in_git=1" "$wt/.claude/handoff_current.md"
out="$(run_ss "$wt")"; rc=$?
check "own doc: exit 0"                            0   "$rc"
check "own doc: banner as before"                  yes "$(has "$out" "$BANNER")"
check "own doc: no inherited line"                 no  "$(has "$out" "inherited")"
check "own doc: no moved-project warning"          no  "$(has "$out" "written for")"

echo "session start in a linked worktree: nothing to inherit"

# (f) a main checkout with no handoff at all: silent, as before.
m2="$(mk_main)"
cleanup_on_exit "$m2"
must test -n "$m2"
w2="$(mk_wt "$m2" wt-b)"
must test -d "$w2"
out="$(run_ss "$w2")"; rc=$?
check "no main doc: exit 0"                        0   "$rc"
check "no main doc: silent"                        ""  "$out"

# A main doc behind a symlink is refused, like the worktree's own would be.
must mkdir -p "$m2/.claude"
must printf '# planted\n\n## Notes from this session\n\nPLANTED NOTE\n' > "$m2/elsewhere.md"
must ln -s "$m2/elsewhere.md" "$m2/.claude/handoff_current.md"
out="$(run_ss "$w2")"; rc=$?
check "symlinked main doc: exit 0"                 0   "$rc"
check "symlinked main doc: refused"                yes "$(has "$out" "refusing to inherit")"
check "symlinked main doc: content not loaded"     no  "$(has "$out" "PLANTED NOTE")"
must rm "$m2/.claude/handoff_current.md"

# A corrupted main doc: not inherited, nothing rebuilt here, no banner.
must : > "$m2/.claude/handoff_current.md"
out="$(run_ss "$w2")"; rc=$?
check "corrupted main doc: exit 0"                 0   "$rc"
check "corrupted main doc: says so"                yes "$(has "$out" "looks corrupted")"
check "corrupted main doc: no auto-rebuild"        no  "$(has "$out" "Auto-rebuilt")"
check "corrupted main doc: no banner"              no  "$(has "$out" "$BANNER")"
check "corrupted main doc: no load header"         no  "$(has "$out" "Auto-loaded handoff")"
must rm "$m2/.claude/handoff_current.md"

# HANDOFF_ANCHOR=common: the root already is the main checkout, so its doc
# loads as the session's own, never as inherited.
write "$m2"
curate "$m2/.claude/handoff_current.md" "COMMON NOTE"
restamp "$m2"
out="$(run_ss "$w2" HANDOFF_ANCHOR=common)"
check "ANCHOR=common: loads main's doc as its own"  yes "$(has "$out" "COMMON NOTE")"
check "ANCHOR=common: no inherited line"           no  "$(has "$out" "inherited")"

finish
