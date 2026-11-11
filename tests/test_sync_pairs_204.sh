#!/usr/bin/env bash
# #204: two more pairs of code that are kept in sync by hand and, until this
# test, by comment only (the #189 sibling is tests/test_lock_body_sync.sh).
#
# Pair 1: handoff_defang (bin/handoff_provenance.sh) and defang_untrusted
#   (bin/handoff_session_start.sh). The second is deliberately self-contained
#   (SessionStart must not depend on the optional lib), so the sed pattern is
#   duplicated. Compared two ways, both against EACH OTHER, never a fixture:
#   TEXT: the function with its header and comment lines dropped, and the
#   one intended difference (the tail of the fallback warning text) cut off,
#   must be byte-identical; BEHAVIOUR: both run on the same corpus (tags that
#   must be defanged, near misses that must not, invalid UTF-8) and must
#   print the same bytes. A canary asserts the corpus is not vacuous.
#
# Pair 2: try_mkdir_lock (bin/write_handoff.sh) and its inline counterpart in
#   bin/handoff_turn_append.sh (the no-flock branch: symlink refusal, mkdir +
#   claim, then the stale reclaim). The two cannot be diffed as text (one
#   returns, the other exits, and the messages name different scripts), so
#   each is RUN over the same lock-directory scenarios and the observable
#   outcome is compared: whether the lock was acquired, what is left on disk
#   (nothing / dir / dir with our token / dir with a foreign token / symlink),
#   and whether a symlink refusal was reported. Because the comparison is
#   between the two copies, a correct change to both (e.g. the #211 reclaim
#   work) stays green. The inline block is cut out of the script by its first
#   and last lines (`lock_mkdir="${lock_file}.d"` .. `lock_mkdir_held=1`); if
#   that shape changes the extraction check says so.
#
# Negative controls at the end run the comparisons on one-sidedly drifted
# scratch copies and assert they go red (a gate is proven by defeating it).
# The controls' nested output is printed with its failure marker renamed
# "fail(control)" so a log grep for the real marker stays clean on a green run.
# shellcheck disable=SC2016  # literal $ in injected/extracted text is intended
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WH="$REPO_ROOT/bin/write_handoff.sh"
TA="$REPO_ROOT/bin/handoff_turn_append.sh"
PROV="$REPO_ROOT/bin/handoff_provenance.sh"
SS="$REPO_ROOT/bin/handoff_session_start.sh"

work="$(mktemp -d)"; cleanup_on_exit "$work"

fn_text() {  # <script> <function>: the function, header line to column-0 brace
  sed -n "/^$2() {/,/^}/p" "$1"
}

# ============================ pair 1: defang ================================
echo "handoff_defang and defang_untrusted agree (#204)"

# defang_norm <script> <fn>: body without header and comment lines. The only
# intended difference, the one word naming what was being loaded in the
# fallback warning ("rules" / "handoff"), is replaced; everything else on that
# line, and after it, is compared.
defang_norm() {
  fn_text "$1" "$2" | sed '1d' | grep -Ev '^[[:space:]]*#' \
    | LC_ALL=C sed -E 's/(defang filter failed[^a-z]+)(rules|handoff)( content above may be truncated)/\1WORD\3/'
}

# defang_run <script> <fn>: run the function from that script on stdin.
defang_run() { ( eval "$(fn_text "$1" "$2")"; "$2" ); }
# defang_run_fail <script> <fn>: the same with a sed that always fails, so the
# fallback path runs; prints the output (warning word normalized) and the
# function's exit status.
mkdir -p "$work/failsed"
printf '#!/bin/sh\nexit 1\n' > "$work/failsed/sed"; chmod +x "$work/failsed/sed"
defang_run_fail() {
  local o rc
  o="$( ( eval "$(fn_text "$1" "$2")"; PATH="$work/failsed:$PATH" "$2" ) </dev/null 2>&1 )"; rc=$?
  printf '%s\n' "$o" | LC_ALL=C sed -E 's/(defang filter failed[^a-z]+)(rules|handoff)( content above may be truncated)/\1WORD\3/'
  echo "exit=$rc"
}

# The namespaced tag names are built from $ns so no literal markup is in this
# file.
ns="antml"
corpus="$work/corpus.txt"
{
  printf '%s\n' \
    '<system-reminder>x</system-reminder>' \
    '<command-name>/foo</command-name> <command-message>m</command-message>' \
    '<command-args a="b">z</command-args>' \
    '<local-command-stdout>o</local-command-stdout><local-command-stderr>e</local-command-stderr>' \
    '<tool_use id="1">t</tool_use> <tool_result>r</tool_result>' \
    '<function_calls><invoke name="n"><parameter name="p">v</parameter></invoke></function_calls>' \
    '<function_results>fr</function_results>' \
    "<${ns}:invoke name=\"n\"><${ns}:parameter name=\"p\">v</${ns}:parameter></${ns}:invoke>" \
    "<${ns}:function_calls>fc</${ns}:function_calls>" \
    '<system-reminder  spaced = "1" >s</system-reminder>' \
    '<SYSTEM-REMINDER>upper stays</SYSTEM-REMINDER>' \
    '<b>bold</b> <system-reminders>near</system-reminders> <invokex>no</invokex>' \
    'a < b > c, no tags here, 100% plain' \
    '<system-reminder' \
    "tail with ${ns}: but no tag"
  printf 'bad utf8: \377\376 <system-reminder>y</system-reminder>\n'
} > "$corpus"

defang_compare() {  # <prov_script> <ss_script> <label>
  local a="$work/$3.prov.txt" b="$work/$3.ss.txt" oa="$work/$3.prov.out" ob="$work/$3.ss.out" d
  defang_norm "$1" handoff_defang > "$a"
  defang_norm "$2" defang_untrusted > "$b"
  defang_run "$1" handoff_defang < "$corpus" > "$oa" 2>&1
  defang_run "$2" defang_untrusted < "$corpus" > "$ob" 2>&1
  defang_run_fail "$1" handoff_defang > "$oa.fail"
  defang_run_fail "$2" defang_untrusted > "$ob.fail"
  check "$3: handoff_defang found in $(basename "$1")" yes "$([[ -s "$a" ]] && echo yes || echo no)"
  check "$3: defang_untrusted found in $(basename "$2")" yes "$([[ -s "$b" ]] && echo yes || echo no)"
  if d="$(diff -u -L provenance -L session_start "$a" "$b")"; then
    check "$3: function text identical (comments and warning tail aside)" same same
  else
    printf '%s\n' "$d" | sed 's/^/    /'
    check "$3: function text identical (comments and warning tail aside)" same differ
  fi
  if d="$(diff -u -L provenance -L session_start "$oa" "$ob")"; then
    check "$3: both print the same bytes for the corpus" same same
  else
    printf '%s\n' "$d" | sed 's/^/    /'
    check "$3: both print the same bytes for the corpus" same differ
  fi
  if d="$(diff -u -L provenance -L session_start "$oa.fail" "$ob.fail")"; then
    check "$3: both fail the same way when sed fails (output and exit status)" same same
  else
    printf '%s\n' "$d" | sed 's/^/    /'
    check "$3: both fail the same way when sed fails (output and exit status)" same differ
  fi
}
defang_compare "$PROV" "$SS" defang

# Canary: the corpus exercises the filter (not a pair of no-ops).
out="$(defang_run "$PROV" handoff_defang < "$corpus")"
check "canary: a system-reminder tag is defanged" yes \
  "$(printf '%s\n' "$out" | grep -q '^«system-reminder»x«/system-reminder»$' && echo yes || echo no)"
check "canary: a namespaced tag is defanged" yes \
  "$(printf '%s\n' "$out" | grep -qF "«${ns}:function_calls»fc«/${ns}:function_calls»" && echo yes || echo no)"
check "canary: a near miss is left alone" yes \
  "$(printf '%s\n' "$out" | grep -qF '<b>bold</b> <system-reminders>near' && echo yes || echo no)"
check "canary: invalid UTF-8 does not abort the filter" yes \
  "$(printf '%s\n' "$out" | LC_ALL=C grep -q 'bad utf8: .*«system-reminder»y«/system-reminder»' && echo yes || echo no)"

# ======================== pair 2: try_mkdir_lock ============================
echo "try_mkdir_lock and the inline lock in handoff_turn_append.sh agree (#204)"

# inline_block <ta_script>: the no-flock inline acquisition, first line
# through `lock_mkdir_held=1`.
inline_block() {
  sed -n '/^  lock_mkdir="\${lock_file}\.d"/,/^  lock_mkdir_held=1$/p' "$1"
}

# Shared driver tail: report in an EXIT trap (the inline block `exit`s on a
# miss). state: none | link | dir-empty | dir-self | dir-other ; refused: did
# stderr say "symlink".
epilogue='
report() {
  local rc=$? st=none tok reaps=0
  if [[ -L "$LOCKD" ]]; then st=link
  elif [[ -d "$LOCKD" ]]; then
    st=dir-empty
    if [[ -f "$LOCKD/owner" ]]; then
      tok=""; read -r tok < "$LOCKD/owner" 2>/dev/null || true
      if [[ "$tok" == "$$" ]]; then st=dir-self; else st=dir-other; fi
    fi
  fi
  [[ -d "$LOCKD" && ! -L "$LOCKD" ]] && reaps="$(ls -d "$LOCKD"/owner.reap.* 2>/dev/null | wc -l | tr -d " ")"
  echo "acquired=${ACQ:-no} state=$st reaps=$reaps rc=$rc"
}
trap report EXIT
'

# build_wh_harness <wh_script> <out>: the three lock functions + a call.
build_wh_harness() {
  {
    fn_text "$1" claim_mkdir_lock
    fn_text "$1" reclaim_stale_mkdir_lock
    fn_text "$1" try_mkdir_lock
    printf '%s\n' "$epilogue" 'try_mkdir_lock "$LOCKD"; WRC=$?; [[ $WRC -eq 0 ]] && ACQ=yes; exit $WRC'
  } > "$2"
}
# build_ta_harness <ta_script> <out>: the ta_ functions + the inline block.
build_ta_harness() {
  {
    fn_text "$1" ta_claim_lock
    fn_text "$1" ta_reclaim_stale_lock
    # refuse_symlink is the only other helper the surrounding script has; the
    # inline block does not call it.
    printf '%s\n' "$epilogue" 'lock_file="${LOCKD%.d}"'
    inline_block "$1"
    echo 'ACQ=yes'
  } > "$2"
}

# scenario <name>: build $LOCKD for it (run in a fresh dir by the caller).
mkshim() {  # a mkdir that lies: always exits 0 (uutils race, see #153)
  mkdir -p "$work/shim"
  printf '#!/usr/bin/env bash\n"%s" "$@" 2>/dev/null\nexit 0\n' "$(command -v mkdir)" > "$work/shim/mkdir"
  chmod +x "$work/shim/mkdir"
}
mkshim
# A stat that, for the lock dir only, reports the 2nd successful reading 5 s
# later: makes the "dir changed between the age check and the recheck" race
# deterministic (no timing).
mkdir -p "$work/statshim"
cat > "$work/statshim/stat" <<SHIM
#!/usr/bin/env bash
last="\${@: -1}"
out="\$("$(command -v stat)" "\$@")" || exit \$?
if [[ "\$last" == "\$LOCKD" ]]; then
  n=\$(cat "\$STATCNT" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$STATCNT"
  [[ \$n -eq 2 ]] && out=\$((out + 5))
fi
echo "\$out"
SHIM
chmod +x "$work/statshim/stat"
scenarios=(free held-fresh held-fresh-liar stale-token stale-token-badenv stale-empty \
           fresh-empty symlink-fresh symlink-dangling symlink-stale \
           handback-live-token handback-boundary stale-reaps stale-empty-race)
setup_scenario() {  # <name> <dir>; sets SC_PATH / SC_ENV via globals
  local d="$2"
  SC_PATH="$PATH"; SC_STALE=""
  case "$1" in
    free) ;;
    held-fresh) mkdir "$d"; echo 424242 > "$d/owner" ;;
    held-fresh-liar) mkdir "$d"; echo 424242 > "$d/owner"; SC_PATH="$work/shim:$PATH" ;;
    stale-token) mkdir "$d"; echo 424242 > "$d/owner"
      touch -t 202001010000 "$d/owner"; touch -t 202001010000 "$d" ;;
    stale-token-badenv) mkdir "$d"; echo 424242 > "$d/owner"
      touch -t 202001010000 "$d/owner"; touch -t 202001010000 "$d"; SC_STALE="abc" ;;
    stale-empty) mkdir "$d"; touch -t 202001010000 "$d" ;;
    fresh-empty) mkdir "$d" ;;
    handback-live-token) mkdir "$d"; echo 424242 > "$d/owner"   # token 50 s newer than the dir
      touch -t 202001010000.50 "$d/owner"; touch -t 202001010000 "$d" ;;
    handback-boundary) mkdir "$d"; echo 424242 > "$d/owner"     # exactly 1 s newer: not a hand-back
      touch -t 202001010000.01 "$d/owner"; touch -t 202001010000 "$d" ;;
    stale-reaps) mkdir "$d"; echo 424242 > "$d/owner"; echo 1 > "$d/owner.reap.1"; echo 2 > "$d/owner.reap.2"
      touch -t 202001010000 "$d/owner" "$d/owner.reap.1"; touch -t 202001010000 "$d" ;;
    stale-empty-race) mkdir "$d"; touch -t 202001010000 "$d"; SC_PATH="$work/statshim:$PATH" ;;
    symlink-fresh) mkdir "$d.target"; ln -s "$d.target" "$d" ;;
    symlink-dangling) ln -s "$d.nowhere" "$d" ;;
    symlink-stale) mkdir "$d.target"; ln -s "$d.target" "$d"; touch -h -t 202001010000 "$d" 2>/dev/null || true ;;
  esac
}

# run_scenarios <harness> <out>: one line per scenario, "<name>: <report>
# refused=<yes|no>".
run_scenarios() {
  local h="$1" out="$2" kind="$3" s base d rep err rc acq st
  : > "$out"
  for s in "${scenarios[@]}"; do
    base="$(mktemp -d "$work/sc.XXXXXX")"; d="$base/lock.d"
    setup_scenario "$s" "$d"
    rep="$( cd "$base" && LOCKD="$d" STATCNT="$base/cnt" PATH="$SC_PATH" HANDOFF_LOCK_STALE_SECS="${SC_STALE:-300}" \
            bash "$h" 2>"$base/err" </dev/null | tail -n 1 )"
    err="$(grep -qi 'symlink' "$base/err" && echo yes || echo no)"
    # Exit-status contract, per copy: try_mkdir_lock returns 0 on acquire and 1
    # on a miss; the inline block falls through on acquire and `exit 0`s on a
    # miss (the hook yields cleanly). Reported as ok/bad so the two compare.
    rc="${rep##*rc=}"; acq="${rep#acquired=}"; acq="${acq%% *}"; rep="${rep% rc=*}"
    st=bad
    if [[ "$kind" == wh ]]; then
      { [[ "$acq" == yes && "$rc" == 0 ]] || [[ "$acq" == no && "$rc" == 1 ]]; } && st=ok
    else
      [[ "$rc" == 0 ]] && st=ok
    fi
    printf '%s: %s refused=%s exit=%s\n' "$s" "$rep" "$err" "$st" >> "$out"
    rm -rf "$base"
  done
}

lock_compare() {  # <wh_script> <ta_script> <label>
  local hw="$work/$3.wh.sh" ht="$work/$3.ta.sh" ow="$work/$3.wh.out" ot="$work/$3.ta.out" d
  build_wh_harness "$1" "$hw"
  build_ta_harness "$2" "$ht"
  check "$3: try_mkdir_lock found in $(basename "$1")" yes "$(grep -q '^try_mkdir_lock() {' "$hw" && echo yes || echo no)"
  check "$3: inline block found in $(basename "$2") (ends at lock_mkdir_held=1)" yes \
    "$(inline_block "$2" | tail -n 1 | grep -q '^  lock_mkdir_held=1$' && echo yes || echo no)"
  run_scenarios "$hw" "$ow" wh
  run_scenarios "$ht" "$ot" ta
  # Non-vacuous: the scenarios really reach different outcomes.
  check "$3: scenarios cover both acquired and missed outcomes" yes \
    "$(grep -q 'acquired=yes' "$ow" && grep -q 'acquired=no' "$ow" && echo yes || echo no)"
  check "$3: a symlink refusal is reported by write_handoff.sh" yes \
    "$(grep -q '^symlink-fresh: .* refused=yes exit=ok$' "$ow" && echo yes || echo no)"
  if d="$(diff -u -L write_handoff -L turn_append "$ow" "$ot")"; then
    check "$3: both copies reach the same outcome in every scenario" same same
  else
    printf '%s\n' "$d" | sed 's/^/    /'
    check "$3: both copies reach the same outcome in every scenario" same differ
  fi
}
lock_compare "$WH" "$TA" lock

# ============================ negative controls ==============================
# control <name> <line-pattern> <function> <args...>: run the comparison on the
# drifted copies in a subshell; it must report a failure and print a line
# matching the pattern.
control() {
  local name="$1" pat="$2" out; shift 2
  out="$("$@" 2>&1 | sed 's/FAIL  /fail(control)  /')"
  printf '%s\n' "$out" | sed 's/^/    | /'
  check "negative control $name: comparison reports a failure" yes \
    "$(printf '%s\n' "$out" | grep -q 'fail(control)' && echo yes || echo no)"
  check "negative control $name: comparison prints the offending line" yes \
    "$(printf '%s\n' "$out" | grep -Eq "$pat" && echo yes || echo no)"
}
# control_green <name> <fn> <orig_a> <orig_b> <drift_a> <drift_b> <label>: the
# edit must add no failure beyond what the unedited pair already reports (so a
# pair that has really drifted is not counted twice here).
control_green() {
  local name="$1" fn="$2" base_n drift_n
  base_n="$("$fn" "$3" "$4" "${7}_base" 2>&1 | grep -c 'FAIL  ')"
  drift_n="$("$fn" "$5" "$6" "${7}" 2>&1 | grep -c 'FAIL  ')"
  check "negative control $name: comparison adds no failure" "$base_n" "$drift_n"
}

# Defang: add one tag name to the pattern of one copy only (the pattern line
# is the one holding `sed -E 's#<`).
sed -E "/^defang_untrusted\\(\\)/,/^}/ s/\\|invoke\\|/|invoke|zzz_tag|/" "$SS" > "$work/ss_drift.sh"
must grep -q 'invoke|zzz_tag|' "$work/ss_drift.sh"
control defang-pattern-drift '^ +[-+].*zzz_tag' defang_compare "$PROV" "$work/ss_drift.sh" ctl_defang_pat
# Defang: a different locale on one copy (the text differs, and so can output).
sed -E "/^handoff_defang\\(\\)/,/^}/ s/LC_ALL=C sed/LC_ALL=en_US.UTF-8 sed/" "$PROV" > "$work/prov_drift.sh"
must grep -q 'LC_ALL=en_US.UTF-8 sed' "$work/prov_drift.sh"
control defang-locale-drift '^ +[-+].*LC_ALL=' defang_compare "$work/prov_drift.sh" "$SS" ctl_defang_loc
# Defang: a comment-only edit (and a different warning tail) stays green.
awk '/^defang_untrusted\(\) \{/ { print; print "  # a comment added to one copy only"; next } { print }' "$SS" > "$work/ss_comment.sh"
must grep -q 'a comment added to one copy only' "$work/ss_comment.sh"
control_green defang-comment-only defang_compare "$PROV" "$SS" "$PROV" "$work/ss_comment.sh" ctl_defang_ok

# Lock: the inline copy stops trying the stale reclaim (survives the build:
# a valid script, only the stale-lock scenarios change).
sed -E '/^  lock_mkdir="\$\{lock_file\}\.d"/,/^  lock_mkdir_held=1$/ s/if ta_reclaim_stale_lock "\$lock_mkdir"; then/if false; then/' "$TA" > "$work/ta_noreclaim.sh"
must grep -q '^    if false; then$' "$work/ta_noreclaim.sh"
control lock-no-reclaim '^ +[-+]stale-' lock_compare "$WH" "$work/ta_noreclaim.sh" ctl_lock_reclaim
# Lock: write_handoff.sh's try_mkdir_lock loses its symlink refusal message.
awk '/^try_mkdir_lock\(\) \{/ { inr = 1 } inr && /symlink; refusing/ { next } /^}/ { inr = 0 } { print }' "$WH" > "$work/wh_nolink.sh"
must test "$(diff "$WH" "$work/wh_nolink.sh" | grep -c '^<')" -eq 1
control lock-no-symlink-message '^ +[-+]symlink-' lock_compare "$work/wh_nolink.sh" "$TA" ctl_lock_link
# Lock: the inline copy claims without the mkdir (acquires over a held dir).
sed -E '/^  lock_mkdir="\$\{lock_file\}\.d"/,/^  lock_mkdir_held=1$/ s/mkdir "\$lock_mkdir" 2>\/dev\/null && ta_claim_lock/true \&\& ta_claim_lock/' "$TA" > "$work/ta_nomkdir.sh"
must grep -q 'true && ta_claim_lock "\$lock_mkdir"' "$work/ta_nomkdir.sh"
control lock-no-mkdir '^ +[-+](free|held|fresh|stale)' lock_compare "$WH" "$work/ta_nomkdir.sh" ctl_lock_mkdir
# Lock: a comment added to one copy only stays green.
awk '/^try_mkdir_lock\(\) \{/ { print; print "  # a comment added to one copy only"; next } { print }' "$WH" > "$work/wh_comment.sh"
control_green lock-comment-only lock_compare "$WH" "$TA" "$work/wh_comment.sh" "$TA" ctl_lock_ok

finish
