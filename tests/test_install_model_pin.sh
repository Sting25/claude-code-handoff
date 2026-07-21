#!/usr/bin/env bash
# Tests install.sh --model / HANDOFF_MODEL pin + the doctor 200k warning:
#   A. --model writes the key when absent, records it, settings stay intact
#   B. idempotent re-run; --uninstall removes only our unchanged pin
#   C. an existing differing "model" is preserved (never overwritten)
#   D. env fallback works and the --model flag beats it
#   E. plain install prints the one-line NOTE only when no model is set
#   F. uninstall preserves a value the user changed after we pinned it
#   G. doctor WARNs on bare 'opus'/'claude-opus-4-8', quiet otherwise
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh model pin"

if ! command -v jq >/dev/null 2>&1; then
  skip "jq not installed — install.sh settings patching is a no-op without it"
  finish
  exit
fi

HOME_DIR=""
OUT=""
# run_install <init|__ABSENT__> [install args...] ; sets RC, HOME_DIR, OUT.
# HANDOFF_MODEL is pinned to ${TEST_HM:-} so the caller's environment can
# never leak a real pin into the jail.
run_install() {
  local init="$1"; shift
  local src; src="$(mktemp -d)"; HOME_DIR="$(mktemp -d)"; OUT="$HOME_DIR/out.txt"
  cp "$REPO_ROOT/install.sh" "$src/"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
  [[ "$init" != "__ABSENT__" ]] && printf '%s' "$init" > "$HOME_DIR/settings.json"
  CLAUDE_HOME="$HOME_DIR" HANDOFF_MODEL="${TEST_HM:-}" bash "$src/install.sh" "$@" >"$OUT" 2>&1
  RC=$?
  rm -rf "$src"
}
# Re-run against the SAME jail (re-install / uninstall / doctor).
run_again() {
  local src; src="$(mktemp -d)"; OUT="$HOME_DIR/out.txt"
  cp "$REPO_ROOT/install.sh" "$src/"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/skills" "$src/"
  CLAUDE_HOME="$HOME_DIR" HANDOFF_MODEL="${TEST_HM:-}" bash "$src/install.sh" "$@" >"$OUT" 2>&1
  RC=$?
  rm -rf "$src"
}
model_val()  { jq -r '.model // "ABSENT"' "$HOME_DIR/settings.json" 2>/dev/null; }
valid_json() { jq -e . "$HOME_DIR/settings.json" >/dev/null 2>&1 && echo yes || echo no; }
has_ss()     { jq -e '.hooks.SessionStart' "$HOME_DIR/settings.json" >/dev/null 2>&1 && echo present || echo absent; }
record()     { [[ -f "$HOME_DIR/handoff-model-pin" ]] && echo yes || echo no; }
saw()        { grep -q "$1" "$OUT" && echo yes || echo no; }

# --- A. pin on fresh settings ---
run_install "" --model 'opus[1m]'
check "pin: exit 0"              0         "$RC"
check "pin: model written"       'opus[1m]' "$(model_val)"
check "pin: valid JSON"          yes       "$(valid_json)"
check "pin: hooks co-installed"  present   "$(has_ss)"
check "pin: record created"      yes       "$(record)"
check "pin: record value"        'opus[1m]' "$(tr -d '[:space:]' < "$HOME_DIR/handoff-model-pin")"
check "pin: no NOTE when pinned" no        "$(saw 'no model pinned')"

# --- B. idempotent re-run, then uninstall removes our pin ---
before="$(cat "$HOME_DIR/settings.json")"
run_again --model 'opus[1m]'
check "rerun: exit 0"            0         "$RC"
check "rerun: reports already"   yes       "$(saw 'model already set')"
check "rerun: settings unchanged" same     "$([[ "$before" == "$(cat "$HOME_DIR/settings.json")" ]] && echo same || echo changed)"
run_again --uninstall
check "uninstall: model removed" ABSENT    "$(model_val)"
check "uninstall: record gone"   no        "$(record)"
rm -rf "$HOME_DIR"

# --- C. existing differing model is never overwritten ---
run_install '{"model":"fable"}' --model 'opus[1m]'
check "existing: exit 0"         0         "$RC"
check "existing: preserved"      fable     "$(model_val)"
check "existing: no record"      no        "$(record)"
check "existing: notice printed" yes       "$(saw 'NOT overwriting')"
rm -rf "$HOME_DIR"

# --- D. env fallback + flag precedence ---
TEST_HM='sonnet' run_install ""
check "env: model from env"      sonnet    "$(model_val)"
rm -rf "$HOME_DIR"
TEST_HM='sonnet' run_install "" --model 'opus[1m]'
check "env: flag beats env"      'opus[1m]' "$(model_val)"
rm -rf "$HOME_DIR"

# --- E. plain install NOTE only when nothing is set ---
run_install ""
check "plain: NOTE printed"      yes       "$(saw 'no model pinned')"
rm -rf "$HOME_DIR"
run_install '{"model":"fable"}'
check "plain: quiet when set"    no        "$(saw 'no model pinned')"
rm -rf "$HOME_DIR"

# --- F. uninstall preserves a user-changed value ---
run_install "" --model 'opus[1m]'
jq '.model = "fable"' "$HOME_DIR/settings.json" > "$HOME_DIR/settings.json.new" \
  && mv "$HOME_DIR/settings.json.new" "$HOME_DIR/settings.json"
run_again --uninstall
check "user-edit: value kept"    fable     "$(model_val)"
check "user-edit: keep reported" yes       "$(saw 'you changed')"
check "user-edit: record gone"   no        "$(record)"
rm -rf "$HOME_DIR"

# --- G. doctor context-window warning ---
run_install '{"model":"opus"}'
run_again --doctor
check "doctor: WARN bare opus"   yes       "$(saw '200k-context')"
rm -rf "$HOME_DIR"
run_install '{"model":"claude-opus-4-8"}'
run_again --doctor
check "doctor: WARN bare full id" yes      "$(saw '200k-context')"
rm -rf "$HOME_DIR"
run_install '{"model":"opus[1m]"}'
run_again --doctor
check "doctor: quiet for [1m]"   no        "$(saw '200k-context')"
rm -rf "$HOME_DIR"
run_install ""
run_again --doctor
check "doctor: quiet when absent" no       "$(saw '200k-context')"
rm -rf "$HOME_DIR"

finish
