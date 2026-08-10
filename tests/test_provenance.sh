#!/usr/bin/env bash
# Direct unit coverage for bin/handoff_provenance.sh — the trusted-rules lib
# is otherwise exercised only end-to-end (test_trusted_rules.sh drives it via
# write_handoff.sh + handoff_session_start.sh), so a regression in one helper
# surfaces as a distant, hard-to-localize failure. This file pins each helper's
# contract in isolation:
#   - handoff_bind_markers_balanced: strict BEGIN,END pairing in file order
#     (counts alone would accept END-before-BEGIN);
#   - handoff_ensure_secret: 64-hex 0600 generation, symlink refusal, and the
#     mode REPAIR of a pre-existing loose (0644) secret;
#   - handoff_mac_compute: the trailer-strip edges — a real trailer is
#     excluded from the digest, a prose lookalike is not, and an empty doc
#     still yields a valid MAC (grep -v selecting nothing must not abort
#     under the caller's pipefail);
#   - install.sh --doctor: the secret-hygiene report (BROKEN on loose modes
#     and planted symlinks, ok on a healthy file, note when absent).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Sourced lib: no shebang, no set -e of its own — safe under lib.sh's -uo
# pipefail. HANDOFF_SECRET_FILE is resolved at CALL time, so each check below
# points it at a per-fixture path (lib.sh's jail never receives a secret).
# shellcheck disable=SC1091
source "$REPO_ROOT/bin/handoff_provenance.sh"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

work="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
cleanup_on_exit "$work"

echo "provenance lib — marker balance, secret hygiene, MAC trailer edges, doctor"

# --- handoff_bind_markers_balanced -------------------------------------------
BEGIN='<!-- HANDOFF_BIND_BEGIN -->'
END='<!-- HANDOFF_BIND_END -->'

must mkdir -p "$work/markers"
printf '%s\nrule\n%s\nprose\n%s\nrule2\n%s\n' "$BEGIN" "$END" "$BEGIN" "$END" \
  > "$work/markers/ok.md"
printf '%s\nrule\n%s\n' "$END" "$BEGIN" > "$work/markers/end_first.md"
printf 'prose\n%s\nrule\n' "$BEGIN" > "$work/markers/unclosed.md"
printf '%s\n%s\nrule\n%s\n' "$BEGIN" "$BEGIN" "$END" > "$work/markers/double_begin.md"

handoff_bind_markers_balanced "$work/markers/ok.md"; rc=$?
check "markers: well-formed pairs accepted"      0 "$rc"
handoff_bind_markers_balanced "$work/markers/end_first.md"; rc=$?
check "markers: END before BEGIN rejected"       1 "$rc"
handoff_bind_markers_balanced "$work/markers/unclosed.md"; rc=$?
check "markers: unclosed BEGIN rejected"         1 "$rc"
handoff_bind_markers_balanced "$work/markers/double_begin.md"; rc=$?
check "markers: double BEGIN rejected"           1 "$rc"

# --- handoff_ensure_secret: generation ---------------------------------------
must mkdir -p "$work/gen"
sf="$work/gen/secret"
out="$(HANDOFF_SECRET_FILE="$sf" handoff_ensure_secret)"; rc=$?
check "ensure: first call succeeds"              0    "$rc"
check "ensure: echoes the secret path"           "$sf" "$out"
check "ensure: 64 lowercase hex"                 yes \
  "$(grep -Eq '^[0-9a-f]{64}$' "$sf" 2>/dev/null && echo yes || echo no)"
check "ensure: mode 600 on creation"             600  "$(file_mode "$sf")"

# --- handoff_ensure_secret: planted symlink refused --------------------------
must mkdir -p "$work/link"
must touch "$work/link/target"
must ln -s "$work/link/target" "$work/link/secret"
out="$(HANDOFF_SECRET_FILE="$work/link/secret" handoff_ensure_secret)"; rc=$?
check "ensure: planted symlink refused (rc)"     1  "$rc"
check "ensure: symlink target left empty"        no \
  "$([ -s "$work/link/target" ] && echo yes || echo no)"

# --- handoff_ensure_secret: REPAIRS a loose pre-existing secret --------------
# A 0644 secret (backup restore / dotfiles sync / old umask) must be chmod'd
# back to 600 on the read path, not returned as-is — the new behavior.
must mkdir -p "$work/loose"
lf="$work/loose/secret"
must cp "$sf" "$lf"
must chmod 644 "$lf"
before="$(cat "$lf")"
out="$(HANDOFF_SECRET_FILE="$lf" handoff_ensure_secret)"; rc=$?
check "repair: existing 0644 secret accepted"    0    "$rc"
check "repair: mode tightened to 600"            600  "$(file_mode "$lf")"
check "repair: content untouched"                yes \
  "$([ "$before" = "$(cat "$lf")" ] && echo yes || echo no)"

# --- handoff_mac_compute: trailer-strip edges --------------------------------
# Needs openssl (the function fails closed without it); mirror the
# test_trusted_rules.sh gate rather than asserting on the degradation path.
if command -v openssl >/dev/null 2>&1; then
  must mkdir -p "$work/mac"
  export_sf="$sf"   # reuse the generated 0600 secret for every compute below
  mac() { HANDOFF_SECRET_FILE="$export_sf" handoff_mac_compute "$@"; }

  # A well-formed trailer as the LAST line is excluded from the digest: the
  # MAC of body+trailer must equal the MAC of the bare body.
  printf 'line one\nline two\n' > "$work/mac/body.md"
  must cp "$work/mac/body.md" "$work/mac/trailed.md"
  printf '<!-- HANDOFF_HMAC: %s -->\n' \
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
    >> "$work/mac/trailed.md"
  m_body="$(mac "$work/mac/body.md")"; rc_body=$?
  m_trail="$(mac "$work/mac/trailed.md")"; rc_trail=$?
  check "mac: computes on bare body (rc)"        0   "$rc_body"
  check "mac: computes with trailer (rc)"        0   "$rc_trail"
  check "mac: well-formed trailer excluded"      yes \
    "$([ -n "$m_body" ] && [ "$m_body" = "$m_trail" ] && echo yes || echo no)"

  # A prose line merely STARTING with the prefix (short/invalid digest) must
  # stay in the digest — its MAC must differ from the bare body's.
  must cp "$work/mac/body.md" "$work/mac/prose.md"
  printf '<!-- HANDOFF_HMAC: deadbeef --> PROSE_DECOY\n' >> "$work/mac/prose.md"
  m_prose="$(mac "$work/mac/prose.md")"; rc=$?
  check "mac: prose lookalike computes (rc)"     0   "$rc"
  check "mac: prose lookalike stays in digest"   yes \
    "$([ -n "$m_prose" ] && [ "$m_prose" != "$m_body" ] && echo yes || echo no)"

  # Empty document: grep -v selects nothing (exit 1) and the function's
  # `|| true` keeps that from aborting under our pipefail — the contract is a
  # VALID MAC over the empty message, rc 0. Pinned here: an empty doc and a
  # doc consisting of ONLY a well-formed trailer both digest the empty body,
  # so their MACs must match.
  : > "$work/mac/empty.md"
  m_empty="$(mac "$work/mac/empty.md")"; rc=$?
  check "mac: empty doc -> rc 0"                 0   "$rc"
  check "mac: empty doc -> valid 64-hex MAC"     yes \
    "$(printf '%s' "$m_empty" | grep -Eq '^[0-9a-f]{64}$' && echo yes || echo no)"
  printf '<!-- HANDOFF_HMAC: %s -->\n' \
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" \
    > "$work/mac/only_trailer.md"
  m_only="$(mac "$work/mac/only_trailer.md")"
  check "mac: trailer-only doc == empty doc"     yes \
    "$([ "$m_only" = "$m_empty" ] && echo yes || echo no)"
else
  skip "openssl not installed — mac_compute trailer-edge checks skipped"
fi

# --- install.sh --doctor: secret-hygiene report ------------------------------
# CLAUDE_HOME fixture pattern (see test_install_*.sh). env -u strips lib.sh's
# exported secret jail so the doctor resolves its default path under the
# fixture home; hooks are deliberately NOT installed (doctor reports them
# MISSING and exits non-zero), so assert on the secret lines, not the rc.
INSTALL="$REPO_ROOT/install.sh"
home="$work/home"
must mkdir -p "$home"
dsec="$home/handoff_secret"
run_doctor() { env -u HANDOFF_SECRET_FILE CLAUDE_HOME="$home" bash "$INSTALL" --doctor 2>&1; }

must cp "$sf" "$dsec"
must chmod 644 "$dsec"
out="$(run_doctor)"
check "doctor: 0644 secret -> BROKEN"            yes "$(has "$out" "BROKEN  $dsec is group/other-readable")"
check "doctor: 0644 remedy is chmod 600"         yes "$(has "$out" "chmod 600")"

must chmod 600 "$dsec"
out="$(run_doctor)"
check "doctor: 0600 secret -> ok line"           yes "$(has "$out" "ok      $dsec")"
check "doctor: 0600 secret -> not BROKEN"        no  "$(has "$out" "BROKEN  $dsec")"

must rm "$dsec"
must ln -s "$work/link/target" "$dsec"
out="$(run_doctor)"
check "doctor: symlink secret -> BROKEN"         yes "$(has "$out" "BROKEN  $dsec is a symlink")"

must rm "$dsec"
out="$(run_doctor)"
check "doctor: absent secret -> note, no error"  yes "$(has "$out" "note    $dsec absent")"
check "doctor: absent secret -> not BROKEN"      no  "$(has "$out" "BROKEN  $dsec")"

finish
