#!/usr/bin/env bash
# Regression guard for install.sh --help completeness: the usage block was
# truncated at line 28, cutting off --uninstall and --help. The sed range was
# hardcoded; this test asserts the output includes both missing options and that
# the fix (printing until the first non-# line) is robust.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh --help (usage block includes --uninstall and --help)"

out="$(bash "$REPO_ROOT/install.sh" --help)"
rc=$?

check "exit code 0" 0 "$rc"

uninstall_present="no"
[[ "$out" == *"--uninstall"* ]] && uninstall_present="yes"
check "--uninstall in output" yes "$uninstall_present"

help_present="no"
[[ "$out" == *"--help"* ]] && help_present="yes"
check "--help in output" yes "$help_present"

finish
