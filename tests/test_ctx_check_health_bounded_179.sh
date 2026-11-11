#!/usr/bin/env bash
# Issue #179: health detector A (handoff_ctx_check.sh) must not scan the whole
# transcript once the Stop-hook ledger is absent. It only needs HEALTH_PROMPTS
# distinct completed turns, so the scan stops as soon as it has them.
#
# Deterministic proof, not a timing assertion: a `jq` shim tees what the
# grep|jq pipeline feeds into the real jq to a file. Once jq has its answer and
# exits, tee dies on SIGPIPE, so the byte count is how far the scan read.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CC="$REPO_ROOT/bin/handoff_ctx_check.sh"
command -v jq >/dev/null 2>&1 || { echo "health detector bounded scan"; skip "jq missing"; finish; exit; }
command -v perl >/dev/null 2>&1 || { echo "health detector bounded scan"; skip "perl missing"; finish; exit; }
echo "handoff_ctx_check.sh: health detector A bounded transcript scan (#179)"

repo="$(mk_repo)"; cleanup_on_exit "$repo"
sid="BOUNDED179"
tp="$repo/transcript.jsonl"
mkdir -p "$repo/.claude/handoff_backups" "$repo/shim"
# 3000 completed turns, ~4 KB each (~12 MB), all distinct message ids.
pad="$(head -c 4000 /dev/zero | tr '\0' x)"
awk -v sid="$sid" -v pad="$pad" 'BEGIN{for(i=0;i<3000;i++)
  printf "{\"type\":\"assistant\",\"sessionId\":\"%s\",\"message\":{\"id\":\"msg_%d\",\"role\":\"assistant\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"%s\"}]}}\n", sid, i, pad}' > "$tp"
real_jq="$(command -v jq)"
cat > "$repo/shim/jq" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -R "*|*" -nR "*|*" -Rn "*) tee "$repo/jq_stdin.bytes" | "$real_jq" "\$@" ;;
  *) exec "$real_jq" "\$@" ;;
esac
SH
chmod +x "$repo/shim/jq"
printf '2\n' > "$repo/.claude/handoff_backups/.ctx_prompts_$sid"

# CI runners start jobs with SIGPIPE ignored, and a shell cannot undo a
# signal ignored on entry. tee then gets EPIPE instead of dying, keeps copying
# the whole input to its file, and every run reads "unbounded". Under Claude
# Code, children get SIGPIPE at its default (measured 2026-11-11: a broken pipe
# kills grep with 141 in its Bash tool), so restore that here (perl can reset
# it; bash cannot) to measure the pipeline as it runs there.
out="$( cd "$repo" && PATH="$repo/shim:$PATH" perl -e '$SIG{PIPE}="DEFAULT"; exec @ARGV' bash "$CC" \
  <<<"{\"session_id\":\"$sid\",\"transcript_path\":\"$tp\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"continue\"}" 2>/dev/null )"
case "$out" in *"does not appear to be running"*) w=yes ;; *) w=no ;; esac
check "still warns when the Stop hook ledger is absent" yes "$w"

total="$(wc -c < "$tp")"; read_bytes="$(wc -c < "$repo/jq_stdin.bytes" 2>/dev/null || echo 0)"
total="${total//[[:space:]]/}"; read_bytes="${read_bytes//[[:space:]]/}"
echo "  transcript=${total}B scanned=${read_bytes}B"
# Bound: well under a tenth of the transcript (pipe buffers add a few hundred KB).
if (( read_bytes > 0 && read_bytes * 10 < total )); then b=bounded; else b=unbounded; fi
check "scan stops early instead of reading the whole transcript" bounded "$b"
finish
