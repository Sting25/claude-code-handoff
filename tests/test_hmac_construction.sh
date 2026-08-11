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

# `exit` is load-bearing: `finish` only PRINTS the tally, it does not end the
# file. Without it an openssl-less host falls straight through into the
# openssl-dependent body below and reports a spurious hard FAIL for a
# dependency it correctly detected as missing.
command -v openssl >/dev/null 2>&1 || { echo "  SKIP  openssl not available"; finish; exit 0; }

td="$(mktemp -d)"
# cleanup_on_exit, never a raw `trap … EXIT`: a raw trap REPLACES lib.sh's
# chained one, and the casualty is the secret jail lib.sh installs — which then
# strands a temp dir per run and re-opens the key-material leak the jail exists
# to prevent. lib.sh:26-27 warns against this in writing.
cleanup_on_exit "$td"

mk_doc() {  # <path> — doc with a decoy prose trailer line that must stay digested
  {
    echo "# fixture doc"
    echo "body line one"
    echo '<!-- HANDOFF_HMAC: prose decoy that must stay in the digest -->'
  } > "$1"
}

# "repeat64"/"repeat32": keys made of repeated identical 16-byte blocks are
# the regression class for the od `*` duplicate-line suppression — without
# `od -v` these collapsed onto one MAC and diverged from openssl -hmac.
for label_key in \
    "genshape:$(openssl rand -hex 32)" \
    "short:Jefe" \
    "long:$(openssl rand -hex 60)" \
    "repeat32:$(printf 'a%.0s' $(seq 1 32))" \
    "repeat64:$(printf 'a%.0s' $(seq 1 64))"; do
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

# Distinct repeated-block keys must NOT collapse onto the same MAC.
printf 'a%.0s' $(seq 1 32) > "$td/sk32"
printf 'a%.0s' $(seq 1 64) > "$td/sk64"
mk_doc "$td/dk"
mk32="$(HANDOFF_SECRET_FILE="$td/sk32" handoff_mac_compute "$td/dk")"
mk64="$(HANDOFF_SECRET_FILE="$td/sk64" handoff_mac_compute "$td/dk")"
distinct=no; [ "$mk32" != "$mk64" ] && distinct=yes
check "distinct repeated-block keys give distinct MACs" yes "$distinct"

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
# shellcheck disable=SC2016  # the pattern is a literal grep needle, not a
# shell expansion — it must stay single-quoted to match the source verbatim.
grep -v '^[[:space:]]*#' "$REPO_ROOT/bin/handoff_provenance.sh" \
  | grep -q -- '-hmac "\$(cat' && exposed=yes
check "no -hmac \"\$(cat …)\" argv shape in lib" no "$exposed"

# --- handoff_skeleton trailer strip: exact-64 AND awk-interval-free ---------
# The strip must (a) drop a well-formed 64-hex machine trailer so a stamp never
# covers itself, (b) KEEP a malformed (non-64) look-alike so it lands in the
# skeleton and changes the digest (fail-closed), and (c) use no awk ERE
# interval braces {64} — classic BSD one-true-awk (macOS <=10.14) treats those
# as literal characters, silently failing to strip a real trailer. (a)+(b)
# together pin the exact-64 semantics that the interval-free form preserves.
real64="$(printf '%064d' 0 | tr '0' 'a')"   # 64 lowercase-hex chars
sk="$td/skel_doc"
{
  printf '# doc\n'
  printf 'a body line\n'
  printf '<!-- HANDOFF_HMAC: %s -->\n' "$real64"
  printf '<!-- HANDOFF_SKEL_HMAC: %s -->\n' "$real64"
  printf '<!-- HANDOFF_HMAC: dead -->\n'   # malformed: MUST survive into skeleton
} > "$sk"
skel_out="$(handoff_skeleton "$sk")"
n_real="$(printf '%s\n' "$skel_out" | grep -c -- "HANDOFF_HMAC: $real64" || true)"
n_skel="$(printf '%s\n' "$skel_out" | grep -c -- "HANDOFF_SKEL_HMAC: $real64" || true)"
n_bad="$(printf '%s\n'  "$skel_out" | grep -c -- 'HANDOFF_HMAC: dead' || true)"
check "skeleton strips a well-formed HMAC trailer"      0 "$n_real"
check "skeleton strips a well-formed SKEL_HMAC trailer" 0 "$n_skel"
check "skeleton KEEPS a malformed (non-64) trailer"     1 "$n_bad"
# Static regression guard: the strip rules inside handoff_skeleton must not
# reintroduce an awk interval. Scope to the function body so the legitimate
# {64} intervals in grep -E / sed contexts elsewhere in the lib don't trip it.
skel_fn="$(sed -n '/^handoff_skeleton()/,/^}/p' "$REPO_ROOT/bin/handoff_provenance.sh")"
interval_in_skel=no
printf '%s\n' "$skel_fn" | grep -qE 'HANDOFF_(SKEL_)?HMAC: \[0-9a-f\]\{[0-9]+\}' && interval_in_skel=yes
check "handoff_skeleton uses no awk interval braces" no "$interval_in_skel"

finish
