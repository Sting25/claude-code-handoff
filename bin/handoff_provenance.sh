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
#      per-machine secret under ~/.claude/ (or $CLAUDE_HOME, see
#      handoff_secret_path below; 0600, auto-generated, never in any
#      repo). A cloned/tarball repo cannot forge it.
#
# Zero hard dependencies: openssl is OPTIONAL. When it is absent,
# signing is skipped and verification fails closed — the handoff loads
# exactly as today (data framing), never a hard failure. Every function
# here returns non-zero for "cannot establish trust" rather than
# erroring, so `set -e` callers must invoke them inside a condition.
#
# Threat-model note on the HMAC construction: the obvious
# `openssl dgst -hmac <key>` puts the key in the process argument list,
# and argv is readable by OTHER users via ps on a multi-user host —
# unlike the 0600 secret file itself. (An earlier revision accepted the
# exposure on the grounds that a same-user process could read the file
# anyway; that rationale ignored the cross-user ps window, and signing
# fires on every SessionEnd/PreCompact.) So handoff_mac_compute builds
# HMAC-SHA256 from its definition instead — two openssl digest passes
# over stdin, with the ipad/opad key blocks emitted by the printf
# BUILTIN (no separate process, no argv) — and openssl only ever sees
# data on stdin. Digest-identical to `-hmac` for the same key bytes,
# so docs signed by older versions keep verifying.
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

# The section headings write_handoff.sh emits IMMEDIATELY after each of its
# own BIND_BEGIN lines. They are the shape that tells a legitimate,
# writer-opened region apart from one a later editor introduced — see
# handoff_guard_bind_regions. Defined here (and defaulted in write_handoff.sh
# for the lib-absent install) so the emitter and the guard can never drift.
# shellcheck disable=SC2034  # consumed by the sourcing scripts
HANDOFF_PIN_HEADING='## 📌 Pinned — carried forward every handoff'
# shellcheck disable=SC2034
HANDOFF_RULES_HEADING='## Rules (fences — carried into the next session)'
# shellcheck disable=SC2034
HANDOFF_NOTES_HEADING='## Notes from this session'

# Mirrors install.sh's claude_home="${CLAUDE_HOME:-$HOME/.claude}" EXACTLY.
# This used to hardcode $HOME/.claude/handoff_secret, ignoring CLAUDE_HOME —
# the one holdout after install.sh's doctor check and remove_secret_if_ours
# were already CLAUDE_HOME-aware. Result: --doctor could say "ok" about
# $CLAUDE_HOME/handoff_secret while this file's callers actually signed under
# $HOME/.claude/handoff_secret — a false clean on the exposure doctor exists
# to catch. Following install.sh (vs. hardcoding doctor back) is also the
# back-compat-safe direction: CLAUDE_HOME is undocumented/test-only (never in
# the README), so ${CLAUDE_HOME:-$HOME/.claude} == $HOME/.claude for every
# real install — a no-op change, not a relocation — whereas the alternative
# would make remove_secret_if_ours (already claude_home-based) target a file
# signing never used whenever CLAUDE_HOME is set.
handoff_secret_path() {
  printf '%s\n' "${HANDOFF_SECRET_FILE:-${CLAUDE_HOME:-$HOME/.claude}/handoff_secret}"
}

# ---------------------------------------------------------------------------
# Root resolution — the ONE way every handoff script picks its project root.
#
# Before this existed the seven bin/ scripts resolved "repo root" three
# different ways: the writer hooks used a bare `git rev-parse --show-toplevel`
# (anchored on the hook process's CWD), the SessionStart loader used
# `git -C "$CLAUDE_PROJECT_DIR"`, and the statusline trusted its payload dir.
# Whenever cwd != CLAUDE_PROJECT_DIR — worktrees, submodules, a `cd` during
# the session — the writers and the loader disagreed on where `.claude/`
# lives: the handoff was written under one root and loaded (or not) from
# another, silently. This resolver gives them all the same answer.
#
# Usage:   handoff_resolve_root [payload_cwd]
# Sets (namespaced globals; never echoes, so `set -e` callers can call it
# bare):
#   HANDOFF_ROOT         resolved project root
#   HANDOFF_ROOT_IN_GIT  1 when the root is a git worktree top, else 0
#   HANDOFF_ROOT_ANCHOR  the anchor dir the resolution started from
#   HANDOFF_ROOT_VIA     which precedence rung chose the anchor:
#                        project_dir | payload_cwd | pwd
#
# Anchor precedence (first hit wins):
#   1. $CLAUDE_PROJECT_DIR — set AND an existing directory. Claude Code
#      exports it for every hook; it names the LAUNCH project regardless of
#      what the session later cd'd to, so it must beat the process cwd.
#      Validated with -d (it never was before): a stale/garbage value must
#      not become the root.
#   2. $1 (payload_cwd) — non-empty AND an existing directory. Hook payloads
#      carry a `cwd` field; the statusline passes its authoritative
#      `workspace.project_dir` here. Callers pass "" when they have none.
#   3. $PWD — matches the historical behavior of skill-invoked runs, where
#      the Bash tool env has no CLAUDE_PROJECT_DIR.
#
# The root is then `git -C "$anchor" rev-parse --show-toplevel` — NEVER a
# bare `git rev-parse`, which silently re-anchors on the process cwd. A
# non-git anchor is its own root (in_git=0).
#
# Anchored INSIDE a `.git` dir (e.g. the user cd'd into it), --show-toplevel
# fails outright; without a rescue the root would become the .git dir itself
# and the handoff would land at `.git/.claude`. Recover the enclosing repo
# via the common dir's parent.
#
# Worktree opt-in (HANDOFF_ANCHOR=common): resolve the root to the MAIN
# repo (parent of `git rev-parse --git-common-dir`), so every linked
# worktree shares one `.claude/` and handoffs survive `git worktree remove`.
# The DEFAULT stays per-worktree toplevel, deliberately: flipping it would
# silently relocate every existing user's handoff files on upgrade — worse
# than the (documented, opt-in-fixable) worktree-deletion hazard. Unset or
# HANDOFF_ANCHOR=toplevel keeps current behavior.
#
# HANDOFF_DEBUG=1 prints a one-line trace to stderr.

# shellcheck disable=SC2034  # consumed by the sourcing scripts
HANDOFF_ROOT=""
# shellcheck disable=SC2034
HANDOFF_ROOT_IN_GIT=0
# shellcheck disable=SC2034
HANDOFF_ROOT_ANCHOR=""
# shellcheck disable=SC2034
HANDOFF_ROOT_VIA=""

handoff_resolve_root() {  # [payload_cwd]
  local anchor via toplevel common common_phys parent
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR:-}" ]; then
    anchor="$CLAUDE_PROJECT_DIR" via="project_dir"
  elif [ -n "${1:-}" ] && [ -d "${1:-}" ]; then
    anchor="$1" via="payload_cwd"
  else
    anchor="$PWD" via="pwd"
  fi
  HANDOFF_ROOT_ANCHOR="$anchor"
  HANDOFF_ROOT_VIA="$via"
  HANDOFF_ROOT="$anchor"
  HANDOFF_ROOT_IN_GIT=0

  toplevel="$(git -C "$anchor" rev-parse --show-toplevel 2>/dev/null)" || toplevel=""
  if [ -n "$toplevel" ]; then
    HANDOFF_ROOT="$toplevel"
    HANDOFF_ROOT_IN_GIT=1
    if [ "${HANDOFF_ANCHOR:-toplevel}" = "common" ]; then
      # Main-repo root = parent of the common git dir. --git-common-dir may
      # print a RELATIVE path (relative to the git process cwd, i.e. our
      # anchor — from a main-repo toplevel it is just ".git"), so prefix the
      # anchor before walking up. Any failure falls back to the toplevel
      # already set above.
      common="$(git -C "$anchor" rev-parse --git-common-dir 2>/dev/null)" || common=""
      case "$common" in
        ""|/*) : ;;
        *) common="$anchor/$common" ;;
      esac
      if [ -n "$common" ] && parent="$(cd "$common/.." 2>/dev/null && pwd -P)" \
         && [ -d "$parent" ]; then
        HANDOFF_ROOT="$parent"
      fi
    fi
  elif [ "$(git -C "$anchor" rev-parse --is-inside-git-dir 2>/dev/null)" = "true" ]; then
    # Anchored inside .git itself: --show-toplevel fails here, and treating
    # the anchor as a non-git root would put the handoff at `.git/.claude`.
    # The common dir resolves even from in here ("." when the anchor IS the
    # main .git dir); its physical parent is the repo root — but only claim
    # that when the dir is actually named ".git" (a bare repo has no
    # worktree to anchor on, so it keeps the non-git fallback).
    common="$(git -C "$anchor" rev-parse --git-common-dir 2>/dev/null)" || common=""
    case "$common" in
      ""|/*) : ;;
      *) common="$anchor/$common" ;;
    esac
    if [ -n "$common" ] && common_phys="$(cd "$common" 2>/dev/null && pwd -P)" \
       && [ "${common_phys##*/}" = ".git" ] && [ -d "${common_phys%/.git}" ]; then
      HANDOFF_ROOT="${common_phys%/.git}"
      HANDOFF_ROOT_IN_GIT=1
    fi
  fi

  if [ "${HANDOFF_DEBUG:-0}" = "1" ]; then
    printf 'handoff: root=%s in_git=%s anchor=%s via=%s\n' \
      "$HANDOFF_ROOT" "$HANDOFF_ROOT_IN_GIT" "$anchor" "$via" >&2
  fi
  return 0
}

# Repair a secret file whose mode has group/other bits. The existing-file
# fast paths below (ensure + verify) would otherwise use a 0644 secret
# silently forever — and a group/other-readable HMAC key lets any local
# reader forge the binding-rules trailer. Loose modes arrive from outside
# our writers: a backup restore, a dotfiles sync, or an earlier version
# generating under a permissive umask. chmod 600 on sight; when the chmod
# fails (e.g. file owned by another user), warn on stderr — one line —
# and CONTINUE: degrading signing over a perms warning would be worse
# than the exposure the warning flags. Portable mode read: GNU `stat -c
# %a` with BSD `stat -f %Lp` fallback (the repo-wide dual idiom). Always
# returns 0 so bare calls are safe under a sourcing script's `set -e`.
handoff_secret_tighten() {  # <file>
  local m
  m="$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)" || m=""
  # Unreadable/odd mode string: nothing actionable (a chmod would likely
  # fail for the same reason), so leave it to the read that follows.
  case "$m" in "" | *[!0-7]*) return 0 ;; esac
  if (( 8#$m & 8#77 )); then
    chmod 600 "$1" 2>/dev/null \
      || printf 'handoff: warning: secret %s is group/other-accessible (mode %s) and chmod 600 failed — fix it manually\n' "$1" "$m" >&2
  fi
  return 0
}

# Generate the per-machine secret if it doesn't exist yet (WRITE path
# only — verification must never mint a secret). 64 hex chars from
# openssl rand, falling back to /dev/urandom via od. mktemp+mv keeps the
# write atomic; the caller's umask 077 (write_handoff.sh) plus the
# explicit chmod make it 0600. Refuses a planted symlink at the path.
# An EXISTING secret gets its mode checked/repaired (handoff_secret_tighten)
# before being returned — never trusted to still be 0600.
# Echoes the secret path on success; non-zero when generation isn't
# possible (callers degrade to unsigned).
handoff_ensure_secret() {
  local sf dir tmp
  sf="$(handoff_secret_path)"
  if [ ! -L "$sf" ] && [ -f "$sf" ] && [ -s "$sf" ]; then
    handoff_secret_tighten "$sf"
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
    # Verify path accepts an existing secret without going through ensure,
    # so it needs the same mode check/repair (see handoff_secret_tighten).
    handoff_secret_tighten "$sf"
  fi
  # HMAC-SHA256 from the definition — H((K'⊕opad) ‖ H((K'⊕ipad) ‖ m)) —
  # instead of `openssl dgst -hmac "$key"`, so the key NEVER appears in a
  # process argument list (see the threat-model note in the header). The
  # key bytes here are the literal file content minus trailing newlines,
  # exactly what `-hmac "$(cat "$sf")"` used before, so the digests are
  # bit-identical and older signed docs keep verifying.
  local key kb pad_i='' pad_o='' x b i inner
  key="$(cat "$sf" 2>/dev/null)" || return 1
  [ -n "$key" ] || return 1
  # Key block K': hex of the key bytes; >64-byte keys are first hashed
  # (per RFC 2104), then zero-padded to the 64-byte SHA-256 block size.
  # od (POSIX) renders the bytes; the generated secret is 64 ASCII hex
  # chars = exactly one block, so both branches are rare in practice.
  # -v is MANDATORY: without it od replaces any run of identical input
  # lines with a single "*", so a key containing repeated 16-byte blocks
  # would be silently truncated — collapsing distinct keys onto one MAC
  # and breaking cross-version verification for that key class.
  kb="$(printf '%s' "$key" | od -An -v -tx1 2>/dev/null | tr -d ' \n')"
  [ -n "$kb" ] || return 1
  if [ "${#kb}" -gt 128 ]; then
    kb="$(printf '%s' "$key" | openssl dgst -sha256 -binary 2>/dev/null \
      | od -An -v -tx1 2>/dev/null | tr -d ' \n')"
    [ "${#kb}" = 64 ] || return 1
  fi
  while [ "${#kb}" -lt 128 ]; do kb="${kb}00"; done
  # ipad/opad blocks as \xHH escape strings, built with the printf
  # BUILTIN (printf -v spawns no process, so no argv for ps to see).
  for ((i = 0; i < 128; i += 2)); do
    b=$((16#${kb:i:2}))
    printf -v x '\\x%02x' $((b ^ 0x36)); pad_i+=$x
    printf -v x '\\x%02x' $((b ^ 0x5c)); pad_o+=$x
  done
  # Inner pass: ipad block, then the doc minus any WELL-FORMED trailer
  # line (prefix + 64 hex + " -->") — not any line that merely starts
  # with the prefix; a prose line beginning "<!-- HANDOFF_HMAC: ..."
  # must stay in the digest (and must not be deleted by --restamp,
  # which strips with the same pattern). `|| true`: grep -v exits 1
  # when it selects nothing (an empty document), which under a caller's
  # pipefail would abort — the hex-regex check below is the real gate.
  # shellcheck disable=SC2059  # deliberate: the format IS the \xHH data
  inner="$({ printf "$pad_i"
             LC_ALL=C grep -Ev '^<!-- HANDOFF_HMAC: [0-9a-f]{64} -->[[:space:]]*$' "$file" 2>/dev/null || true
           } | openssl dgst -sha256 -binary 2>/dev/null \
             | od -An -v -tx1 2>/dev/null | tr -d ' \n')" || return 1
  [ "${#inner}" = 64 ] || return 1
  # Outer pass: opad block plus the inner digest bytes. The inner hex is
  # machine-generated [0-9a-f], so sed turning it into \xHH escapes for
  # the printf builtin is injection-safe; it reaches sed via stdin, not
  # argv.
  # shellcheck disable=SC2059  # deliberate: the format IS the \xHH data
  out="$({ printf "$pad_o"
           printf "$(printf '%s' "$inner" | sed 's/../\\x&/g')"
         } | openssl dgst -sha256 2>/dev/null)" || return 1
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

# Re-establish "only the writer may open a bind region" over a document that
# has been EDITED since it was built, then re-signed (`write_handoff.sh
# --restamp`). handoff_sanitize_markers protects content the writer embeds at
# build time; this protects the whole document at restamp time, which is the
# other half of the same invariant.
#
# Why it is needed: the /handoff skill has the model rewrite the Notes block
# and then restamps. Restamp signs whatever bytes are on disk, so a matched
# BIND_BEGIN/END pair written into Notes — by a model steered by prompt
# injection in anything it read this session — would be signed here, pass
# provenance, and load into the NEXT session as verified binding rules.
#
# The rule: a BEGIN is kept only when the very next line is one of the
# writer's own section headings (the writer always emits the heading directly
# after the marker), an END only when a kept region is open, and NOTHING is
# kept at or after the Notes heading — the region below it is model-authored
# by design and must stay on the data tier. Everything else is rewritten to
# the same visibly-defanged form handoff_sanitize_markers uses. Reads stdin,
# writes stdout.
handoff_guard_bind_regions() {
  LC_ALL=C awk \
    -v begin_m="$HANDOFF_BIND_BEGIN" \
    -v end_m="$HANDOFF_BIND_END" \
    -v pin_h="$HANDOFF_PIN_HEADING" \
    -v rules_h="$HANDOFF_RULES_HEADING" \
    -v notes_h="$HANDOFF_NOTES_HEADING" \
    -v begin_d='«HANDOFF_BIND_BEGIN» (defanged: only write_handoff.sh may open a rules region)' \
    -v end_d='«HANDOFF_BIND_END» (defanged: only write_handoff.sh may close a rules region)' '
    {
      # A BEGIN is held for one line so its successor can be inspected.
      if (held) {
        held = 0
        if ($0 == pin_h || $0 == rules_h) { print begin_m; inside = 1 }
        else { print begin_d }
      }
      if ($0 == notes_h) { untrusted = 1 }
      if ($0 == begin_m) {
        if (untrusted || inside) print begin_d; else held = 1
        next
      }
      if ($0 == end_m) {
        if (untrusted || !inside) print end_d; else { print end_m; inside = 0 }
        next
      }
      print
    }
    END { if (held) print begin_d }
  ' || echo "⚠️  handoff: bind-region guard failed — content above may be truncated"
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
