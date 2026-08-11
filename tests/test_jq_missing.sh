#!/usr/bin/env bash
# Coverage for the jq runtime-dependency checks (audit 2026-07-17): jq going
# missing used to disable the Stop hook, the ctx nudge, and the recover-tail
# rescue SILENTLY (every call site is wired '|| true'), while install.sh still
# printed "done" and --doctor reported all-healthy. Now:
#   - install.sh (install mode) refuses up front with a clear error;
#   - install.sh --doctor reports jq as BROKEN and exits non-zero;
#   - handoff_session_start.sh warns visibly (it needs no jq itself);
#   - handoff_recover_tail.sh errors instead of printing an empty "recovery".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "jq-missing behavior — install / doctor / session_start / recover_tail"

# The positive-control setups below need a real jq (mirrors the suite's
# convention of skipping jq-dependent files outright when it's absent).
if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — cannot build the with-jq controls"
  finish
  exit
fi

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

nojq="$(path_without jq)"
check "jq really absent on shim PATH" absent \
  "$(PATH="$nojq" command -v jq >/dev/null 2>&1 && echo present || echo absent)"

# --- install.sh refuses to install without jq --------------------------------
home="$(mktemp -d)"
out="$(PATH="$nojq" CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" 2>&1)"; rc=$?
check "install w/o jq: nonzero exit"      nonzero "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
check "install w/o jq: names jq"          yes     "$(has "$out" "jq not found")"
check "install w/o jq: does not say done" no      "$(has "$out" "/handoff is available now")"
check "install w/o jq: nothing installed" no      "$([[ -e "$home/bin/handoff_session_start.sh" ]] && echo yes || echo no)"
rm -rf "$home"

# --- install.sh --doctor flags a healthy-looking install as broken -----------
home="$(mktemp -d)"
CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" --copy >/dev/null 2>&1
out="$(CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" --doctor 2>&1)"; rc=$?
check "doctor with jq: exit 0"            0       "$rc"
check "doctor with jq: no jq complaint"   no      "$(has "$out" "jq not found")"
out="$(PATH="$nojq" CLAUDE_HOME="$home" bash "$REPO_ROOT/install.sh" --doctor 2>&1)"; rc=$?
check "doctor w/o jq: nonzero exit"       nonzero "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
check "doctor w/o jq: reports jq BROKEN"  yes     "$(has "$out" "jq not found")"
rm -rf "$home"

# --- handoff_session_start.sh warns, but still loads the handoff -------------
proj="$(mktemp -d)"; must mkdir -p "$proj/.claude"
must cat > "$proj/.claude/handoff_current.md" <<'EOF'
# handoff
## Notes from this session
Curated notes. JQLESS_MARKER
EOF
out="$( cd "$proj" && PATH="$nojq" CLAUDE_PROJECT_DIR="$proj" \
    bash "$REPO_ROOT/bin/handoff_session_start.sh" 2>&1 )"; rc=$?
check "session_start w/o jq: exit 0 (non-fatal)"  0   "$rc"
check "session_start w/o jq: warns about jq"      yes "$(has "$out" "jq not found")"
check "session_start w/o jq: handoff still loads" yes "$(has "$out" "JQLESS_MARKER")"
out="$( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" \
    bash "$REPO_ROOT/bin/handoff_session_start.sh" 2>&1 )"
check "session_start with jq: no warning"         no  "$(has "$out" "jq not found")"
rm -rf "$proj"

# --- handoff_recover_tail.sh errors instead of an empty 'recovery' -----------
out="$(PATH="$nojq" HANDOFF_BACKUP_DIR="$(mktemp -d)" \
    bash "$REPO_ROOT/bin/handoff_recover_tail.sh" SOMESESSION 2>&1)"; rc=$?
check "recover_tail w/o jq: nonzero exit"         nonzero "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
check "recover_tail w/o jq: says why"             yes     "$(has "$out" "jq not found")"
check "recover_tail w/o jq: no fake tail header"  no      "$(has "$out" "Recovered tail")"

rm -rf "$nojq"
finish
