---
name: handoff
description: Snapshot session state to .claude/handoff_current.md and tell the user (loudly, with -*-*- borders) to start a new session. Requires the scripts/hooks installed by this repo's ./install.sh — not a prompt-only skill. Use at clean boundaries (commit lands, track wraps), when the user signals context pressure ("getting long", "meter is full"), or whenever the user invokes /handoff. Blocks until the user actually starts a new session — do not start new work after invoking.
---

# /handoff — write a session handoff

> **Prerequisite:** this skill drives scripts and hooks from
> https://github.com/Sting25/claude-code-handoff — `write_handoff.sh`
> under `~/.claude/bin/` (script install) or the plugin's `bin/`
> (plugin install) and the Stop / SessionStart / SessionEnd hooks
> in `~/.claude/settings.json` are NOT part of this file. Run
> `./install.sh` from that repo (or install the plugin) once per
> machine before first use.

Used at clean boundaries (after a commit, when a major track wraps),
when the user signals context pressure, or whenever the user invokes
`/handoff`. Hands the next session a complete state snapshot so
nothing gets lost across the restart boundary.

## What this skill does

1. **Snapshot state** — runs `write_handoff.sh` (resolved from
   `~/.claude/bin/` on a script install or the plugin's `bin/` on a
   plugin install — see Steps below), which captures:
   - HEAD, branch, recent commits, working-tree state for the current repo
   - Same for an optional sibling "substrate" repo (configured via
     `HANDOFF_SUBSTRATE_NAME`, e.g. a shared decisions / RFCs repo)
   - In-flight (untracked or modified) `.md` docs under the configured
     directories (default: `docs/`; configurable via `HANDOFF_INFLIGHT_DIRS`)
   - The "verify state matches reality" command block
   - Before overwriting `handoff_current.md`, the script rotates the
     previous one into `.claude/handoff_history/` and prunes to the
     last `HANDOFF_HISTORY_KEEP` (default 5). The next session's
     SessionStart hook auto-includes the most recent history entry
     if the current handoff has no curated Notes; `/handoff-more` lets
     a future session pull more of the history into context on demand.
   (Auto-compaction is also checkpointed: a `PreCompact` hook fires
   the same `--if-curated` safety net, so an uncurated session gets a
   mechanical snapshot before compaction destroys the conversation.
   That snapshot is a placeholder — running `/handoff` to curate is
   still the only path that captures intent.)
2. **Replace the placeholder block with session-specific intent** — the script's snapshot is git-state-only; the conversation knows things git doesn't (decisions made, in-flight ASKs, open questions, "next session should start with X" notes). The auto-generated file contains a `## Notes from this session` section with a placeholder block bracketed by a `<!-- HANDOFF_PLACEHOLDER: ... -->` sentinel comment. **Replace the entire placeholder block (sentinel + italic prose) with curated Notes using Edit** — do not just append below the placeholder, because the SessionEnd safety-net detects "no curation happened" by the presence of that sentinel. Removing the sentinel is what tells the SessionEnd hook to stand down and preserve your work. Explicit fences for the next session go in the marker-wrapped `## Rules` section, NOT in Notes (see Steps). After editing, re-sign with `write_handoff.sh --restamp` so the rules load as binding, not data.
3. **Confirm the raw-dump backup exists** — the `Stop` hook (`handoff_turn_append.sh`) has been appending turn-by-turn to `.claude/handoff_backups/handoff_raw_<session_id>.md` throughout the session, so by the time `/handoff` runs the backup is already there. Verify it: `ls -la .claude/handoff_backups/`. If the file is missing (hook not installed, or session started before the hook landed), fall back to writing a one-shot dump per the "Raw dump fallback" section below. The hook prunes to 3 newest automatically — you do not need to.
4. **Print a loud, unmissable banner** — the ASK must be impossible to miss (the user specifically asked for this; do not soften).
5. **Stop**. Do not start new work after the banner. The session is over.

## Steps

1. Resolve where the scripts live, then run via Bash. Script installs
   put them under `~/.claude/bin/`; plugin installs put them under the
   plugin's `bin/`, whose location `CLAUDE_PLUGIN_ROOT` gives when set
   — but that env var's visibility to skill-driven Bash calls is
   unverified, so fall back to the legacy path and then a cache-glob
   before giving up:
   ```bash
   hb=""
   if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/write_handoff.sh" ]; then
     hb="${CLAUDE_PLUGIN_ROOT}/bin"
   elif [ -f "$HOME/.claude/bin/write_handoff.sh" ]; then
     hb="$HOME/.claude/bin"
   else
     for d in "$HOME"/.claude/plugins/cache/*/claude-code-handoff/*/bin; do
       [ -f "$d/write_handoff.sh" ] && hb="$d"
     done
   fi
   # env var wins when set (running from that plugin), legacy bin next (existing
   # installs), cache glob last (plugin installed but env var not visible to
   # skill Bash); the loop's last match takes the lexically-highest version dir.
   [ -n "$hb" ] || echo "MISSING: handoff scripts not installed (neither ~/.claude/bin nor a plugin install found)"
   ```
   Then, if it did not print MISSING, run it:
   ```bash
   bash "$hb/write_handoff.sh"
   ```
   If it prints MISSING, **stop here** — tell the user to clone
   https://github.com/Sting25/claude-code-handoff and run `./install.sh`
   (or install the plugin), then re-invoke `/handoff`. Do NOT attempt to
   reconstruct the script's behavior by hand; the hooks it pairs with
   won't be installed either, and a hand-rolled snapshot breaks the
   HMAC/rotation contract.
   Otherwise, the script outputs the absolute path of the written handoff
   (`<repo-root>/.claude/handoff_current.md`).

   Keep the resolution/check and the run as two separate commands.
   Chaining them as `<resolve $hb> && bash "$hb/write_handoff.sh" ||
   echo MISSING` makes **any** non-zero exit from the script print
   MISSING — including real installed-but-blocked conditions like a
   symlinked `.claude` — which would send the user off to re-install an
   already-correct install while the actual cause goes unaddressed.
   Resolving `$hb` and checking it (the shape `/handoff-more` and
   `/handoff-recover` use) tests installation and nothing else.

2. Read the file you just wrote. Then Edit it to **replace the
   placeholder block** under `## Notes from this session` with curated
   prose. The placeholder block is the sentinel comment
   (`<!-- HANDOFF_PLACEHOLDER: keep until /handoff replaces this block -->`)
   plus the italic instructions immediately below it; both must be
   removed and replaced with your Notes content. The SessionEnd safety-
   net stands down only when that sentinel is gone, so leaving it in
   place (even with Notes added below) means the safety-net write
   could later clobber your work. Capture in your Notes, in order of
   importance:
   - **Work product produced this session.** If a plan was approved,
     a spec was drafted, a design was decided, or any artifact beyond
     commits was produced — paste or faithfully summarize it here.
     The next session should not have to read chat history to find
     what was decided. This is the load-bearing item.
   - Decisions made this session that aren't in any commit (e.g. "user
     greenlit X but we decided to spec it before coding").
   - In-flight tracks the next session should pick up (e.g. "drafted
     plan at X; awaiting greenlight").
   - Open questions the user hasn't answered yet.
   - "Don't do Y" / "Be careful about Z" cautions specific to this
     session.
   - The literal commands the next session should run first to get
     oriented (often the verify-state block from the snapshot, plus any
     project-specific reads).
   Skip items that are already in the auto-snapshot (HEAD, dirty files,
   commit list — those live above the `Notes` section).

   **Garbage-collect what you inherited.** Before writing, look at the
   cautions and lessons the handoff you *started* this session with
   carried forward (the auto-loaded `handoff_current.md`). Don't copy
   them forward by reflex — decide each one's fate:
   - **Settled** — now fixed in code, or written into a spec / `AGENTS.md`
     / memory / the system log → move it to that permanent home and
     **drop it from the Notes.** A gotcha that's been codified has
     graduated; it no longer belongs in the handoff.
   - **Still live** — could still cause a wrong move next session →
     carry it forward.
   - **Stale** — no longer applies → drop it.

   The handoff is a working set, not an archive: it should **trend
   smaller** as lessons graduate into permanent homes, not grow every
   session. If you carried everything forward and dropped nothing, say
   so and why — silent monotonic growth is the signal the loop has
   stopped maintaining itself.

   **Fences go in the `## Rules` block, not in Notes.** The doc contains
   a `## Rules (fences — carried into the next session)` section wrapped
   in `<!-- HANDOFF_BIND_BEGIN/END -->` markers, above the Notes section.
   Scope fences the next session must honor ("do NOT begin X without a
   fresh decision", "never force-push to main") belong INSIDE those
   markers — replace the `HANDOFF_RULES_PLACEHOLDER` comment with them,
   or leave it in place if there are none. Only marker-wrapped content
   ever loads with binding framing in the next session (and only when
   the doc's provenance verifies); anything you write in Notes loads as
   reference data, so a fence left in Notes is just a suggestion. Do not
   move the markers, and do not put narrative inside them — every line
   there will be treated as a standing rule.

   Writing fences *inside* the existing Rules markers is the sanctioned
   edit — that region is the one place model-authored rules are meant to
   bind. But **do not add, move, or duplicate the markers themselves, or
   the headings, or reorder sections.** The re-sign step (Step 3) records
   the document's structure and refuses to vouch for a document whose
   marker/heading/section shape changed outside the Notes and Rules bodies;
   if that happens your rules silently drop to reference data.

   **Write state claims as checks, not verdicts.** When a Note asserts
   something the next session will rely on ("the migration is done", "X
   is wired up"), phrase it as the check that *proves* it, not the
   conclusion — e.g. "migration done iff `SELECT schema_version` reads 7
   and `./smoke.sh` exits 0", not "migration done". The next session
   re-derives the claim instead of trusting stale prose. Anything git
   already proves (HEAD, branch, pushed commits) lives in the snapshot
   above — don't restate it as a verdict here.

3. **Re-sign the edited doc.** Your Edit invalidated the two stamp
   trailers `write_handoff.sh` put on the file at write time (the
   `<!-- HANDOFF_HMAC: … -->` and `<!-- HANDOFF_SKEL_HMAC: … -->` lines —
   leave both alone; they get replaced). Run:
   ```bash
   bash "$hb/write_handoff.sh" --restamp
   ```
   This re-signs `handoff_current.md` in place with the per-machine
   secret so the next session loads the Rules/pinned blocks as binding.
   Best-effort: if it warns (no openssl, older install), continue — the
   handoff still works, the rules just load as reference data.

   **What re-signing will and won't vouch for.** `--restamp` only re-signs
   as binding when the document's *structure* is unchanged since it was
   written — the same structure it recorded in the `HANDOFF_SKEL_HMAC`
   stamp. You are meant to edit exactly two zones: the **Notes body** and
   the content **inside the writer's own `## Rules` region** (replacing the
   `HANDOFF_RULES_PLACEHOLDER` comment with fences). Editing only those is
   what a normal curation does, and it re-signs cleanly. If instead a
   `HANDOFF_BIND_BEGIN`/`END` marker, a section heading, or a whole section
   has been added, moved, or deleted *outside* those zones, `--restamp`
   refuses and leaves the file byte-identical (its rules then load as
   reference data). If you see that refusal, do **not** try to hand-fix the
   markers — re-run `write_handoff.sh` to regenerate a fresh, structurally-
   stamped document and curate that.

4. **Verify the raw dump.** The `Stop` hook has been appending to
   `<repo-root>/.claude/handoff_backups/handoff_raw_<session_id>.md`
   throughout the session. Run `ls -la <repo-root>/.claude/handoff_backups/`
   and confirm the current session's file is there. The hook also handles
   pruning (3 newest) — no action needed from you in the normal path.
   If the file is **missing**, fall through to "Raw dump fallback" below.

5. Determine how this session is running, so the banner tells the user
   an action they can actually take (the CLI's "Ctrl+D, then `claude`"
   is meaningless in the desktop app, and vice versa):

   ```bash
   printf '%s\n' "${CLAUDE_CODE_ENTRYPOINT:-unknown}"
   ```

   Then print the banner verbatim. Do NOT skip, soften, or shrink it.
   Use the exact format below — the borders are deliberate width — and
   substitute the `action:` block for the detected mode:

   - Output `cli` → use the **terminal** action block.
   - Any other value (or empty/unknown, or the check failed) → print
     **both** action blocks, desktop first. Wrong-mode advice is the
     failure to avoid; two extra lines is the acceptable cost.

   ```
   -*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-
                    ASK: START A NEW SESSION NOW
   -*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-

   handoff written to: <path the script printed>
   raw dump written to: <path of the raw-dump file>

   action:  [terminal] hit Ctrl+D to exit, then run `claude` to start
            a fresh session. Do NOT use `claude --continue` — that
            resumes this same saturated context, which defeats the
            purpose of the handoff.

   action:  [desktop app] start a New Session (new-session button or
            Cmd/Ctrl+N) in this same project folder. Do NOT continue
            or resume this conversation — that reopens the saturated
            context the handoff exists to retire.

   (Either way, the SessionStart hook in ~/.claude/settings.json
   auto-loads the handoff into the fresh session.)

   -*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-
   ```

6. Stop. Do NOT continue working after printing the banner. No "while
   we're here" cleanup, no "one more thing." The whole point of the
   handoff is to land at a clean boundary so the next session starts
   from a known state.

## Raw dump

The raw dump is the safety net for when curated `Notes from this
session` turns out thin. It exists because the curation step has a
known failure mode — bias toward "nothing worth capturing" — and the
recovery cost is high (the next session has no way to read chat
history). The dump is redundant with the curated Notes by design.

**Normal path: the `Stop` hook does this for you.** Every assistant
turn, `handoff_turn_append.sh` reads the new lines from the Claude Code
transcript JSONL and appends a formatted turn block (user message,
assistant text, tool calls) to
`.claude/handoff_backups/handoff_raw_<session_id>.md`. The hook prunes
the directory to the 3 newest files. By the time `/handoff` runs the
file already covers the whole session — no one-shot generation needed,
which is the failure mode this hook exists to prevent (context too
saturated to write a long dump at the end).

If the hook is installed and working, skip "Raw dump fallback" below.

### What goes in it

A long-form, lightly-edited brain dump of everything from this session
that might matter to the next session. Not polished. Write without an
editorial filter; better to over-include than miss something.

Structure suggestion (not mandatory — the point is comprehensiveness,
not format):

- **What we worked on.** Plain prose, what the session was actually
  about.
- **What got decided.** Every decision, including the small ones and
  the ones the user pushed back on.
- **What got built or written.** Plans, specs, designs, approved
  approaches — paste them in full if reasonable, summarize faithfully
  if huge.
- **What the user said about how to proceed.** Direct quotes where the
  phrasing matters. Constraints, preferences, things they explicitly
  ruled out.
- **What's still open.** Unanswered questions, things deferred, things
  noted as "tomorrow."
- **What almost got missed.** Anything you nearly didn't write down —
  this is exactly the content the curated Notes will fail to capture.
- **Any other context the next session won't have.** External state,
  things you observed in tool output that won't be re-observable, etc.

The dump is gitignored (the directory should be in `.gitignore`); it
is for local recovery only. Do not commit it.

### Raw dump fallback

Use this only if the `Stop` hook is not installed or the running file is
missing. Create the dump in one shot with the content guidance above,
write it to `<repo-root>/.claude/handoff_backups/handoff_raw_<timestamp>.md`
(use UTC `YYYY-MM-DD_HHMM`), and prune to 3 newest:

```bash
ls -t <repo-root>/.claude/handoff_backups/handoff_raw_*.md 2>/dev/null \
  | tail -n +4 \
  | while IFS= read -r f; do rm -f "$f"; done
```

(`xargs -r` would be the obvious spelling, but `-r` is a GNU extension:
BSD/macOS `xargs` rejects it with `illegal option`, so the prune would
fail silently on the platform this tool is developed on. The `while
read` loop is empty-input-safe everywhere.)

If the directory doesn't exist yet, create it. Make sure
`.claude/handoff_backups/` is in the project `.gitignore` (the hook
also assumes this).

## When to invoke without being asked

The assistant cannot self-measure context % from inside the
conversation (`/context` is a user-side slash command, read-only).
Don't fabricate a percentage. Three real triggers:

### Trigger 1: clean boundary after meaningful work

After a clean boundary — a commit landed, a track wrapped, a spec
shipped, an ASK reply went out — if the boundary feels substantive
(not "ran one grep"), ask:

> Good handoff moment — want me to run /handoff, or keep going?

The user decides. If they say keep going, defer until the next
boundary; don't re-ask at every commit.

### Trigger 2: any user signal about context pressure

If the user mentions context, meter, percentage, "this is getting long,"
"you must be running out," "how much is left," or any similar signal —
treat it as an explicit cue. Immediately offer:

> Sounds like context is getting tight. Want me to run /handoff now?

If they confirm, invoke this skill. Don't try to estimate the number
yourself; the user has the meter, the user is the source of truth.

### Trigger 3: transcript-size system-reminder

The `handoff_ctx_check.sh` `UserPromptSubmit` hook measures context
usage each turn and emits a `<system-reminder>` past a threshold
(default 40% of the detected window — 200k, or 1M for 1M-native
models; both configurable). When the handoff statusLine is wired, the
numbers are Claude Code's own (window size and current usage, cached
by `handoff_statusline.sh` — the same status line that shows
`handoff: curated/auto/none` to the user). This is a **real
measurement**, not a fabricated %, so it's a
legitimate signal to act on.

When the reminder lands, surface it to the user as a **passive
mention** — not a choice, not a question. One line, no question mark,
no "want me to?". Example:

> Flagging: ~40% of context used — natural /handoff moment if you want
> to lock in the prose while I'm still sharp.

Then continue answering the user's actual prompt. By default the hook
nudges ONCE per session (`HANDOFF_CTX_MAX_FLAGS=1` in suggest mode) —
if the user lets it pass, no second reminder is coming, so don't
assume the hook will catch it again later. When the user has raised or
removed the cap (`HANDOFF_CTX_MAX_FLAGS=0` or `N>1`), re-flags are
spaced by a ~100KB-growth cooldown; if a fresh reminder lands later,
surface it again — don't ration yourself. The reminder itself states
which case applies.

### What NOT to trigger on

- A fabricated percentage. The assistant does not have access to the
  number directly; the only real numeric signal is the size from
  Trigger 3.
- Mid-task interruption. Always wait for a clean boundary, even if a
  user signal lands mid-track — finish the in-flight edit, then offer.
- Repeated asks at every tiny boundary. One offer per substantive
  boundary; defer at the next minor one if declined.

## What NOT to do

- Do not invoke this skill mid-task. Always wait for a commit / boundary.
- Do not invoke twice in a row — once the handoff is written and the
  banner is printed, the session is done.
- Do not "soften" the banner because it feels intrusive. It IS intrusive
  by design — the borders exist so the user cannot scroll past it.
- Do not skip the raw dump. It is the recovery path when curated Notes
  turns out thin, which is the failure mode this skill is hardening
  against.
- Empty `## Notes from this session` is acceptable ONLY when the
  session was purely mechanical (single bug fix, no surrounding
  discussion, no decisions made, no work product beyond commits). If
  the session produced a plan, a spec, a decision, or an approved
  approach, Notes is MANDATORY. When in doubt, write the notes —
  underspecifying the next session is the failure mode this skill
  exists to prevent. (The raw dump backstops mistakes here, but
  curated Notes is still the primary deliverable.)
