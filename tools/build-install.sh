#!/usr/bin/env bash
# tools/build-install.sh — concatenates install.d/*.sh into the committed
# install.sh artifact at the repo root.
#
# Run this after editing any install.d/*.sh module, then commit the
# regenerated install.sh alongside your change. CI's install-drift job
# rebuilds into a temp file and diffs it against the committed install.sh —
# a stale artifact fails that gate.
#
# Explicit ordered array of module filenames below — NOT a glob over
# install.d/*.sh — so a stray or misnamed file dropped into install.d/
# can't silently get spliced into a security-relevant script. See
# docs/install-split-v0.14-design.md §2 for the full rationale.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
install_d="$repo_root/install.d"
out="$repo_root/install.sh"
sha_out="$repo_root/install.sh.sha256"

# Contiguous slices of today's install.sh, in file order — bash's
# define-before-call requirement is trivially satisfied because nothing
# executes until 40-main.sh dispatches at the bottom.
modules=(
  00-preamble.sh
  10-symlinks.sh
  20-settings-patch.sh
  30-settings-unpatch-doctor.sh
  40-main.sh
)

module_paths=()
for m in "${modules[@]}"; do
  f="$install_d/$m"
  if [[ ! -f "$f" ]]; then
    echo "build-install: missing module $f" >&2
    exit 1
  fi
  module_paths+=("$f")
done

# Hash of stdin, portable across macOS/BSD (shasum) and Linux (sha256sum) —
# no bash-4-only features, no assumption about which one is on PATH.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    echo "build-install: neither shasum nor sha256sum found on PATH" >&2
    exit 1
  fi
}

# SOURCE-SHA256 covers the concatenated install.d sources plus this build
# script itself, in module order — provenance/human-visible only. It is
# never the gate itself (that's the full rebuild-and-diff in CI); it just
# lets a human eyeballing install.sh confirm which sources produced it.
source_sha="$(cat "${module_paths[@]}" "$script_dir/build-install.sh" | sha256_of)"

tmp="$(mktemp "${TMPDIR:-/tmp}/install.sh.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
  printf '#!/usr/bin/env bash\n'
  cat <<'BANNER'
# GENERATED FILE — do not edit directly.
#
# This is the concatenation of install.d/*.sh, produced by
# tools/build-install.sh. To change installer behavior, edit the relevant
# module under install.d/, then regenerate with:
#
#   bash tools/build-install.sh
#
# CI's install-drift job rebuilds this file into a temp path and diffs it
# against the committed copy below; a stale install.sh fails that gate.
BANNER
  printf '# SOURCE-SHA256: %s\n' "$source_sha"
  cat "${module_paths[@]}"
} > "$tmp"

chmod +x "$tmp"
mv "$tmp" "$out"
trap - EXIT

# Companion checksum for a future curl consumer: fetch install.sh.sha256
# from a tagged release alongside install.sh and verify with
# `shasum -a 256 -c install.sh.sha256` (or `sha256sum -c`) before piping.
out_sha="$(sha256_of < "$out")"
printf '%s  install.sh\n' "$out_sha" > "$sha_out"

echo "build-install: wrote $out and $sha_out (SOURCE-SHA256 $source_sha)"
