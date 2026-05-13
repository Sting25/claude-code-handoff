---
name: handoff-more
description: Pull older handoffs from .claude/handoff_history/ into the current session's context. Use when the auto-loaded handoff_current.md is thin (placeholder Notes, mechanical session, missing context the user is referencing), when the user references work from "yesterday" or "the session before this one," or whenever the user explicitly invokes /handoff-more. Reads up to N older snapshots (default 5) so the assistant has continuity beyond the single most-recent handoff.
---

# /handoff-more — load older handoffs into context

The `SessionStart` hook auto-loads `handoff_current.md` (the most
recent handoff). This skill pulls in the older snapshots that
`write_handoff.sh` rotated into `<repo>/.claude/handoff_history/`
before each new write.

## When to invoke

- **User asks explicitly** (`/handoff-more`, "load more handoff
  context," "what did we do two sessions ago," etc.).
- **Auto-loaded handoff is thin.** If `handoff_current.md` was the
  result of an automatic `SessionEnd` write (no model in the loop to
  add curated Notes), the SessionStart hook already loaded the prior
  one as a fallback. But if the user is referencing decisions or work
  the assistant still can't account for, run this skill to pull
  further back.
- **Continuity gap.** User mentions a track, decision, or artifact you
  have no context on, and the current handoff doesn't reference it.

## Steps

1. List the history dir:
   ```bash
   ls -la <repo-root>/.claude/handoff_history/
   ```
   If the directory is missing or empty, say so and stop — there's
   nothing to load.

2. Read each retained snapshot, newest first. The default retention
   is 5 (configurable via `HANDOFF_HISTORY_KEEP` in the user's shell),
   so this is normally 1–5 files. Use the `Read` tool on each.

3. Acknowledge in one line that older handoffs are now in context
   (e.g. "Loaded 3 older handoffs from
   `.claude/handoff_history/` — `handoff_2026-05-12_140312.md`,
   `handoff_2026-05-11_180044.md`, `handoff_2026-05-10_223301.md` —
   into context."). Then continue answering whatever the user
   actually asked.

## What NOT to do

- Do not load history files that aren't in `handoff_history/`. The
  raw turn-by-turn dumps under `handoff_backups/` are a different
  artifact (verbose, per-turn, for forensic recovery) — use that
  directly if you need that level of detail, not this skill.
- Do not summarize the loaded handoffs back to the user as a wall of
  text. The point is to put the prose in context, not to recite it.
  One acknowledgement line is enough.
- Do not invoke proactively at every session start. The SessionStart
  hook already handles the "current handoff is thin → also include
  previous" fallback automatically. This skill is for when *that*
  fallback is also insufficient.
