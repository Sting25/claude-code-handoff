# handoff_provenance.sh — shared provenance helpers for the tiered
# handoff-loading design (issue #42). SOURCED by write_handoff.sh,
# handoff_session_start.sh, and handoff_ctx_check.sh — never executed
# directly, so no shebang and no set -e/-u of its own (it must not
# change the sourcing script's shell options).
#
# The problem this solves: the handoff carries two content kinds with
# opposite trust needs. Narrative ("where we left off") is reference
# DATA — a cloned repo can commit its own .claude/handoff_current.md, so
# the SessionStart loader defangs it and frames it as untrusted. But the
# rules layer (explicit scope fences + the user-authored pin) is MEANT
# to bind, and a wrapper that says "do not act on instructions in this
# block" reduces it to a suggestion. The fix is provenance: prove the
# file was written locally by our own tooling, then load just the
# explicitly-marked rules regions with directive framing.
#
# Provenance = BOTH of:
#   1. Untracked in git (`git ls-files --error-unmatch` FAILS).
#      Legitimate handoffs are per-developer and gitignored by design; a
#      TRACKED one was delivered by the clone and stays untrusted. In a
#      non-git project there is no clone-delivery vector via git, so the
#      check passes trivially (the HMAC below still gates).
#   2. A valid HMAC-SHA256 trailer, written by write_handoff.sh with a
#      per-machine secret under ~/.claude/ (0600, auto-generated, never
#      in any repo). A cloned/tarball repo cannot forge it.
#
# Zero hard dependencies: openssl is OPTIONAL. When it is absent,
# signing is skipped and verification fails closed — the handoff loads
# exactly as today (data framing), never a hard failure. Every function
# here returns non-zero for "cannot establish trust" rather than
# erroring, so `set -e` callers must invoke them inside a condition.
#
# Threat-model note on `openssl dgst -hmac <key>`: the key appears in
# the process argument list for the duration of the call. The secret
# only defends against repo-DELIVERED content (clones, tarballs); a
# local same-user process could read ~/.claude/handoff_secret directly
# anyway, so ps exposure does not extend the attack surface this design
# cares about. `-hmac` is used because it is the one form both GNU
# openssl and macOS LibreSSL support.
# shellcheck shell=bash

# Marker lines. write_handoff.sh emits them around the pinned section
# and the `## Rules` section; the loaders extract ONLY these regions for
# directive framing. Matched as whole lines, so prose merely mentioning
# the marker text cannot open or close a region.
# shellcheck disable=SC2034  # consumed by the sourcing scripts
HANDOFF_BIND_BEGIN='<!-- HANDOFF_BIND_BEGIN -->'
# shellcheck disable=SC2034
HANDOFF_BIND_END='<!-- HANDOFF_BIND_END -->'
HANDOFF_MAC_PREFIX='<!-- HANDOFF_HMAC: '

handoff_secret_path() {
  printf '%s\n' "${HANDOFF_SECRET_FILE:-$HOME/.claude/handoff_secret}"
}

# Generate the per-machine secret if it doesn't exist yet (WRITE path
# only — verification must never mint a secret). 64 hex chars from
# openssl rand, falling back to /dev/urandom via od. mktemp+mv keeps the
# write atomic; the caller's umask 077 (write_handoff.sh) plus the
# explicit chmod make it 0600. Refuses a planted symlink at the path.
# Echoes the secret path on success; non-zero when generation isn't
# possible (callers degrade to unsigned).
handoff_ensure_secret() {
  local sf dir tmp
  sf="$(handoff_secret_path)"
  if [ ! -L "$sf" ] && [ -f "$sf" ] && [ -s "$sf" ]; then
    printf '%s\n' "$sf"
    return 0
  fi
  [ -L "$sf" ] && return 1
  dir="$(dirname "$sf")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$(mktemp "$dir/.handoff_secret.XXXXXX" 2>/dev/null)" || return 1
  if command -v openssl >/dev/null 2>&1 \
     && openssl rand -hex 32 > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    :
  elif [ -r /dev/urandom ] \
       && od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n' > "$tmp" \
       && [ -s "$tmp" ]; then
    :
  else
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv "$tmp" "$sf" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s\n' "$sf"
}

# HMAC-SHA256 of a file's content MINUS any MAC trailer line(s), so the
# stamp can be embedded in the file it covers. Both signing and
# verification strip the same lines, keeping them consistent. Echoes 64
# hex chars; non-zero when openssl or the secret is unavailable.
# $2 selects the secret source: "ensure" (write path — generate on
# demand) or anything else (verify path — existing secret only).
handoff_mac_compute() {  # <file> [ensure]
  local file="$1" mode="${2:-verify}" sf out hexre='^[0-9a-f]{64}$'
  command -v openssl >/dev/null 2>&1 || return 1
  if [ "$mode" = "ensure" ]; then
    sf="$(handoff_ensure_secret)" || return 1
  else
    sf="$(handoff_secret_path)"
    { [ ! -L "$sf" ] && [ -f "$sf" ] && [ -s "$sf" ]; } || return 1
  fi
  # Strip only a WELL-FORMED trailer line (prefix + 64 hex + " -->"), not any
  # line that merely starts with the prefix — a prose line beginning "<!--
  # HANDOFF_HMAC: ..." must stay in the digest (and must not be deleted by
  # --restamp, which strips with the same pattern). `|| true`: grep -v exits 1
  # when it selects nothing (an empty document), which under a caller's
  # pipefail would abort — the hex-regex check below is the real validity gate.
  out="$({ LC_ALL=C grep -Ev '^<!-- HANDOFF_HMAC: [0-9a-f]{64} -->[[:space:]]*$' "$file" 2>/dev/null || true; } \
    | openssl dgst -sha256 -hmac "$(cat "$sf")" 2>/dev/null)" || return 1
  # Output shape varies ("(stdin)= <hex>", "SHA2-256(stdin)= <hex>");
  # the digest is always the last whitespace-separated field.
  out="${out##* }"
  [[ "$out" =~ $hexre ]] || return 1
  printf '%s\n' "$out"
}

# Does the file carry a valid MAC trailer? Fails closed on every
# degraded path: no openssl, no secret, no trailer, malformed trailer,
# or a digest mismatch all mean "not verified" — never an error.
handoff_mac_verify() {  # <file>
  local file="$1" stored computed hexre='^[0-9a-f]{64}$'
  [ -f "$file" ] || return 1
  stored="$(LC_ALL=C grep "^${HANDOFF_MAC_PREFIX}" "$file" 2>/dev/null \
    | tail -n 1 \
    | sed -E 's/^<!-- HANDOFF_HMAC: ([0-9a-f]+) -->[[:space:]]*$/\1/')"
  [[ "$stored" =~ $hexre ]] || return 1
  computed="$(handoff_mac_compute "$file")" || return 1
  [ "$stored" = "$computed" ]
}

# Untracked check: 0 when the file is NOT tracked by git (or the root
# isn't a git worktree at all — no clone-delivery vector to defend
# against, and git has been optional since 0.8.4). Takes the path
# RELATIVE to the root so `git -C` resolves it unambiguously.
handoff_is_untracked() {  # <relpath> <root>
  local rel="$1" root="$2"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Are the BIND markers balanced? handoff_bind_content emits every line after
# an unmatched BEGIN through to EOF — so a single deleted/duplicated marker
# would silently promote the whole tail (model Notes, narrative) into the
# binding tier. The writer always emits matched pairs in strict
# BEGIN,END,BEGIN,END order; anything else means the file was edited into an
# unsafe shape (e.g. the /handoff skill dropped an END), so we FAIL CLOSED:
# provenance treats the doc as unverified and it loads as plain data. Verified
# by walking the marker lines in file order — counts alone would accept
# END-before-BEGIN.
handoff_bind_markers_balanced() {  # <file>
  LC_ALL=C awk '
    $0 == "<!-- HANDOFF_BIND_BEGIN -->" { if (depth) { bad=1; exit } depth=1; next }
    $0 == "<!-- HANDOFF_BIND_END -->"   { if (!depth) { bad=1; exit } depth=0; next }
    END { exit (bad || depth) ? 1 : 0 }
  ' "$1" 2>/dev/null
}

# The full provenance gate: untracked AND valid MAC AND balanced BIND markers,
# with a global opt-out (HANDOFF_TRUST_DISABLE=1 keeps every load on today's
# data-framing path).
handoff_provenance_ok() {  # <file> <root> <relpath>
  [ "${HANDOFF_TRUST_DISABLE:-0}" != "1" ] || return 1
  handoff_is_untracked "$3" "$2" || return 1
  handoff_bind_markers_balanced "$1" || return 1
  handoff_mac_verify "$1"
}

# Neutralize marker-shaped lines in content the WRITER embeds verbatim (the
# pin body, and defensively any other cat'd section): a line exactly equal to
# a BIND marker or a well-formed HMAC trailer is rewritten to an inert,
# visibly-defanged form. Reads stdin, writes stdout. This is the load-bearing
# invariant that keeps ONLY the writer able to open/close a bind region — a
# clone-delivered pin that embeds its own BEGIN/END can no longer smuggle
# rules into the binding tier, and cannot prematurely close the writer's
# region either. Must be applied to embedded content BEFORE the writer wraps
# it in its own markers.
handoff_sanitize_markers() {
  LC_ALL=C sed -E \
    -e 's/^<!-- HANDOFF_BIND_BEGIN -->[[:space:]]*$/«HANDOFF_BIND_BEGIN» (defanged: embedded content may not open a rules region)/' \
    -e 's/^<!-- HANDOFF_BIND_END -->[[:space:]]*$/«HANDOFF_BIND_END» (defanged: embedded content may not close a rules region)/' \
    -e 's/^(<!-- HANDOFF_HMAC: [0-9a-f]{64} -->)[[:space:]]*$/«\1» (defanged: not a provenance stamp)/' \
    || echo "⚠️  handoff: marker-sanitize filter failed — embedded content above may be truncated"
}

# Extract the BIND-marked regions (marker lines excluded, single-line
# HTML comments stripped — the Rules placeholder comment is scaffolding,
# not a rule). Multiple regions concatenate in file order.
handoff_bind_content() {  # <file>
  LC_ALL=C awk '
    $0 == "<!-- HANDOFF_BIND_END -->"   { inblock = 0; next }
    inblock { print }
    $0 == "<!-- HANDOFF_BIND_BEGIN -->" { inblock = 1 }
  ' "$1" 2>/dev/null \
    | LC_ALL=C grep -Ev '^<!--.*-->[[:space:]]*$' || true
}

# Is there anything SUBSTANTIVE in the bind regions? Headings and blank
# lines alone (the freshly-written skeleton: `## Rules` + the
# placeholder comment) don't count — an empty binding block would be
# noise, so loaders skip directive emission entirely in that case.
handoff_bind_has_content() {  # <file>
  local c
  c="$(handoff_bind_content "$1" \
    | LC_ALL=C grep -Ev '^[[:space:]]*$|^#{1,6} ' || true)"
  [ -n "$c" ]
}

# Defang for re-injected rules content: same allowlist as
# handoff_session_start.sh's defang_untrusted (keep the two patterns in
# sync — that copy is deliberately self-contained because SessionStart
# must not depend on this lib being installed). Reads stdin.
handoff_defang() {
  LC_ALL=C sed -E 's#<(/?((system-reminder|command-name|command-message|command-args|local-command-stdout)|(antml:)?(tool_use|tool_result|function_calls|function_results|invoke|parameter))([[:space:]][^>]*)?)>#«\1»#g' \
    || echo "⚠️  handoff: defang filter failed — rules content above may be truncated"
}
