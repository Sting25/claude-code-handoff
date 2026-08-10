---
name: handoff-recover
description: Compose a retroactive curated handoff when the previous session ended without invoking /handoff. Requires the scripts/hooks installed by this repo's ./install.sh — not a prompt-only skill. Triggered by the SessionStart "ACTION: RUN /handoff-recover" banner (emitted when handoff_current.md still has the placeholder Notes block) or by explicit /handoff-recover. Reads the previous session's raw per-turn dump under .claude/handoff_backups/ and the most recent curated handoff under .claude/handoff_history/, then writes a retroactive Notes block into handoff_current.md so the recovered context persists.
---

# /handoff-recover — retroactive handoff composition

> **Prerequisite:** this skill leans on scripts and hooks from
> https://github.com/Sting25/claude-code-handoff — the raw dumps it
> recovers from are written by the Stop hook, and it runs
> `handoff_recover_tail.sh` / `write_handoff.sh` from `~/.claude/bin/`.
> None of that ships with this file alone; run `./install.sh` from that
> repo once per machine first.

The previous session ended without running `/handoff` — crashed,
killed, terminal closed, or just never invoked. `SessionEnd` wrote a
safety-net snapshot, so `handoff_current.md` has git state but no
curated Notes. The SessionStart hook detected this and printed an
ACTION banner telling you to invoke this skill.

Note: since the `PreCompact` hook joined the safety net, a
placeholder can also be written MID-session (an uncurated session
that hit auto or manual compaction), not only at session end — so
this banner can appear even though the "previous session" is the
same still-running conversation, freshly compacted. The recovery
flow is identical: the raw dump covers the pre-compact turns that
compaction summarized away.

This skill reconstructs what the previous session would have written
into Notes if `/handoff` had run, using the raw per-turn dump and the
prior history snapshot. The reconstruction is best-effort — it will
miss things only the live model knew — but it puts a working baseline
into the current session's context and persists it back into
`handoff_current.md` so it's not lost again.

## When to invoke

- **Auto-triggered by the SessionStart banner.** When the hook output
  contains `ACTION: RUN /handoff-recover`, invoke this skill as the
  first action of the session, before doing any new work.
- **User invokes `/handoff-recover` explicitly.** Same flow.
- **You notice the placeholder yourself.** If `handoff_current.md`
  contains the `<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces
  this block -->` sentinel (or the legacy "The /handoff skill should
  append decisions" line) but the hook didn't flag it (e.g.
  `HANDOFF_SS_DISABLE_RECOVER` was set), invoke anyway — the recovery
  is still useful.

## Steps

**Preflight — verify the toolchain is installed.** Before step 1:

```bash
test -f ~/.claude/bin/write_handoff.sh || echo "MISSING: handoff scripts not installed"
```

If it prints MISSING, **stop here** — tell the user to clone
https://github.com/Sting25/claude-code-handoff and run `./install.sh`,
then re-invoke `/handoff-recover`. Do NOT reconstruct the scripts'
behavior by hand: a recovery composed without the real
`write_handoff.sh --restamp` / `handoff_recover_tail.sh` leaves the
handoff unsigned and can silently miss the lost session's final turns.

1. **Identify the previous session's raw dump.** The `Stop` hook
   appends every turn to `<repo>/.claude/handoff_backups/handoff_raw_<session_id>.md`.
   Strategies to find the previous session's file, in order of
   preference:

   a. **Session registry (if present):** check `~/.claude/session_registry/`
      for an entry whose `project` matches this repo and whose `status`
      is `ended_clean` or `crashed`, with the most recent
      `ended_at_utc` / `crash_detected_at_utc` / `heartbeat_utc`. That
      entry's `session_id` is the previous session — look for the
      matching `handoff_raw_<session_id>.md`. The registry is
      forge-control-specific (not part of this repo's install); skip
      this step silently if `~/.claude/session_registry/` doesn't exist.

   b. **mtime + size heuristic:** list raw dumps:

      ```bash
      ls -lt <repo>/.claude/handoff_backups/handoff_raw_*.md
      ```

      The current session's dump is the one being written *right now*
      and started growing at this session's SessionStart. The previous
      session's dump is one of: the most-recent one (if the current
      session hasn't had any turns yet — unlikely by the time you
      invoke this skill), or the second-most-recent one (typical
      case). Look at file sizes: the previous dump is usually
      substantial; the current one is small (just a few turns into
      the recovery).

   c. **Last resort:** if you cannot disambiguate, ask the user
      "previous session's id?" — they often have the terminal
      transcript or the registry handy.

   If `handoff_backups/` is empty or doesn't exist, skip to step 4
   (no raw dump available) and note this in the recovered Notes.

2. **Read the raw dump.** Use `Read` on the previous session's
   `handoff_raw_<session_id>.md`. It is verbose (per-turn user
   messages + assistant text + tool calls). Extract the content that
   matters for a Notes block: decisions made, work product produced,
   in-flight tracks, open questions, "next session" cautions. Skip
   transient tool output and routine acknowledgements.

   **The raw dump can be missing the final turn(s).** It is built
   incrementally by the `Stop` hook, which fires *after* each assistant
   turn. A session killed before its final `Stop` ran — OOM, SIGKILL,
   power loss, terminal closed mid-turn — never folds its last exchange
   into the dump, yet Claude Code already wrote it to the transcript
   JSONL. That last turn is often the most valuable thing to recover
   ("what I was about to do next"). The dump alone silently loses it.

   Run the recovery helper to surface anything the dump missed:

   ```bash
   bash ~/.claude/bin/handoff_recover_tail.sh <previous_session_id>
   ```

   It compares the dump's cursor against the transcript JSONL and prints
   any turns past the cursor (formatted like the dump). Empty output
   means the dump is already complete — the normal clean-`/handoff`
   case; nothing to do. Non-empty output is the un-captured tail: read
   it and fold anything load-bearing into the recovered Notes below,
   same as content from the dump itself. If the helper isn't installed
   (older install) or prints a "no transcript" notice, skip it — the
   dump is your only source and you proceed with what it has.

3. **Read the most recent curated handoff from history.** The
   SessionStart hook already cat'd this above if one existed, so
   it may already be in your context — confirm by checking for a
   "Also loaded: previous handoff" block in the auto-loaded text.
   If not in context, read it manually:

   ```bash
   ls -1 <repo>/.claude/handoff_history/handoff_*.md | sort -r | head -1
   ```

   Use it as scaffolding context — it tells you what the session
   *before* the lost one had been working on, which often clarifies
   what the lost session's session-of-its-own-day was about.

4. **(Optional) Check the session registry for crash annotation.**
   If `~/.claude/session_registry/<previous_session_id>.json` exists,
   read it. Useful fields: `status` (`ended_clean` vs `crashed`),
   `crash_detected_at_utc`, `heartbeat_utc`, `turn_count`. A crashed
   session may have ended mid-track, which is worth noting in the
   recovered Notes ("session ended unplanned at turn N").

5. **Compose retroactive Notes.** Quality bar matches the `/handoff`
   skill — see `skills/handoff/SKILL.md` for the structure. In order
   of importance:

   - **Work product produced this session.** Plans, specs, designs,
     approved approaches. Paste or faithfully summarize from the raw
     dump.
   - **Decisions made that aren't in any commit.** "User greenlit X
     but we decided to spec it before coding," etc.
   - **In-flight tracks the next session should pick up.**
   - **Open questions the user hasn't answered yet.**
   - **"Don't do Y" / "Be careful about Z" cautions.**
   - **Literal commands to run first to get oriented.**

   Lead the composed Notes with a short header noting this is
   retroactive — e.g. "_Reconstructed by /handoff-recover from
   handoff_raw_<session_id>.md (and history fallback). Some intent
   may be missing; the live model didn't curate this._"

6. **Edit `<repo>/.claude/handoff_current.md` to replace the
   placeholder block.** Same Edit rules as `/handoff`: delete the
   `<!-- HANDOFF_PLACEHOLDER: ... -->` sentinel comment AND the
   italic instructions immediately below it, then insert the
   retroactive Notes. Removing the sentinel is what tells the
   SessionEnd safety-net that this file now has real content.

7. **Re-sign the edited handoff.** Your Edit invalidated the HMAC
   trailer `write_handoff.sh` wrote on the file, which would silently
   demote the pinned/rules blocks from binding to reference data for
   every subsequent session. Re-stamp it:
   ```bash
   bash ~/.claude/bin/write_handoff.sh --restamp
   ```
   Best-effort — if it warns (no openssl, older install), continue; the
   handoff still works, the rules just load as data. Re-run it after any
   later re-edit (step 9).

8. **Surface the recovered Notes in chat.** Print the composed Notes
   directly so the current session has it in working memory, not
   just on disk. One short header line ("Recovered Notes from
   session <id>:"), then the Notes content. Keep it readable —
   the user should be able to scan it.

9. **Pause and confirm with the user.** Before doing new work, ask:

   > Recovered Notes above. Does this match your recollection of
   > what the previous session did, or should I adjust before we
   > continue?

   Wait for the user. If they correct or add, update the in-chat
   summary AND re-edit `handoff_current.md` with the corrections
   (then re-run `write_handoff.sh --restamp`, per step 7).

10. **Reconcile the working tree before resuming — don't redo done
   work.** A crashed session's in-progress edits are usually still in
   the working tree, uncommitted; `git status` and `git diff` are the
   ground truth for what it already applied. Before resuming:

   - **Treat already-applied edits as done — never re-apply them.**
     If the recovered Notes say "edited X to do Y" and `git diff`
     already shows Y in X, that step is complete. Re-running the edit
     duplicates it or corrupts the file. This is the single most
     common recovery mistake: a fresh session, blind to what the dead
     one did, redoes it.
   - **Verify scope.** The diff should touch only the files the
     recovered work intended — flag anything extra. Don't be fooled
     by noise: line-ending / `.gitattributes` churn appears as
     modified files with zero changed lines.
   - **Baseline the tests, then read the result honestly.** If the
     repo has a suite, run it *before* any new edits. A failure on a
     file that is byte-identical to `HEAD` is environmental (OS,
     shell version, a missing tool) — not a regression the recovered
     work caused. Prove it (`git diff --stat` the file) instead of
     assuming; environmental red must not scare you off good work,
     and must not mask a real one.

11. **Then continue with the session's actual work.** With the
    retroactive Notes in context and the tree reconciled, you have a
    working baseline.

## What gets persisted to disk

The recovered Notes go into `handoff_current.md`'s Notes block,
replacing the placeholder. When the current session later invokes
`/handoff`, that file rotates into `handoff_history/` with the
retroactive Notes intact, so future sessions can see the recovery.

The git-state snapshot above the Notes section is from the current
session's SessionStart (the `SessionEnd` auto-write), not the
previous session. That's a known caveat: the snapshot's HEAD/commits
reflect "state at the end of the lost session" (which is what got
captured), but the timestamp is the safety-net's write time, not
the lost session's actual end. Don't try to backdate it — the Notes
prose makes the recovery context clear without rewriting metadata.

## Raw dump not available

If `handoff_backups/handoff_raw_<previous_session_id>.md` doesn't
exist (Stop hook wasn't installed during the lost session, or the
file was pruned, or this repo predates the hook), do what you can:

1. Use the most recent history handoff as the primary reference.
2. Use the session registry's crash annotation (if any) to note the
   unplanned end.
3. Compose a *minimal* retroactive Notes block that documents the
   gap explicitly: "Previous session's raw dump unavailable. The
   most recent curated handoff (handoff_<timestamp>.md) covers
   session N-2; session N-1's intent is lost. Resume from
   handoff_<timestamp>.md."
4. Surface this clearly to the user — they may have additional
   recall to fill in.

A missing raw dump is not a reason to skip the skill. A documented
gap is better than a silent gap.

## What NOT to do

- **Do not invent decisions or work products that aren't in the raw
  dump or history.** The raw dump is the ground truth. If something
  is unclear, mark it `(uncertain)` in the recovered Notes rather
  than guessing.
- **Do not pick the current session's raw dump as "previous."** The
  current session's dump is being written right now and contains the
  recovery work itself — including it would create a circular
  recovery. Use the mtime/size heuristic or the session registry to
  disambiguate.
- **Do not re-apply work the crashed session already did.** Its
  uncommitted edits live in the working tree; `git diff` is the
  source of truth for what's done. Blindly redoing a step from the
  recovered Notes duplicates edits or corrupts files (see step 10).
- **Do not modify `handoff_history/` files.** Those are historical
  snapshots from prior sessions; treat them as read-only.
- **Do not skip the user confirmation step.** Retroactive composition
  is high-stakes (it shapes the rest of the session) and the user is
  the only one who knows whether the reconstruction is accurate.
- **Do not run /handoff immediately after /handoff-recover.** The
  recovered Notes are now persisted; running /handoff right away
  would rotate them into history before the current session has
  done any meaningful work, which is wasteful. /handoff at the next
  real boundary picks up the recovered Notes naturally.
