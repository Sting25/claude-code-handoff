#!/usr/bin/env bash
# Local coverage for the install-drift CI gate (docs/install-split-v0.14-design.md
# §3): install.sh is a GENERATED artifact, concatenated from install.d/*.sh by
# tools/build-install.sh. This test rebuilds from the committed install.d/
# sources into a throwaway directory and diffs the result against the
# committed install.sh + install.sh.sha256, so a contributor who edited
# install.d/*.sh and forgot to rebuild finds out from `./tests/run.sh`
# locally, not from a red CI job on the PR.
#
# Rebuild happens in a copy, never in place against $REPO_ROOT — this test
# must never mutate the working tree's tracked install.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh — build drift (install.d/*.sh -> tools/build-install.sh -> install.sh)"

for f in install.sh install.sh.sha256 tools/build-install.sh; do
  if [[ ! -e "$REPO_ROOT/$f" ]]; then
    echo "  FAIL  missing $f — is this checkout mid-migration?"
    finish
    exit 1
  fi
done

WORKDIR="$(mktemp -d)"
cleanup_on_exit "$WORKDIR"

must cp -R "$REPO_ROOT/install.d" "$WORKDIR/install.d"
must cp -R "$REPO_ROOT/tools" "$WORKDIR/tools"

( cd "$WORKDIR" && bash tools/build-install.sh >/dev/null )
build_rc=$?
check "rebuild exits 0" 0 "$build_rc"

install_diff="no"
if ! diff -q "$REPO_ROOT/install.sh" "$WORKDIR/install.sh" >/dev/null 2>&1; then
  install_diff="yes"
fi
check "install.sh matches a fresh rebuild of install.d/*.sh" no "$install_diff"

sha_diff="no"
if ! diff -q "$REPO_ROOT/install.sh.sha256" "$WORKDIR/install.sh.sha256" >/dev/null 2>&1; then
  sha_diff="yes"
fi
check "install.sh.sha256 matches a fresh rebuild" no "$sha_diff"

if [[ "$install_diff" == yes ]]; then
  echo "  --- diff (committed vs. freshly rebuilt) ---"
  diff -u "$REPO_ROOT/install.sh" "$WORKDIR/install.sh" | head -40 | sed 's/^/    /'
  echo "  Run 'bash tools/build-install.sh' and commit the result."
fi

# Unregistered-module guard (v0.14.1): a slice on disk but missing from the
# build script's modules list would build green and never ship — the drift
# gate rebuilds with the same list, so only the build script itself can
# catch it. Negative control: plant a stray slice, expect the build to fail
# and name it.
printf '# stray slice — must fail the build\n' > "$WORKDIR/install.d/99-unregistered.sh"
stray_out="$(cd "$WORKDIR" && bash tools/build-install.sh 2>&1)"
stray_rc=$?
check "unregistered install.d module fails the build" yes "$([ "$stray_rc" -ne 0 ] && echo yes || echo no)"
stray_named="no"
case "$stray_out" in *99-unregistered.sh*) stray_named="yes" ;; esac
check "failure names the stray module" yes "$stray_named"
must rm "$WORKDIR/install.d/99-unregistered.sh"

finish
