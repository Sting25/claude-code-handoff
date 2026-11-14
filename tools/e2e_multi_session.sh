#!/usr/bin/env bash
# shellcheck disable=SC2329  # the measurement predicates are called indirectly, by name, through count_over and yn
# tools/e2e_multi_session.sh: the release-fence multi-session e2e driver (#203).
#
#   bash tools/e2e_multi_session.sh [options] <tree> [<outdir>]
#
#   <tree>     the exact tree under release (a checkout holding install.sh and
#              bin/). Its installer is run for real, inside a jail.
#   <outdir>   where results go; must not exist yet, or be an empty directory.
#              Default: a fresh mktemp directory (printed at the end).
#
#   --variant NAME   run only this variant (repeatable). Default: all of
#                    baseline notesonly worktree prune trimmer.
#   --keep-jails     keep each variant's jailed HOME and project for debugging
#                    (default: removed when the variant finishes).
#   --allow-dirty    run on a tree with uncommitted changes, or one that is not
#                    a git checkout (for red runs on a mutated copy). Without
#                    it such a tree is refused: the fence is a run on the
#                    exact release tree, and results.md records its HEAD.
#   -h, --help       this text.
#
# What it proves. Before a release, a fresh multi-session run on the release
# tree: session A curates (Notes, and Rules fences where the variant says),
# sessions B..J never curate, K only starts. The expected outcomes recorded in
# #203 (the 2026-11-10 run on b7b0a4e) are asserted after every variant, and
# the driver exits non-zero, naming each failed check, when any does not hold.
#
# How it is wired. The real installer runs jailed:
#   HOME=<jail> CLAUDE_HOME=<jail>/.claude bash <tree>/install.sh --scope project --project <proj>
# Each hook's command string is then read from the jailed project's
# .claude/settings.json with jq and run with `bash -c`, after stripping the
# trailing `|| true` and the stdout/stderr redirections so the exit code and
# stderr are recorded (the verbatim strings are not exercised, see #203 "Not
# covered"). Every call runs under `env -i` with HOME, CLAUDE_PROJECT_DIR and
# HANDOFF_SECRET_FILE pointing into the jail, so nothing from the invoking
# environment (a real ~/.claude, a real project, HANDOFF_* overrides) can leak
# in. Hooks run with CLAUDE_CODE_SESSION_ID unset (they get the id from the
# payload); the skill-side write and restamp get it set, as Claude Code's Bash
# tool does. A 1 s sleep follows every doc write so the next writer's stamps
# are strictly later than the previous one.
#
# Session shapes. A: SessionStart, 2 Stop turns, the skill's write, curate
# (the Notes and Rules placeholder lines replaced by sed-style edits),
# --restamp, SessionEnd. B..J: SessionStart, 3 Stop turns, SessionEnd. E also
# fires PreCompact, PostCompact and SessionStart(source=compact). K:
# SessionStart only. Variants:
#   baseline   A curates Notes and Rules.
#   notesonly  A curates Notes only (no fence anywhere, by design).
#   worktree   as baseline, but F runs in a linked worktree with the desktop
#              payload shape, then WorktreeRemove fires and it is removed.
#   prune      HANDOFF_HISTORY_KEEP=1: A1 and A2 curate Notes and Rules, A3
#              Rules only, then B, C, K.
#   trimmer    as baseline with HANDOFF_SS_MAX_BYTES=2000, so the SessionStart
#              trimmer runs.
#
# SIGPIPE: CI runners start jobs with SIGPIPE ignored, and a shell cannot
# un-ignore a signal it inherited ignored, so every hook runs through perl
# with SIGPIPE reset to default. Claude Code's own child processes start with
# the default disposition, so this matches the real environment instead of
# hiding a failure.
#
# The jails live in a separate mktemp dir under TMPDIR (removed on exit
# unless --keep-jails); outdir holds only the results.
#
# Output: <outdir>/results.md (the table to paste into the release PR body),
# <outdir>/<variant>/calls.tsv and calls/NNN_* (per-call payload, stdout,
# stderr, rc), plus <outdir>/<variant>/snap/ (doc and history listings at each
# checkpoint). Exit status: 0 when every check held, 1 when any failed, 2 on
# a usage or setup error. Not run in CI by default: it sleeps on purpose
# (about two and a half minutes of wall time for all five variants) and needs
# jq, git, openssl and perl.
set -uo pipefail

usage() { sed -n '3,/^set -uo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

die() { printf 'e2e_multi_session: %s\n' "$*" >&2; exit 2; }

all_variants="baseline notesonly worktree prune trimmer"
variants=""
keep_jails=0
allow_dirty=0
tree=""
outdir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --variant)
      [ $# -ge 2 ] || die "--variant needs a name"
      case " $all_variants " in *" $2 "*) ;; *) die "unknown variant '$2' (known: $all_variants)" ;; esac
      variants="$variants $2"; shift 2 ;;
    --keep-jails) keep_jails=1; shift ;;
    --allow-dirty) allow_dirty=1; shift ;;
    --) shift; break ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *)
      if [ -z "$tree" ]; then tree="$1"
      elif [ -z "$outdir" ]; then outdir="$1"
      else die "too many arguments (see --help)"; fi
      shift ;;
  esac
done
[ -n "$variants" ] || variants="$all_variants"
[ -n "$tree" ] || { usage >&2; exit 2; }

# --- preflight ---------------------------------------------------------------
phys() { if [ -d "$1" ]; then (cd "$1" && pwd -P); fi; }
for dep in jq git openssl perl cksum awk sed; do
  command -v "$dep" >/dev/null 2>&1 || die "missing dependency: $dep"
done
[ -f "$tree/install.sh" ] && [ -d "$tree/bin" ] || die "'$tree' does not look like a claude-code-handoff tree (no install.sh or bin/)"
tree="$(cd "$tree" && pwd -P)" || die "cannot resolve tree '$tree'"
tree_head="$(git -C "$tree" rev-parse HEAD 2>/dev/null || echo unknown)"
tree_dirty="$(git -C "$tree" status --porcelain 2>/dev/null | grep -c . || true)"
tree_top="$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$tree_top" ] || tree_top="$(phys "$tree_top")"
if [ "$tree_top" != "$tree" ]; then
  [ "$allow_dirty" -eq 1 ] || die "'$tree' is not a git checkout, so its exact state cannot be recorded; refusing (--allow-dirty overrides, for red runs)"
  tree_dirty="not a git checkout"
elif [ "$tree_dirty" -ne 0 ]; then
  [ "$allow_dirty" -eq 1 ] || die "'$tree' has $tree_dirty uncommitted path(s); the fence runs on the exact release tree. Commit or stash, or pass --allow-dirty (for red runs)"
fi

# Physical paths of the invoking HOME and of every Claude config dir it may
# use: $HOME/.claude (a symlink is followed, so its target is guarded too) and
# $CLAUDE_CONFIG_DIR when set. Both the logical and the physical spelling of
# each are refused below.
real_home="${HOME:-}"
real_home_p=""
[ -n "$real_home" ] && real_home_p="$(phys "$real_home")"
guarded_dirs=""
for g in ${real_home:+"$real_home/.claude"} ${real_home_p:+"$real_home_p/.claude"} ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR"}; do
  guarded_dirs="$guarded_dirs
$g"
  gp="$(phys "$g")"
  [ -n "$gp" ] && guarded_dirs="$guarded_dirs
$gp"
done

# Resolve outdir BEFORE creating anything, so a refused path is never made.
# Refuse an outdir that IS the invoking HOME or sits inside its .claude/, and
# one inside the tree under test: the hooks only ever see the jail's HOME, but
# a mistake in this driver must not be able to reach a real install or dirty
# the release tree.
if [ -z "$outdir" ]; then
  outdir="$(mktemp -d "${TMPDIR:-/tmp}/handoff-e2e.XXXXXX")" || die "mktemp failed"
fi
if [ -e "$outdir" ]; then
  [ -d "$outdir" ] || die "outdir '$outdir' exists and is not a directory"
  [ -z "$(ls -A "$outdir" 2>/dev/null)" ] || die "outdir '$outdir' is not empty; give a fresh path"
  outdir_p="$(cd "$outdir" && pwd -P)" || die "cannot resolve outdir '$outdir'"
else
  parent="$(dirname "$outdir")"
  [ -d "$parent" ] || die "outdir's parent '$parent' does not exist"
  outdir_p="$(cd "$parent" && pwd -P)/$(basename "$outdir")" || die "cannot resolve outdir '$outdir'"
fi
if [ -n "$real_home_p" ]; then
  [ "$outdir_p" != "$real_home_p" ] || die "outdir is the invoking HOME; refusing"
fi
while IFS= read -r g; do
  [ -n "$g" ] || continue
  case "$outdir_p/" in "${g%/}/"*) die "outdir is inside a Claude config dir ($g); refusing" ;; esac
done <<EOT
$guarded_dirs
EOT
case "$outdir_p/" in "$tree/"*) die "outdir is inside the tree under test; refusing" ;; esac
mkdir -p "$outdir_p" || die "cannot create outdir '$outdir_p'"
outdir="$outdir_p"

# The jails (HOME, project, secret, TMPDIR) live in their own temp dir, not in
# outdir: the installed hook strings are `bash $HOME/.claude/bin/...` with
# $HOME unquoted, so a HOME holding whitespace breaks every hook (exit 127).
# outdir may hold spaces; the jail base must not.
jail_base="$(mktemp -d "${TMPDIR:-/tmp}/handoff-e2e-jail.XXXXXX")" || die "mktemp for the jail failed"
jail_base="$(phys "$jail_base")"
case "$jail_base" in *[[:space:]]*) rm -rf "$jail_base"; die "jail dir '$jail_base' holds whitespace (the hook strings cannot run there); set TMPDIR to a path without spaces" ;; esac
while IFS= read -r g; do
  [ -n "$g" ] || continue
  case "$jail_base/" in "${g%/}/"*) rm -rf "$jail_base"; die "jail dir is inside a Claude config dir ($g); set TMPDIR elsewhere" ;; esac
done <<EOT
$guarded_dirs
EOT

start_epoch="$(date +%s)"

# --- per-variant state -------------------------------------------------------
V=""        # variant name
VD=""       # <outdir>/<variant>: logs and snapshots
JB=""       # <jail_base>/<variant>: the jailed HOME, project, secret, TMPDIR
JH=""       # jailed HOME
PROJ=""     # jailed project (main checkout)
WT=""       # linked worktree (worktree variant)
SECRET=""   # HANDOFF_SECRET_FILE
seq_n=0
extra_env=()

fail_total=0
results_rows=""

note() { printf '[%s] %s\n' "$V" "$*"; }

# Remove the current variant's jail on any exit (a failed check, a die, ^C),
# unless --keep-jails. Results and per-call logs stay in outdir.
on_exit() {
  if [ -n "$VD" ]; then teardown_variant; fi
  if [ "$keep_jails" -eq 1 ]; then
    printf 'e2e_multi_session: jails kept under %s\n' "$jail_base" >&2
  else
    rm -rf "$jail_base"
  fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# Every path a hook can be pointed at must be inside the variant's jail.
assert_jailed() {
  case "$1/" in "$JB/"*) ;; *) die "internal: '$1' is outside the jail $JB" ;; esac
  if [ -n "$real_home_p" ]; then
    [ "$1" != "$real_home_p" ] || die "internal: refusing to run with the invoking HOME"
  fi
}

# Hook command string for <event>, from the jailed settings.json, with the
# trailing `|| true` and the redirections stripped. Refuses anything that is
# not `bash $HOME/.claude/bin/<script>.sh [--flag...]`.
hook_cmd() {
  local raw cmd
  raw="$(jq -r --arg e "$1" '.hooks[$e][]?.hooks[]?.command // empty' "$PROJ/.claude/settings.json" | grep -F '/.claude/bin/' | head -n 1)"
  [ -n "$raw" ] || die "no $1 hook in $PROJ/.claude/settings.json"
  cmd="$(printf '%s' "$raw" | sed -E 's/[[:space:]]*\|\|[[:space:]]*true[[:space:]]*$//; s/[[:space:]]*>\/dev\/null[[:space:]]+2>&1//g; s/[[:space:]]*2>\/dev\/null//g')"
  # shellcheck disable=SC2016  # a regex matching a literal $HOME in the command string
  printf '%s' "$cmd" | grep -Eq '^bash \$HOME/\.claude/bin/[a-z_]+\.sh( --[a-z-]+)*$' \
    || die "unexpected $1 hook command shape: $raw"
  printf '%s' "$cmd"
}

# run_call <session> <event> <cwd> <payload|-> <command...>
# Runs one call jailed, records payload/stdout/stderr/rc and a calls.tsv row.
# The command runs via perl so SIGPIPE starts at its default disposition.
run_call() {
  local sess="$1" ev="$2" cwd="$3" payload="$4"; shift 4
  local tag rc out err
  seq_n=$((seq_n + 1))
  tag="$(printf '%03d_%s_%s' "$seq_n" "$sess" "$ev")"
  out="$VD/calls/$tag.out"; err="$VD/calls/$tag.err"
  assert_jailed "$JH"; assert_jailed "$cwd"
  if [ "$payload" = "-" ]; then : > "$VD/calls/$tag.in"; else printf '%s' "$payload" > "$VD/calls/$tag.in"; fi
  # shellcheck disable=SC2016  # the perl program is single-quoted on purpose: perl expands it, not this shell
  ( cd "$cwd" && env -i \
      PATH="$PATH" HOME="$JH" TMPDIR="$JB/tmp" LANG="${LANG:-C}" \
      CLAUDE_PROJECT_DIR="$PROJ" HANDOFF_SECRET_FILE="$SECRET" \
      GIT_CONFIG_NOSYSTEM=1 \
      ${extra_env[@]+"${extra_env[@]}"} \
      perl -e '$SIG{PIPE}="DEFAULT"; exec @ARGV or die "exec: $!\n"' "$@" \
      <"$VD/calls/$tag.in" >"$out" 2>"$err" )
  rc=$?
  printf '%s\n' "$rc" > "$VD/calls/$tag.rc"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$seq_n" "$sess" "$ev" "$rc" \
    "$(wc -c < "$out" | tr -d ' ')" "$(wc -c < "$err" | tr -d ' ')" >> "$VD/calls.tsv"
  LAST_OUT="$out"
  return 0
}

# Skill-side calls (the /handoff skill's write and restamp) run the way the
# skill runs them inside Claude Code's Bash tool: from the project dir, with
# no CLAUDE_PROJECT_DIR, stdin /dev/null, and CLAUDE_CODE_SESSION_ID set to the
# session's id (the Bash tool exports it; hooks get it from the payload, which
# is why hook calls run with it unset). The write passes --session-id, as the
# skill does when that variable is set; the restamp relies on the env.
run_skill() {  # <session> <label> [write_handoff.sh args...]
  local sess="$1" ev="$2"; shift 2
  # shellcheck disable=SC2016  # the inner bash expands $1 and $@, not this shell
  run_call "$sess" "$ev" "$PROJ" - \
    bash -c 'unset CLAUDE_PROJECT_DIR; export CLAUDE_CODE_SESSION_ID="$1"; shift; exec bash "$@"' _ \
    "$(sid_of "$sess")" "$JH/.claude/bin/write_handoff.sh" "$@"
}

sid_of() { printf 'e2e-%s-%s' "$V" "$1"; }
tx_of() { printf '%s/.claude/projects/e2e/%s.jsonl' "$JH" "$(sid_of "$1")"; }
json_str() { jq -Rn --arg s "$1" '$s'; }

hook() {  # <session> <event> <payload-cwd> <extra payload json fields>
  local sess="$1" ev="$2" pcwd="$3" extra="$4" cmd payload
  cmd="$(hook_cmd "$ev")" || exit 2
  payload="{\"session_id\":$(json_str "$(sid_of "$sess")"),\"transcript_path\":$(json_str "$(tx_of "$sess")"),\"cwd\":$(json_str "$pcwd"),\"hook_event_name\":\"$ev\"${extra:+,$extra}}"
  # Process cwd is the main checkout (the desktop shape for a worktree
  # session: process cwd main, payload cwd worktree).
  run_call "$sess" "$ev" "$PROJ" "$payload" bash -c "$cmd"
}

ss() {
  hook "$1" SessionStart "${2:-$PROJ}" "\"source\":\"${3:-startup}\""
  eval "SS_$1=\$LAST_OUT"
  keep_trim_refs "$1" "$LAST_OUT"
}
# A trimmed section names its full file ("Full text: `<path>`"). Copy each
# named file at load time (the doc is rewritten later) so the checks can ask
# whether trimmed text stayed reachable; count names that do not resolve.
# shellcheck disable=SC2016  # the backticks in the sed pattern below are literal
keep_trim_refs() {  # <session> <ss output>
  local p n=0 miss=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in /*) ;; *) p="$PROJ/$p" ;; esac
    n=$((n + 1))
    if [ -f "$p" ]; then cp "$p" "$VD/snap/trimref_$1_$n"; else miss=$((miss + 1)); fi
  done <<EOT
$(LC_ALL=C sed -nE 's/.*\[handoff: trimmed [0-9]+ of [0-9]+ bytes.* Full text: `([^`]+)`.*/\1/p' "$2")
EOT
  eval "TRIMREFS_$1=$n; TRIMMISS_$1=$miss"
}
stop_turn() {  # <session> <turn> [payload-cwd]
  local tx; tx="$(tx_of "$1")"
  mkdir -p "$(dirname "$tx")"
  printf '{"type":"user","message":{"role":"user","content":"prompt %s from session %s"}}\n' "$2" "$1" >> "$tx"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reply %s from session %s"}]}}\n' "$2" "$1" >> "$tx"
  hook "$1" Stop "${3:-$PROJ}" '"stop_hook_active":false'
}
send() { hook "$1" SessionEnd "${2:-$PROJ}" '"reason":"prompt_input_exit"'; sleep 1; }

doc() { printf '%s/.claude/handoff_current.md' "$PROJ"; }
hist_dir() { printf '%s/.claude/handoff_history' "$PROJ"; }
hist_files() { find "$(hist_dir)" -maxdepth 1 -type f -name 'handoff_*.md' 2>/dev/null | LC_ALL=C sort; }
hist_count() { hist_files | grep -c . || true; }

# Snapshot doc + history at a checkpoint for the record.
snap() {
  local d="$VD/snap/$1"
  mkdir -p "$d"
  [ -f "$(doc)" ] && cp "$(doc)" "$d/handoff_current.md"
  { hist_files; find "$(hist_dir)/worktrees" -type f 2>/dev/null | LC_ALL=C sort; } > "$d/history.txt"
  if [ -d "$(hist_dir)" ]; then mkdir -p "$d/history" && cp -R "$(hist_dir)/." "$d/history/" 2>/dev/null; fi
  return 0
}

# Curate the current doc as session <S>: replace the Notes sentinel line and,
# when <rules>=1, the Rules placeholder line. The two lines are matched by
# their sentinel comments, exactly as the /handoff skill is told to.
curate() {  # <session> <notes:0|1> <rules:0|1> <cwd>
  local d="$4/.claude/handoff_current.md"
  awk -v s="$1" -v n="$2" -v r="$3" '
    n == 1 && $0 == "<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->" { print "NOTES_" s ": curated note from session " s "."; next }
    r == 1 && index($0, "<!-- HANDOFF_RULES_PLACEHOLDER") == 1 { print "- FENCE_" s ": do not start the frobnicator migration (fence from session " s ")."; next }
    { print }' "$d" > "$d.e2e.tmp" && mv "$d.e2e.tmp" "$d"
  seq_n=$((seq_n + 1))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$seq_n" "$1" curate 0 0 0 >> "$VD/calls.tsv"
}

# Session A shape: SessionStart, 2 Stop turns, write, curate, restamp, SessionEnd.
session_curator() {  # <session> <notes> <rules>
  ss "$1"
  stop_turn "$1" 1; stop_turn "$1" 2
  after_stops "$1" 2
  run_skill "$1" write --session-id "$(sid_of "$1")"; sleep 1
  curate "$1" "$2" "$3" "$PROJ"
  run_skill "$1" restamp --restamp; sleep 1
  send "$1"
}
# B..J shape: SessionStart, 3 Stop turns, SessionEnd. Never curates.
session_plain() {  # <session> [payload-cwd]
  ss "$1" "${2:-$PROJ}"
  stop_turn "$1" 1 "${2:-$PROJ}"; stop_turn "$1" 2 "${2:-$PROJ}"; stop_turn "$1" 3 "${2:-$PROJ}"
  after_stops "$1" 3 "${2:-$PROJ}"
  send "$1" "${2:-$PROJ}"
}

setup_variant() {
  V="$1"; VD="$outdir/$V"; seq_n=0; extra_env=()
  JB="$jail_base/$V"
  JH="$JB/home"; PROJ="$JB/proj"; WT=""; SECRET="$JB/secret/handoff_secret"
  mkdir -p "$VD/calls" "$VD/snap" "$JB/tmp" "$JH" "$JB/secret" "$PROJ" || die "mkdir failed"
  : > "$VD/calls.tsv"
  local gitenv=(env -i PATH="$PATH" HOME="$JH" GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.invalid
    GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.invalid)
  ( cd "$PROJ" && "${gitenv[@]}" git init -q && printf 'e2e fixture\n' > README.md \
      && printf '.claude/worktrees/\n' > .gitignore \
      && "${gitenv[@]}" git add README.md .gitignore && "${gitenv[@]}" git commit -q -m "e2e fixture" ) \
    || die "fixture repo setup failed"
  env -i PATH="$PATH" HOME="$JH" CLAUDE_HOME="$JH/.claude" TMPDIR="$JB/tmp" LANG="${LANG:-C}" \
    bash "$tree/install.sh" --scope project --project "$PROJ" </dev/null > "$VD/install.out" 2>&1
  INSTALL_RC=$?
  [ "$INSTALL_RC" -eq 0 ] || note "installer exited $INSTALL_RC (see $VD/install.out)"
  [ -f "$PROJ/.claude/settings.json" ] || die "[$V] installer wrote no $PROJ/.claude/settings.json"
  # Every event the scenarios fire must be wired, in the expected shape.
  local ev
  for ev in SessionStart Stop SessionEnd PreCompact PostCompact WorktreeRemove; do
    hook_cmd "$ev" > /dev/null || exit 2
  done
}

teardown_variant() {
  if [ "$keep_jails" -eq 1 ]; then return 0; fi
  if [ -n "$WT" ] && [ -d "$WT" ]; then git -C "$PROJ" worktree remove --force "$WT" >/dev/null 2>&1 || true; fi
  rm -rf "$JB"
}

# --- measurements ------------------------------------------------------------
ss_out() { eval "printf '%s' \"\${SS_$1:-}\""; }
yn() { if "$@"; then echo yes; else echo no; fi; }
has_notes() { [ -f "$1" ] && LC_ALL=C grep -q "^NOTES_$2: " "$1"; }
# The fence is bound when its line sits inside a TRUSTED block of the
# SessionStart output: from a "## ...Standing rules..." heading (the verified
# load, or the post-compaction re-inject) to the next `---` rule.
fence_bound() {  # <ss output> <session that wrote the fence>
  [ -f "$1" ] && LC_ALL=C awk -v f="- FENCE_$2: " '
    /^## .*Standing rules/ { t = 1; next }
    t && /^---$/ { t = 0 }
    t && index($0, f) == 1 { hit = 1 }
    END { exit hit ? 0 : 1 }' "$1"
}
# Notes reachable: inline in the load, or in a file one of its trim notices named.
notes_reachable() {  # <ss output> <session>
  local f s
  has_notes "$1" "$2" && return 0
  s="${1##*/}"; s="${s#*_}"; s="${s%_SessionStart.out}"
  for f in "$VD/snap/trimref_${s}_"*; do has_notes "$f" "$2" && return 0; done
  return 1
}
over_budget_warned() {  # <ss output> <budget>: an over-budget load must say so
  [ "$(bytes "$1")" -le "$2" ] && return 0
  LC_ALL=C grep -q "still over the $2-byte budget after trimming" "$1"
}
trim_noticed() { LC_ALL=C grep -q '^⚠️  handoff: this startup output was trimmed' "$1" && [ "$(trimmed_count "$1")" -gt 0 ]; }
fence_anywhere() { [ -f "$1" ] && LC_ALL=C grep -q -- "- FENCE_$2: " "$1"; }
trimmed_count() { LC_ALL=C grep -c '\[handoff: trimmed ' "$1" 2>/dev/null || true; }
bind_lines() { LC_ALL=C grep -c 'HANDOFF_BIND_' "$1" 2>/dev/null || true; }
bytes() { wc -c < "$1" | tr -d ' '; }
# History file written by session <S> (its HANDOFF_WRITER marker), if any.
hist_by_sid() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if LC_ALL=C grep -q "^<!-- HANDOFF_WRITER: sid=$(sid_of "$1") " "$f"; then echo "$f"; fi
  done <<EOT
$(hist_files)
EOT
}
# The history file a SessionStart fallback named ("_From `handoff_....md`").
fallback_name() {
  # shellcheck disable=SC2016  # the backticks in the pattern are literal
  LC_ALL=C sed -n '/^## Also loaded: previous handoff/,$p' "$1" 2>/dev/null \
    | LC_ALL=C sed -nE 's/^_From `(handoff_[0-9_-]+\.md)`.*/\1/p' | head -n 1
}
# A doc's "carried forward" label is accurate when it claims "archived in
# handoff_history/" exactly when the source doc (sid + t) is in history.
archive_claim_ok() {
  local d line src t in_hist=no claims=no f
  d="$(doc)"
  line="$(LC_ALL=C grep -E '^<!-- HANDOFF_RULES_CARRIED: ' "$d" 2>/dev/null | tail -n 1)"
  [ -n "$line" ] || return 0
  src="$(printf '%s' "$line" | LC_ALL=C sed -nE 's/.* sid=([A-Za-z0-9_-]+) t=([0-9]+).*/\1/p')"
  t="$(printf '%s' "$line" | LC_ALL=C sed -nE 's/.* sid=([A-Za-z0-9_-]+) t=([0-9]+).*/\2/p')"
  [ -n "$src" ] && [ -n "$t" ] || return 1
  case "$line" in *"archived in handoff_history/"*) claims=yes ;; esac
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if LC_ALL=C grep -qx "<!-- HANDOFF_WRITER: sid=$src t=$t -->" "$f"; then in_hist=yes; fi
  done <<EOT
$(hist_files)
EOT
  [ "$claims" = "$in_hist" ]
}
# A history snapshot is placeholder-only when neither its Notes nor its Rules
# were curated: both sentinels still present.
placeholder_only_archived() {
  local f n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if LC_ALL=C grep -q '^<!-- HANDOFF_PLACEHOLDER: ' "$f" && LC_ALL=C grep -q '^<!-- HANDOFF_RULES_PLACEHOLDER' "$f"; then n=$((n + 1)); fi
  done <<EOT
$(hist_files)
EOT
  echo "$n"
}
after_end() {  # <session>: record history count and label accuracy right after its end
  eval "HIST_$1=$(hist_count)"
  eval "HSIDS_$1=\"$(hist_sids)\""
  eval "ARCH_$1=$(yn archive_claim_ok)"
  snap "$1"
}

# --- checks ------------------------------------------------------------------
vchecks=""
vfail=0
check() {  # <name> <expected> <measured>
  local st=PASS
  if [ "$2" != "$3" ]; then st=FAIL; vfail=$((vfail + 1)); fi
  vchecks="${vchecks}| $st | $1 | \`$2\` | \`$3\` |
"
  printf '[%s] %s  %s (expected %s, measured %s)\n' "$V" "$st" "$1" "$2" "$3"
}
count_over() {  # <predicate fn> <arg2> <sessions...>: "hits/total"
  local fn="$1" a="$2" n=0 t=0 s; shift 2
  for s in "$@"; do t=$((t + 1)); if "$fn" "$(ss_out "$s")" "$a"; then n=$((n + 1)); fi; done
  echo "$n/$t"
}
list_over() {  # <var prefix> <sessions...>: "B:1 C:1 ..."
  local p="$1" s r=""; shift
  for s in "$@"; do eval "r=\"\$r \$s:\${${p}_$s:-?}\""; done
  echo "${r# }"
}

# Columns of the #203 table, measured over calls.tsv and the SS outputs.
row_metrics() {  # sets R_* for the summary table
  R_calls="$(awk -F'\t' '$3 != "curate"' "$VD/calls.tsv" | grep -c . || true)"
  R_rc0="$(awk -F'\t' '$3 != "curate" && $4 == 0' "$VD/calls.tsv" | grep -c . || true)"
  R_ss="$(awk -F'\t' '$3 == "SessionStart"' "$VD/calls.tsv" | grep -c . || true)"
  R_max=0; R_trim=0; R_bind=0
  local f b
  for f in "$VD"/calls/*_SessionStart.out; do
    [ -f "$f" ] || continue
    b="$(bytes "$f")"; [ "$b" -gt "$R_max" ] && R_max="$b"
    R_trim=$((R_trim + $(trimmed_count "$f")))
    R_bind=$((R_bind + $(bind_lines "$f")))
  done
  # Hook stderr only: the skill-side write prints informational .gitignore
  # bootstrap lines on its first run, which is not a hook.
  R_hook_err="$(awk -F'\t' '$3 != "write" && $3 != "restamp" && $3 != "curate" { s += $6 } END { print s + 0 }' "$VD/calls.tsv")"
  R_hook_err_calls="$(awk -F'\t' '$3 != "write" && $3 != "restamp" && $3 != "curate" && $6 > 0 { printf "%s%s_%s", sep, $2, $3; sep = "," }' "$VD/calls.tsv")"
}

common_checks() {  # <expected SS loads>
  row_metrics
  check "installer exit code" 0 "$INSTALL_RC"
  check "calls with rc 0" "$R_calls" "$R_rc0"
  check "SessionStart loads" "$1" "$R_ss"
  check "HANDOFF_BIND marker lines in SessionStart output" 0 "$R_bind"
  check "placeholder-only docs archived" 0 "$(placeholder_only_archived)"
}

# What the Stop hook leaves behind for <S>: its raw dump under
# <root>/.claude/handoff_backups/ holding every prompt and reply of turns
# 1..<n>, and the .ctx_<sid> size sidecar. Measured right after the last Stop.
stop_ok() {  # <session> <turns> <root>
  local d="$3/.claude/handoff_backups" i
  [ -f "$d/.ctx_$(sid_of "$1")" ] || return 1
  i=1
  while [ "$i" -le "$2" ]; do
    LC_ALL=C grep -qx "prompt $i from session $1" "$d/handoff_raw_$(sid_of "$1").md" 2>/dev/null || return 1
    LC_ALL=C grep -qx "reply $i from session $1" "$d/handoff_raw_$(sid_of "$1").md" 2>/dev/null || return 1
    i=$((i + 1))
  done
}
after_stops() { eval "STOP_$1=$(yn stop_ok "$1" "$2" "${3:-$PROJ}")"; }
ctx_sidecar() { yn test -f "$PROJ/.claude/handoff_backups/.ctx_$(sid_of "$1")"; }
banner() { [ -f "$1" ] && LC_ALL=C grep -q 'ACTION: RUN /handoff-recover' "$1"; }
# Session ids whose snapshots are in history, newest first.
hist_sids() {
  local f r=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    r="$r $(LC_ALL=C sed -nE 's/^<!-- HANDOFF_WRITER: sid=e2e-[a-z]+-([A-Za-z0-9]+) t=[0-9]+ -->$/\1/p' "$f" | tail -n 1)"
  done <<EOT
$(hist_files | LC_ALL=C sort -r)
EOT
  r="${r# }"; printf '%s' "${r:-none}"
}

# --- scenarios ---------------------------------------------------------------

# A curates, B..J never curate (E also compacts, F optionally in a worktree),
# K only starts.
scenario_main() {  # <notes 0|1> <rules 0|1> <worktree 0|1>
  local s wt="$3"
  session_curator A "$1" "$2"; snap A
  for s in B C D E F G H I J; do
    if [ "$s" = F ] && [ "$wt" = 1 ]; then scenario_worktree_f; after_end F; continue; fi
    ss "$s"
    stop_turn "$s" 1; stop_turn "$s" 2; stop_turn "$s" 3
    after_stops "$s" 3
    if [ "$s" = E ]; then
      hook E PreCompact "$PROJ" '"trigger":"auto","custom_instructions":""'; sleep 1
      # PostCompact deletes the session's .ctx_<sid> size sidecar, which the
      # Stop hook wrote: observe it present before and gone after.
      CTX_pre_E="$(ctx_sidecar E)"
      hook E PostCompact "$PROJ" '"trigger":"auto"'
      CTX_post_E="$(ctx_sidecar E)"
      hook E SessionStart "$PROJ" '"source":"compact"'; SS_E_compact="$LAST_OUT"
    fi
    send "$s"
    after_end "$s"
  done
  ss K; snap K
}

# F runs in a linked worktree the way the desktop app shapes it: worktree at
# <main>/.claude/worktrees/<name>, process cwd and CLAUDE_PROJECT_DIR = main,
# payload cwd = worktree. Then the WorktreeRemove hook fires and the worktree
# is removed.
scenario_worktree_f() {
  WT="$PROJ/.claude/worktrees/e2e-f"
  ( cd "$PROJ" && env -i PATH="$PATH" HOME="$JH" GIT_CONFIG_NOSYSTEM=1 git worktree add -q "$WT" -b e2e-f ) \
    >"$VD/worktree_add.out" 2>&1 || die "[$V] git worktree add failed (see $VD/worktree_add.out)"
  CK_before_F="$(cksum < "$(doc)")"
  WRITER_before_F="$(LC_ALL=C sed -nE 's/^<!-- HANDOFF_WRITER: sid=([A-Za-z0-9_-]+) .*/\1/p' "$(doc)" | tail -n 1)"
  ss F "$WT"
  stop_turn F 1 "$WT"; stop_turn F 2 "$WT"; stop_turn F 3 "$WT"
  after_stops F 3 "$WT"
  send F "$WT"
  CK_after_F_end="$(cksum < "$(doc)")"
  hook F WorktreeRemove "$PROJ" "\"worktree_path\":$(json_str "$WT")"
  ( cd "$PROJ" && env -i PATH="$PATH" HOME="$JH" GIT_CONFIG_NOSYSTEM=1 git worktree remove --force "$WT" ) \
    >"$VD/worktree_remove.out" 2>&1 || die "[$V] git worktree remove failed (see $VD/worktree_remove.out)"
  CK_after_wt_remove="$(cksum < "$(doc)")"
}

main_checks() {  # <rules 0|1> <ss budget> <worktree 0|1>
  local rules="$1" budget="$2" s fb a_hist a_name n t
  common_checks 12
  check "Stop hook left a raw dump with every turn and a .ctx sidecar, A..J" "A:yes B:yes C:yes D:yes E:yes F:yes G:yes H:yes I:yes J:yes" "$(list_over STOP A B C D E F G H I J)"
  check "E's .ctx sidecar before PostCompact / after" "yes/no" "${CTX_pre_E:-?}/${CTX_post_E:-?}"
  # B loads A's curated doc; C..K load an uncurated refresh and must be told
  # to run /handoff-recover (F in a worktree is checked in worktree_checks).
  check "recover banner absent at B" no "$(yn banner "$(ss_out B)")"
  if [ "$3" = 1 ]; then
    check "recover banner present at C..K (not F)" 8/8 "$(count_over banner - C D E G H I J K)"
  else
    check "recover banner present at C..K" 9/9 "$(count_over banner - C D E F G H I J K)"
  fi
  if [ "$budget" = 9000 ]; then
    check "A's Notes present in SessionStart B..K" 10/10 "$(count_over has_notes A B C D E F G H I J K)"
  else
    check "A's Notes reachable from SessionStart B..K (inline or in a file a trim notice names)" 10/10 "$(count_over notes_reachable A B C D E F G H I J K)"
  fi
  if [ "$rules" = 1 ]; then
    check "A's fence bound in SessionStart B..K" 10/10 "$(count_over fence_bound A B C D E F G H I J K)"
    check "A's fence bound in E's post-compaction SessionStart" yes "$(yn fence_bound "${SS_E_compact:-}" A)"
    check "B's doc carries the fence with the 'archived in handoff_history/' label" yes \
      "$(yn grep -q 'whose snapshot is archived in handoff_history/' "$VD/snap/B/handoff_current.md")"
  else
    check "fence lines anywhere in SessionStart B..K (no fence written)" 0/10 "$(count_over fence_anywhere A B C D E F G H I J K)"
  fi
  check "archive claim accurate after each B..J end" 9/9 "$(n=0; for s in B C D E F G H I J; do eval "[ \"\$ARCH_$s\" = yes ]" && n=$((n + 1)); done; echo "$n/9")"
  check "history count after each B..J end" "B:1 C:1 D:1 E:1 F:1 G:1 H:1 I:1 J:1" "$(list_over HIST B C D E F G H I J)"
  a_hist="$(hist_by_sid A)"
  check "A's snapshot in history after J" yes "$(yn test -n "$a_hist")"
  check "B's doc not archived after C's end (carried-only, deleted)" no "$(yn test -n "$(cd "$VD/snap/C/history" 2>/dev/null && LC_ALL=C grep -l "^<!-- HANDOFF_WRITER: sid=$(sid_of B) " handoff_*.md 2>/dev/null)")"
  a_name="${a_hist##*/}"
  n=0; t=0
  for s in C D E G H I J K; do t=$((t + 1)); fb="$(fallback_name "$(ss_out "$s")")"; [ -n "$a_name" ] && [ "$fb" = "$a_name" ] && n=$((n + 1)); done
  check "C..K (not F) load the fallback from A's snapshot" "$t/$t" "$n/$t"
  if [ "$budget" = 9000 ]; then
    check "largest SessionStart output under the 9000 B budget" yes "$(yn test "$R_max" -le 9000)"
    check "trimmed sections" 0 "$R_trim"
  else
    # The binding tier is never trimmed, so at a budget smaller than the
    # untrimmable part a load stays over it; it must then say so.
    check "SessionStart B..K with the trim notice and a trimmed section" 10/10 "$(count_over trim_noticed - B C D E F G H I J K)"
    check "over-budget SessionStart B..K that say they are still over" 10/10 "$(count_over over_budget_warned "$budget" B C D E F G H I J K)"
    check "trim notices naming a missing file" 0 "$(n=0; for s in B C D E F G H I J K; do eval "n=\$((n + \${TRIMMISS_$s:-0}))"; done; echo "$n")"
  fi
}

# Only F's SessionEnd and WorktreeRemove may write stderr, and only these
# informational lines; anything else on any F call is counted as unexpected.
wt_stderr_unexpected() {
  local f ev line bad=0 salv=0
  for f in "$VD"/calls/*_F_*.err; do
    [ -f "$f" ] || continue
    ev="${f##*_F_}"; ev="${ev%.err}"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$ev:$line" in
        "SessionEnd:write_handoff.sh: added '.claude/"*"' to $WT/.gitignore (set HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 to skip)") ;;
        "SessionEnd:handoff: salvaged this session's raw dump for sessions in the main checkout: $(hist_dir)/worktrees/raw_"*".md") salv=$((salv + 1)) ;;
        "WorktreeRemove:handoff: WorktreeRemove: $WT/.claude/handoff_current.md is an unedited placeholder; not copied (its raw dumps are salvaged below).") ;;
        "WorktreeRemove:handoff: raw dump unchanged since the last salvaged copy ($(hist_dir)/worktrees/raw_"*".md); no new copy.") ;;
        *) bad=$((bad + 1)); printf '[%s] unexpected F stderr (%s): %s\n' "$V" "$ev" "$line" >&2 ;;
      esac
    done < "$f"
  done
  [ "$salv" -eq 1 ] || bad=$((bad + 1))
  echo "$bad"
}

worktree_checks() {
  local raw_n s n
  check "hook stderr outside the worktree path (bytes)" 0 "$(awk -F'\t' '$2 != "F" && $3 != "write" && $3 != "restamp" && $3 != "curate" { s += $6 } END { print s + 0 }' "$VD/calls.tsv")"
  check "unexpected stderr lines on F's calls (only the pinned SessionEnd/WorktreeRemove notices allowed)" 0 "$(wt_stderr_unexpected)"
  check "F loaded main's current doc (writer before F)" yes "$(yn grep -q "^<!-- HANDOFF_WRITER: sid=$WRITER_before_F " "$(ss_out F)")"
  check "F's SessionStart has no recover banner" no "$(yn grep -q 'ACTION: RUN /handoff-recover' "$(ss_out F)")"
  check "main doc unchanged by F's end" yes "$(yn test "$CK_before_F" = "$CK_after_F_end")"
  check "main doc unchanged by the worktree removal" yes "$(yn test "$CK_before_F" = "$CK_after_wt_remove")"
  raw_n="$(LC_ALL=C grep -l 'from session F' "$(hist_dir)"/worktrees/raw_*.md 2>/dev/null | grep -c . || true)"
  check "F's raw dump salvaged to handoff_history/worktrees/" yes "$(yn test "$raw_n" -ge 1)"
  check "G's SessionStart lists the salvaged dump" yes "$(yn grep -q 'handoff_history/worktrees/raw_' "$(ss_out G)")"
  n=0; for s in H I J K; do grep -q 'handoff_history/worktrees/raw_' "$(ss_out "$s")" && n=$((n + 1)); done
  check "H..K SessionStart list the salvaged dump" 0/4 "$n/4"
}

# KEEP=1 keeps one snapshot plus the newest Notes-curated and the newest
# Rules-curated ones. The order makes each protected slot hold a file that is
# NOT the newest, so dropping either protection changes the result:
#   A1 Rules only, A2 Notes only, A3 Rules only, then B, C (never curate), K.
#   A3's write archives A2 over A1: history A2 A1, A1 kept ONLY by the Rules
#   slot. B's stale refresh archives A3: history A3 A2, A2 kept ONLY by the
#   Notes slot, A1 pruned. C's end deletes B's carried-only doc.
scenario_prune() {
  session_curator A1 0 1; after_end A1
  session_curator A2 1 0; after_end A2
  session_curator A3 0 1; after_end A3
  session_plain B; after_end B
  session_plain C; after_end C
  ss K; snap K
}

prune_checks() {
  common_checks 6
  check "Stop hook left a raw dump with every turn and a .ctx sidecar" "A1:yes A2:yes A3:yes B:yes C:yes" "$(list_over STOP A1 A2 A3 B C)"
  check "history count after each end (KEEP=1)" "A1:0 A2:1 A3:2 B:2 C:2" "$(list_over HIST A1 A2 A3 B C)"
  check "history after A3's end, newest first (A1 kept only by the Rules slot)" "A2 A1" "${HSIDS_A3:-?}"
  check "history after B's end, newest first (A2 kept only by the Notes slot, A1 pruned)" "A3 A2" "${HSIDS_B:-?}"
  check "history after C's end, newest first (B's carried-only doc not archived)" "A3 A2" "${HSIDS_C:-?}"
  check "A2's Notes present in SessionStart B, C, K" 3/3 "$(count_over has_notes A2 B C K)"
  check "FENCE_A3 bound in SessionStart B, C, K" 3/3 "$(count_over fence_bound A3 B C K)"
  check "largest SessionStart output under the 9000 B budget" yes "$(yn test "$R_max" -le 9000)"
  check "trimmed sections" 0 "$R_trim"
  check "hook stderr (bytes)" 0 "$R_hook_err"
}

summary_row() {  # <notes label> <fence label> <history label> <A snapshot label>
  results_rows="${results_rows}| $V | $R_calls | $R_rc0 | $R_ss | $1 | $2 | $R_max | $R_trim | $R_bind | $3 | $4 | ${R_hook_err} B${R_hook_err_calls:+ ($R_hook_err_calls)} | $vfail |
"
}

run_variant() {
  local v="$1" t0 notes fence arch hist asnap
  setup_variant "$v"
  t0="$(date +%s)"
  note "installed (rc $INSTALL_RC), running"
  vchecks=""; vfail=0
  case "$v" in
    baseline) scenario_main 1 1 0; main_checks 1 9000 0; check "hook stderr (bytes)" 0 "$R_hook_err" ;;
    notesonly) scenario_main 1 0 0; main_checks 0 9000 0; check "hook stderr (bytes)" 0 "$R_hook_err" ;;
    worktree) scenario_main 1 1 1; main_checks 1 9000 1; worktree_checks ;;
    trimmer)
      extra_env=(HANDOFF_SS_MAX_BYTES=2000)
      scenario_main 1 1 0; main_checks 1 2000 0; check "hook stderr (bytes)" 0 "$R_hook_err" ;;
    prune)
      extra_env=(HANDOFF_HISTORY_KEEP=1)
      scenario_prune; prune_checks ;;
  esac
  if [ "$v" = prune ]; then
    notes="A2's Notes at B,C,K: $(count_over has_notes A2 B C K)"
    fence="FENCE_A3 at B,C,K: $(count_over fence_bound A3 B C K)"
    arch="$(list_over HIST A1 A2 A3 B C)"
    asnap="after A3: ${HSIDS_A3:-?}; after B: ${HSIDS_B:-?}; final: $(hist_sids)"
    hist="$arch"
  else
    notes="$(count_over has_notes A B C D E F G H I J K)"
    [ "$v" = trimmer ] && notes="inline $notes, reachable $(count_over notes_reachable A B C D E F G H I J K)"
    fence="$(count_over fence_bound A B C D E F G H I J K)"
    hist="$(list_over HIST B C D E F G H I J)"
    asnap="$(yn test -n "$(hist_by_sid A)")"
  fi
  summary_row "$notes" "$fence" "$hist" "$asnap"
  {
    printf '\n### %s (%ss)\n\n| result | check | expected | measured |\n|---|---|---|---|\n%s' "$v" "$(( $(date +%s) - t0 ))" "$vchecks"
  } >> "$outdir/.checks.md"
  fail_total=$((fail_total + vfail))
  teardown_variant
}

# --- main --------------------------------------------------------------------
: > "$outdir/.checks.md"
for v in $variants; do run_variant "$v"; done
wall=$(( $(date +%s) - start_epoch ))
{
  printf '# Release-fence multi-session e2e (tools/e2e_multi_session.sh)\n\n'
  # shellcheck disable=SC2016  # Markdown backticks, not command substitution
  printf -- '- tree: `%s`\n- HEAD: `%s` (uncommitted paths: %s)\n- run: %s, %s s wall\n- variants: %s\n- result: %s\n\n' \
    "$tree" "$tree_head" "$tree_dirty" "$(date -u '+%Y-%m-%d %H:%M UTC')" "$wall" "${variants# }" \
    "$(if [ "$fail_total" -eq 0 ]; then echo "PASS (all checks held)"; else echo "FAIL ($fail_total check(s) failed)"; fi)"
  printf '| variant | calls | rc 0 | SS loads | Notes present | fence bound | max bytes | trimmed | BIND lines | history after each end | A snapshot kept | hook stderr | failed checks |\n'
  printf '|---|---|---|---|---|---|---|---|---|---|---|---|---|\n'
  printf '%s' "$results_rows"
  cat "$outdir/.checks.md"
} > "$outdir/results.md"
rm -f "$outdir/.checks.md"
printf '\nresults: %s/results.md (wall %ss)\n' "$outdir" "$wall"
if [ "$fail_total" -ne 0 ]; then
  printf 'e2e_multi_session: FAIL: %s check(s) did not hold; see the FAIL rows above and in results.md\n' "$fail_total" >&2
  exit 1
fi
printf 'e2e_multi_session: PASS: every check held\n'
exit 0
