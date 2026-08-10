#!/usr/bin/env bash
# HMAC construction (ps-argv hardening): handoff_mac_compute builds
# HMAC-SHA256 from the two-pass definition so the secret never appears in
# any process argument list. These checks pin the two properties that make
# that safe to ship:
#   1. EQUIVALENCE — digests are bit-identical to the previous
#      `openssl dgst -hmac "$(cat secret)"` form for the same key/doc,
#      across the generated-secret shape (64 ASCII hex = one SHA-256
#      block), a short key, and a >64-byte key (RFC 2104 hash-then-pad
#      branch). Older signed docs must keep verifying.
#   2. NO ARGV EXPOSURE — the lib no longer contains the `-hmac "$(cat`
#      invocation shape (source-level pin; a ps race is untestable here).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "hmac construction (argv hardening + back-compat)"

# shellcheck source=bin/handoff_provenance.sh
. "$REPO_ROOT/bin/handoff_provenance.sh"

command -v openssl >/dev/null 2>&1 || { echo "  SKIP  openssl not available"; finish; }

td="$(mktemp -d)"
trap 'rm -r "$td" 2>/dev/null' EXIT

mk_doc() {  # <path> — doc with a decoy prose trailer line that must stay digested
  {
    echo "# fixture doc"
    echo "body line one"
    echo '<!-- HANDOFF_HMAC: prose decoy that must stay in the digest -->'
  } > "$1"
}

for label_key in "genshape:$(openssl rand -hex 32)" "short:Jefe" "long:$(openssl rand -hex 60)"; do
  label="${label_key%%:*}"
  key="${label_key#*:}"
  printf '%s' "$key" > "$td/secret_$label"
  mk_doc "$td/doc_$label"
  new="$(HANDOFF_SECRET_FILE="$td/secret_$label" handoff_mac_compute "$td/doc_$label" || echo COMPUTE_FAILED)"
  ref="$(LC_ALL=C grep -Ev '^<!-- HANDOFF_HMAC: [0-9a-f]{64} -->[[:space:]]*$' "$td/doc_$label" \
    | openssl dgst -sha256 -hmac "$key" | awk '{print $NF}')"
  same=no; [ "$new" = "$ref" ] && same=yes
  check "matches legacy -hmac digest ($label key)" yes "$same"
done

# Trailer stripping still scoped to well-formed trailers only: a real
# trailer line is excluded from the digest, the prose decoy is not.
printf '%s' "$(openssl rand -hex 32)" > "$td/secret_strip"
mk_doc "$td/doc_strip"
mac1="$(HANDOFF_SECRET_FILE="$td/secret_strip" handoff_mac_compute "$td/doc_strip")"
printf '<!-- HANDOFF_HMAC: %s -->\n' "$mac1" >> "$td/doc_strip"
mac2="$(HANDOFF_SECRET_FILE="$td/secret_strip" handoff_mac_compute "$td/doc_strip")"
same=no; [ "$mac1" = "$mac2" ] && same=yes
check "well-formed trailer excluded from own digest" yes "$same"

# Source-level pin: the argv-exposing invocation shape must not return.
# Comment lines are excluded — the lib's rationale comment quotes the old
# form on purpose; only executable code counts as exposure.
exposed=no
grep -v '^[[:space:]]*#' "$REPO_ROOT/bin/handoff_provenance.sh" \
  | grep -q -- '-hmac "\$(cat' && exposed=yes
check "no -hmac \"\$(cat …)\" argv shape in lib" no "$exposed"

finish
