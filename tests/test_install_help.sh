#!/usr/bin/env bash
# Regression guard: `install.sh --help` must print complete usage text and
# exit 0, both run normally AND when the script arrives on stdin (the
# `curl ... | bash -s -- --help` real-world shape).
#
# Two bugs, one fix. (1) The usage block was originally read via a hardcoded
# `sed -n '2,28p' "${BASH_SOURCE[0]}"` line range, which truncated --uninstall
# and --help once the header grew past line 28. (2) The self-read approach is
# fundamentally broken under `curl | bash -s -- --help`: BASH_SOURCE[0] is
# "bash", not a path to the script, so the self-read produced nothing. Both
# are fixed the same way: usage text now lives in a usage() heredoc, parsed
# out of the script's own source at parse time — no path or working stdin
# needed, and no line range to fall out of sync with the content.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --help (normal invocation)"

out="$(bash "$REPO_ROOT/install.sh" --help)"
rc=$?

check "exit code 0" 0 "$rc"

usage_present="no"
[[ "$out" == *"Usage:"* ]] && usage_present="yes"
check "usage text present" yes "$usage_present"

uninstall_present="no"
[[ "$out" == *"--uninstall"* ]] && uninstall_present="yes"
check "--uninstall in output" yes "$uninstall_present"

help_present="no"
[[ "$out" == *"--help"* ]] && help_present="yes"
check "--help in output" yes "$help_present"

echo
echo "install.sh --help (piped: script on stdin, as with curl | bash -s -- --help)"

piped_out="$(bash -s -- --help < "$REPO_ROOT/install.sh")"
piped_rc=$?

check "piped exit code 0" 0 "$piped_rc"

piped_usage_present="no"
[[ "$piped_out" == *"Usage:"* ]] && piped_usage_present="yes"
check "piped usage text present" yes "$piped_usage_present"

piped_uninstall_present="no"
[[ "$piped_out" == *"--uninstall"* ]] && piped_uninstall_present="yes"
check "piped --uninstall in output" yes "$piped_uninstall_present"

check "piped output matches normal output" "$out" "$piped_out"

finish
