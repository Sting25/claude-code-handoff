#!/usr/bin/env bash
# Tests the --if-curated guard in write_handoff.sh: the SessionEnd safety-net
# must OVERWRITE only an unedited placeholder, and PRESERVE anything curated —
# including curated files where the placeholder sentinel string happens to
# appear elsewhere (embedded commit subject, or quoted in prose). Regression
# guard for the sentinel-scoping data-loss fix.
#
# Observable: each fixture embeds a unique MARKER. After `write_handoff.sh
# --if-curated`, MARKER surviving => preserved; MARKER gone => overwritten.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WH="$REPO_ROOT/bin/write_handoff.sh"
SENTINEL="<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->"

# run_case <name> <preserve|overwrite> ; fixture comes from stdin
run_case() {
  local name="$1" expect="$2" repo got
  repo="$(mk_repo)"
  mkdir -p "$repo/.claude"
  cat > "$repo/.claude/handoff_current.md"
  ( cd "$repo" && HANDOFF_NO_GITIGNORE_BOOTSTRAP=1 HANDOFF_HISTORY_KEEP=0 \
      bash "$WH" --if-curated >/dev/null 2>&1 )
  if grep -qF "MARKER_$name" "$repo/.claude/handoff_current.md" 2>/dev/null; then
    got=preserve
  else
    got=overwrite
  fi
  check "$name" "$expect" "$got"
  rm -rf "$repo"
}

echo "write_handoff.sh --if-curated (sentinel scoping)"

# Genuine placeholder: sentinel is the first non-blank line under the header.
# MARKER lives in the snapshot region, so a correct overwrite drops it.
run_case placeholder overwrite <<EOF
# handoff
MARKER_placeholder

## Notes from this session

$SENTINEL

_auto placeholder prose_
EOF

# Normal curated handoff: prose under the header, no sentinel anywhere.
run_case curated preserve <<EOF
# handoff

## Notes from this session

Real curated notes. MARKER_curated lives here.
EOF

# VECTOR 1 — curated, but the snapshot embedded a commit whose subject is the
# sentinel. A whole-file grep matched it and clobbered the notes (was data loss).
run_case commitsubj preserve <<EOF
# handoff

### Recent commits

\`\`\`
abc1234 $SENTINEL
def5678 ordinary commit
\`\`\`

## Notes from this session

Curated. MARKER_commitsubj must persist.
EOF

# VECTOR 2 — curated notes that quote the sentinel on their own line in prose
# (not the first content line). A whole-file grep matched it (was data loss).
run_case quoted preserve <<EOF
# handoff

## Notes from this session

We fixed the bug where this line:
$SENTINEL
was matched anywhere. MARKER_quoted must persist.
EOF

# EDGE — header present but only blank lines after it (malformed). Preserve.
run_case headeronly preserve <<EOF
# handoff
MARKER_headeronly

## Notes from this session


EOF

# EDGE — no Notes header at all (malformed). Preserve.
run_case noheader preserve <<EOF
# handoff
MARKER_noheader
content without any notes header
EOF

finish
