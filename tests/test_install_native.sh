#!/usr/bin/env bash
# install.sh wiring for the native-integration surface:
#   A. fresh install adds PreCompact + PostCompact hooks and the statusLine
#   B. idempotent re-run (no duplicate entries, no-change backup removed)
#   C. an EXISTING user statusLine is never overwritten (skip msg emitted) —
#      the mandated negative control
#   D. uninstall removes ours (incl. statusLine when ours), preserves a user's
#      own statusLine and co-located PreCompact hook commands
#   E. --doctor covers both new scripts + reports the statusLine state
#   F. the manual snippet (printed when settings.json is invalid JSON)
#      documents PreCompact/PostCompact/statusLine with the only-if-unset
#      note; a jq-less plain install REFUSES up front (0.9.0 behavior —
#      jq is a hard runtime dependency, so installing would ship a
#      silently-dead system)
#   G. a truncated piped install stream exits nonzero and installs nothing
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh native-integration wiring (PreCompact/PostCompact/statusLine)"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh settings patching is a no-op without it"
  finish
  exit
fi

HOME_DIR=""
# run_install <init|__ABSENT__> [install args...] ; sets RC, OUT, HOME_DIR.
run_install() {
  local init="$1"; shift
  local src; src="$(mktemp -d)"; HOME_DIR="$(mktemp -d)"
  cp "$REPO_ROOT/install.sh" "$src/"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
  [[ "$init" != "__ABSENT__" ]] && printf '%s' "$init" > "$HOME_DIR/settings.json"
  OUT="$(CLAUDE_HOME="$HOME_DIR" bash "$src/install.sh" "$@" 2>&1)"
  RC=$?
  rm -rf "$src"
}
sj()  { jq -r "$1" "$HOME_DIR/settings.json" 2>/dev/null; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# --- A. fresh install wires the new surface ----------------------------------
run_install __ABSENT__
check "fresh: exit 0"                    0   "$RC"
check "fresh: PreCompact present"        yes "$(has "$(sj '.hooks.PreCompact[0].hooks[0].command')" 'write_handoff.sh --if-curated')"
check "fresh: PreCompact has no matcher" null "$(sj '.hooks.PreCompact[0].matcher // "null"')"
check "fresh: PostCompact present"       yes "$(has "$(sj '.hooks.PostCompact[0].hooks[0].command')" 'handoff_compact_reset.sh')"
check "fresh: statusLine wired"          yes "$(has "$(sj '.statusLine.command')" 'handoff_statusline.sh')"
check "fresh: statusLine type command"   command "$(sj '.statusLine.type')"
check "fresh: reset perm added"          yes "$(sj '.permissions.allow | join(" ")' | grep -q handoff_compact_reset && echo yes || echo no)"
check "fresh: statusline perm added"     yes "$(sj '.permissions.allow | join(" ")' | grep -q handoff_statusline && echo yes || echo no)"

# --- B. idempotent re-run ----------------------------------------------------
before="$(cat "$HOME_DIR/settings.json")"
src2="$(mktemp -d)"; cp "$REPO_ROOT/install.sh" "$src2/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src2/"
out2="$(CLAUDE_HOME="$HOME_DIR" bash "$src2/install.sh" 2>&1)"
after="$(cat "$HOME_DIR/settings.json")"
check "re-run: settings unchanged"       same "$([[ "$before" == "$after" ]] && echo same || echo changed)"
check "re-run: single PreCompact entry"  1    "$(sj '.hooks.PreCompact | length')"
check "re-run: single PostCompact entry" 1    "$(sj '.hooks.PostCompact | length')"
check "re-run: no-change backup removed" yes  "$(has "$out2" "no settings.json changes")"
check "re-run: statusLine reported ours" yes  "$(has "$out2" "statusLine (already ours)")"
rm -rf "$HOME_DIR" "$src2"

# --- C. existing user statusLine is NEVER overwritten (negative control) -----
run_install '{"statusLine":{"type":"command","command":"my-own-statusline.sh"}}'
check "user sl: exit 0"                  0   "$RC"
check "user sl: value untouched"         "my-own-statusline.sh" "$(sj '.statusLine.command')"
check "user sl: skip message emitted"    yes "$(has "$OUT" "skip    statusLine")"
check "user sl: manual recipe in msg"    yes "$(has "$OUT" "call our script from your existing")"
check "user sl: hooks still installed"   yes "$(has "$(sj '.hooks.PreCompact[0].hooks[0].command')" 'write_handoff.sh')"
rm -rf "$HOME_DIR"

# --- D. uninstall: removes ours; preserves user's statusLine + co-located ----
# D1: our own full install, then uninstall -> statusLine + new hooks gone.
run_install __ABSENT__
src3="$(mktemp -d)"; cp "$REPO_ROOT/install.sh" "$src3/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src3/"
CLAUDE_HOME="$HOME_DIR" bash "$src3/install.sh" --uninstall >/dev/null 2>&1
check "uninstall: statusLine (ours) removed" null "$(sj '.statusLine // "null"')"
check "uninstall: PreCompact removed"        null "$(sj '.hooks.PreCompact // "null"')"
check "uninstall: PostCompact removed"       null "$(sj '.hooks.PostCompact // "null"')"
check "uninstall: reset perm removed"        ""   "$(sj '.permissions.allow // [] | .[]' | grep handoff_compact_reset)"
# uninstall_symlinks tidies up now-empty leaf dirs it created (rmdir only,
# never rm -r) — a clean install has nothing else under bin/ or skills/, so
# both should be gone once every symlink/copy in them is removed.
check "uninstall: bin/ dir removed (now empty)"    no "$([[ -d "$HOME_DIR/bin" ]] && echo yes || echo no)"
check "uninstall: skills/ dir removed (now empty)" no "$([[ -d "$HOME_DIR/skills" ]] && echo yes || echo no)"
rm -rf "$HOME_DIR" "$src3"

# D1b: a user's own extra file left in bin/ blocks the rmdir (never rm -r) —
# the dir AND the user's file must both survive uninstall untouched.
run_install __ABSENT__
printf '#!/bin/sh\necho mine\n' > "$HOME_DIR/bin/my-own-script.sh"
src3b="$(mktemp -d)"; cp "$REPO_ROOT/install.sh" "$src3b/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src3b/"
CLAUDE_HOME="$HOME_DIR" bash "$src3b/install.sh" --uninstall >/dev/null 2>&1
rc3b=$?
check "uninstall: exit 0 with foreign file present" 0  "$rc3b"
check "uninstall: ours still removed (foreign file)" no "$([[ -e "$HOME_DIR/bin/write_handoff.sh" ]] && echo yes || echo no)"
check "uninstall: non-empty bin/ dir kept"         yes "$([[ -d "$HOME_DIR/bin" ]] && echo yes || echo no)"
check "uninstall: user's own bin file untouched"   "echo mine" "$(tail -1 "$HOME_DIR/bin/my-own-script.sh" 2>/dev/null)"
rm -rf "$HOME_DIR" "$src3b"

# D2: a user's own statusLine + a co-located PreCompact user command survive.
read -r -d '' USERMIX <<'JSON' || true
{ "statusLine": {"type":"command","command":"my-own-statusline.sh"},
  "hooks": {
    "PreCompact": [ { "hooks": [
      { "type": "command", "command": "bash $HOME/.claude/bin/write_handoff.sh --if-curated >/dev/null 2>&1 || true" },
      { "type": "command", "command": "echo USER_PRECOMPACT" }
    ] } ]
  } }
JSON
run_install "$USERMIX" --uninstall
check "uninstall: user statusLine kept"      "my-own-statusline.sh" "$(sj '.statusLine.command')"
check "uninstall: user sl 'not ours' msg"    yes "$(has "$OUT" "statusLine (not ours; leaving alone)")"
check "uninstall: co-located user cmd kept"  yes "$(has "$(sj '.hooks.PreCompact[0].hooks[0].command')" 'USER_PRECOMPACT')"
check "uninstall: our PreCompact cmd gone"   no  "$(has "$(sj '[.. | objects | .command? // empty] | join(" ")')" 'write_handoff.sh')"
rm -rf "$HOME_DIR"

# --- E. --doctor covers the new scripts + statusLine state -------------------
run_install __ABSENT__
src4="$(mktemp -d)"; cp "$REPO_ROOT/install.sh" "$src4/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src4/"
dout="$(CLAUDE_HOME="$HOME_DIR" bash "$src4/install.sh" --doctor 2>&1)"; drc=$?
check "doctor: exit 0 (healthy)"            0   "$drc"
check "doctor: checks handoff_statusline"   yes "$(has "$dout" "bin/handoff_statusline.sh")"
check "doctor: checks handoff_compact_reset" yes "$(has "$dout" "bin/handoff_compact_reset.sh")"
check "doctor: statusLine wired (ours)"     yes "$(has "$dout" "statusLine wired (ours)")"
# user's-own state
printf '%s' '{"statusLine":{"type":"command","command":"my-own.sh"}}' > "$HOME_DIR/settings.json"
dout="$(CLAUDE_HOME="$HOME_DIR" bash "$src4/install.sh" --doctor 2>&1)"; drc=$?
check "doctor: user's own sl reported"      yes "$(has "$dout" "user's own")"
check "doctor: user's own sl not broken"    0   "$drc"
# unset state
printf '%s' '{}' > "$HOME_DIR/settings.json"
dout="$(CLAUDE_HOME="$HOME_DIR" bash "$src4/install.sh" --doctor 2>&1)"; drc=$?
check "doctor: unset sl reported"           yes "$(has "$dout" "statusLine unset")"
check "doctor: unset sl not broken"         0   "$drc"
rm -rf "$HOME_DIR" "$src4"

# --- F. manual snippet documents the new surface -----------------------------
# Since 0.9.0 a jq-less plain install refuses up front (jq is a hard runtime
# dependency), so the snippet's reachable path is the invalid-settings.json
# one: patch_settings refuses to auto-patch un-parseable JSON and prints the
# manual snippet instead. Exercise that path (jq present) and assert the
# snippet documents the full 0.9.0 surface.
src5="$(mktemp -d)"; HOME_DIR="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$src5/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src5/"
printf 'not json\n' > "$HOME_DIR/settings.json"
snip="$(CLAUDE_HOME="$HOME_DIR" bash "$src5/install.sh" 2>&1 || true)"
check "snippet: PreCompact line"        yes "$(has "$snip" '"PreCompact"')"
check "snippet: PostCompact line"       yes "$(has "$snip" '"PostCompact"')"
check "snippet: statusLine block"       yes "$(has "$snip" '"statusLine"')"
check "snippet: only-if-unset NOTE"     yes "$(has "$snip" "only add the \"statusLine\" key if you don't already have")"
rm -rf "$src5" "$HOME_DIR"

# jq-less plain install refuses up front (mediums fix, f3dde70) — the refusal
# must survive alongside the new wiring. Build a PATH that simply lacks jq
# (a failing jq stub is not enough: install.sh checks `command -v jq`).
nojq="$(path_without jq)"
src6="$(mktemp -d)"; HOME_DIR6="$(mktemp -d)"
cp "$REPO_ROOT/install.sh" "$src6/"; cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src6/"
out="$(PATH="$nojq" CLAUDE_HOME="$HOME_DIR6" bash "$src6/install.sh" 2>&1)" && rc=0 || rc=$?
check "no-jq: plain install refuses (rc!=0)" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check "no-jq: names jq as the reason"        yes "$(has "$out" 'jq not found')"
rm -rf "$src6" "$HOME_DIR6" "$nojq"

# --- G. truncated piped install stream fails loudly (v0.14.1) ----------------
# On bash 3.2, set -e + an already-armed EXIT trap swallow a stream parse
# error's status: a download truncated after `trap ... EXIT` exited 0 as if
# the install succeeded. The fix arms the trap inside the final dispatch
# group, so truncation can never coexist with an armed trap. Cut points:
# just past the trap line (the exact regression), and inside the dispatch
# tail. Both must exit nonzero and install nothing.
tg_home="$(mktemp -d)"
tg_total="$(wc -l < "$REPO_ROOT/install.sh" | tr -d ' ')"
tg_trap="$(grep -n '^trap cleanup EXIT$' "$REPO_ROOT/install.sh" | head -1 | cut -d: -f1)"
check "truncation guard: trap armed in dispatch group, not preamble" yes \
  "$([ -n "$tg_trap" ] && [ "$tg_trap" -gt $((tg_total / 2)) ] && echo yes || echo no)"
for tg_cut in $((tg_trap + 1)) $((tg_total - 10)); do
  head -n "$tg_cut" "$REPO_ROOT/install.sh" | CLAUDE_HOME="$tg_home" bash >/dev/null 2>&1
  rc=$?
  check "truncated at line $tg_cut/$tg_total: nonzero exit" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
done
check "truncated: nothing installed (no bin/)" no "$([[ -d "$tg_home/bin" ]] && echo yes || echo no)"
check "truncated: no settings.json created"    no "$([[ -f "$tg_home/settings.json" ]] && echo yes || echo no)"
rm -rf "$tg_home"

finish
