#!/usr/bin/env bash
# Guard for issue #49: the test suite must be hermetic with respect to key
# material. write_handoff.sh generates the per-machine HMAC secret on first
# signed write, defaulting to $HOME/.claude/handoff_secret; lib.sh therefore
# exports a jailed HANDOFF_SECRET_FILE so that a test invoking write_handoff.sh
# WITHOUT a per-fixture override (exactly what the pre-existing
# test_write_handoff_*.sh files do) cannot create or touch a secret in the
# developer's real home. This file re-runs that scenario under a jailed HOME
# and asserts the side effect lands in the lib jail, not in HOME.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "secret jail — signing side effects stay out of \$HOME (issue #49)"

# The jail must exist and must not point back into the real default location.
check "lib.sh exports HANDOFF_SECRET_FILE" yes \
  "$([ -n "${HANDOFF_SECRET_FILE:-}" ] && echo yes || echo no)"
check "jail is not \$HOME/.claude/handoff_secret" no \
  "$([ "$HANDOFF_SECRET_FILE" = "$HOME/.claude/handoff_secret" ] && echo yes || echo no)"

# A signed write with NO per-invocation override — the exact call shape of the
# pre-existing write_handoff tests. The jailed HOME gets a .claude dir up
# front so "no secret appeared" can't pass vacuously for lack of a directory.
repo="$(mk_repo)" || { check "mk_repo" ok failed; finish; exit 1; }
jail_home="$(mktemp -d)"
must mkdir -p "$jail_home/.claude"
( cd "$repo" && HOME="$jail_home" bash "$REPO_ROOT/bin/write_handoff.sh" </dev/null >/dev/null 2>&1 )

check "no secret materialized in jailed \$HOME/.claude" no \
  "$([ -e "$jail_home/.claude/handoff_secret" ] && echo yes || echo no)"
check "secret went to the lib jail instead" yes \
  "$([ -f "$HANDOFF_SECRET_FILE" ] && echo yes || echo no)"
check "jailed secret mode 600" 600 "$(file_mode "$HANDOFF_SECRET_FILE")"
check "jailed secret is 64 lowercase hex" yes \
  "$(grep -qE '^[0-9a-f]{64}$' "$HANDOFF_SECRET_FILE" 2>/dev/null && echo yes || echo no)"

# --- HANDOFF_SECRET_FILE pointing at a DIRECTORY must fail loudly, not strand
# a fresh key file inside it on every signed write. Before the fix,
# handoff_ensure_secret() didn't check the resolved path's type: mktemp wrote
# a tmp key file next to it and `mv tmp <dir>` MOVED THE TMP INTO the
# directory (mv's into-a-directory behavior) instead of erroring — reporting
# success while stranding one key file per write, so signing/verification
# never converged on a single key.
echo
echo "HANDOFF_SECRET_FILE as a directory (issue: strands a key file per write)"

repo2="$(mk_repo)" || { check "mk_repo (dir case)" ok failed; finish; exit 1; }
secret_dir="$(mktemp -d)/secret-as-dir"
must mkdir -p "$secret_dir"

dir_err="$(cd "$repo2" && HANDOFF_SECRET_FILE="$secret_dir" \
  bash "$REPO_ROOT/bin/write_handoff.sh" </dev/null 2>&1 >/dev/null)"

loud_present="no"
case "$dir_err" in
  *"HANDOFF_SECRET_FILE"*"$secret_dir"*"not a regular file"*) loud_present="yes" ;;
esac
check "loud stderr message names the directory + explains the fix" yes "$loud_present"

check "no stranded key file inside the directory" 0 \
  "$(find "$secret_dir" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"

check "write still completes (degraded/unsigned)" yes \
  "$([ -f "$repo2/.claude/handoff_current.md" ] && echo yes || echo no)"

check "published handoff has no HMAC trailer (unsigned, same as no-openssl degrade)" 0 \
  "$(grep -c '^<!-- HANDOFF_HMAC: ' "$repo2/.claude/handoff_current.md" 2>/dev/null || true)"

finish
