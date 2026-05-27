# claude-code-handoff

Claude Code sessions hit a context limit. When they do, the next
session starts blind — you re-explain the project, the in-flight work,
the decisions you made twenty minutes ago, all from memory. This skill
makes the next session not blind.

Three paths, doing different jobs:

- **`/handoff` (preferred, you invoke it at session end):** writes
  the snapshot AND asks the assistant to append a "Notes from this
  session" prose block — decisions, open questions, "next session
  should start with X." The prose is the part git can't see. Use
  this at clean boundaries (commit lands, track wraps) or when your
  context meter is getting tight. Rule of thumb: invoke at 30-50%
  remaining, not at 5% — quality degrades well before the meter runs
  out, and you want the reflection to happen while the model is
  still sharp.
- **`/handoff-more` (you invoke it in a fresh session):** pulls
  *older* handoffs into the new session's context, beyond the single
  most-recent one that auto-loads. Use it when the loaded handoff is
  thin, when you reference work from a session further back than
  yesterday, or to give a sibling re-entering the repo continuity
  deeper than the last session alone.
- **`/handoff-recover` (auto-triggered by the SessionStart hook):**
  composes a retroactive curated handoff when the previous session
  ended without `/handoff` — crashed, killed, or just never
  invoked. The SessionStart hook detects the placeholder Notes
  block and prints an `ACTION: RUN /handoff-recover` banner; the
  skill reads the previous session's raw per-turn dump under
  `.claude/handoff_backups/`, the prior curated handoff under
  `.claude/handoff_history/`, and (if present) the host-wide
  session registry, then reconstructs what the lost session would
  have written and persists it back into `handoff_current.md` so
  the recovery survives into future history.
- **`SessionEnd` hook (automatic, safety net):** on clean session
  exit, fires the same snapshot script — but no model is in the loop,
  so the "Notes from this session" block stays empty. You get git
  state (HEAD, branch, recent commits, working tree, in-flight docs)
  and nothing else. It's there so an unplanned exit isn't a total
  loss, not as a substitute for `/handoff`. The hook passes
  `--if-curated`, so if you already ran `/handoff` this session (it
  replaced the placeholder block with curated Notes), the safety-net
  write is a no-op — your curated content
  stays put rather than being rotated into history.

The next session in the same repo auto-loads the latest snapshot via
the `SessionStart` hook. No `/compact` to remember, no kickoff prompt
to write, no copy-paste. The new session starts with a fresh context
window — the loaded handoff itself consumes a few KB (more if the
`Notes from this session` prose is long), which is negligible against
a 200k or 1M window.

A third hook (`Stop`) does two jobs each assistant turn:

1. Appends the turn to a raw-dump backup under `.claude/handoff_backups/`
   — the fallback for cases where the process is killed before
   `SessionEnd` can fire (SIGKILL, terminal closed).
2. Records context measurements into `.claude/handoff_backups/`: the
   real token count from the latest assistant turn's `usage` (same
   number `/context` shows) into `.ctx_tokens_<session_id>`, and the
   transcript JSONL byte size into `.ctx_<session_id>` as a fallback.
   A fourth hook (`UserPromptSubmit`) reads those on the next prompt
   and, if usage has crossed ~50% of the configured context window
   (auto-detected as 1,000,000 tokens if `~/.claude.json` shows a
   `[1m]` model active for this project, else 200,000), injects a
   `<system-reminder>` telling the assistant to flag this passively as
   a natural `/handoff` moment. That's how the assistant knows to
   mention it without you having to glance at the meter.

### Where the handoff files live

Only the latest snapshot is named `handoff_current.md`. Each new
write rotates the previous one into `<repo>/.claude/handoff_history/`,
filename stamped with the snapshot's own timestamp. The last 5 are
kept (override via `HANDOFF_HISTORY_KEEP=N`, or `0` to disable
retention); older entries are pruned. So the on-disk layout looks
like:

```
<repo>/.claude/
├── handoff_current.md                       # the latest snapshot (always)
├── handoff_pinned.md                        # optional: carried forward verbatim (see below)
└── handoff_history/                         # rotated older snapshots
    ├── handoff_2026-05-13_174853.md         # yesterday's
    ├── handoff_2026-05-12_194751.md         # two sessions ago
    ├── handoff_2026-05-11_103022.md
    ├── handoff_2026-05-10_215800.md
    └── handoff_2026-05-09_142105.md
```

Two consumers read this directory:

- The `SessionStart` hook auto-includes the most recent history entry
  *if* `handoff_current.md` was an auto-write (no curated Notes from
  `/handoff`) — so an unplanned exit doesn't strand the next session
  with only mechanical git state. When current already has curated
  Notes, the hook just notes that history exists.
- `/handoff-more` reads up to N retained snapshots into context on
  demand, so the assistant can see further back than just yesterday.

The retention dir is bootstrapped into the repo's `.gitignore` on
first write — handoffs are intentionally per-developer, not
checked-in artifacts.

### Pinned context (carried forward every handoff)

Some context outlives a single session but isn't a permanent rule —
load-bearing facts the next session needs, and guardrails ("don't drop
X", "Y connects via Z, not a password"). Re-typing those into the Notes
block every session is lossy. Drop them in `<repo>/.claude/handoff_pinned.md`
and they're injected verbatim at the top of *every* handoff. The script
only reads that file — never rotates or regenerates it — so it persists
untouched until you edit it. Three layers, by lifetime:

- **`AGENTS.md`** — permanent governance rules.
- **`handoff_pinned.md`** — durable-but-temporary context + guardrails
  that expire when the underlying state resolves (a migration finishes,
  an incident closes). The pin is where you record those.
- **Notes block** — this-session intent only.

The pin is gitignored on first write (same per-developer posture as the
handoff). Override its path with `HANDOFF_PINNED_FILE`. Absent file →
no pinned section; repos that don't use it are unaffected.

### System-log nudge

If your repo keeps a `SYSTEM_LOG.md` (an append-only record of
shape-changing work — security posture, scaffold/topology, migrations),
the handoff flags a `⚠️` section when this session's commits *look*
system-level (by changed-path or commit-subject heuristic) but none of
them touched the log. It's a reminder to record the work before context
is lost, not a gate. It fires only at handoff time over the
previous-handoff→HEAD commit range, so routine sessions stay silent.
Override the watched file with `HANDOFF_SYSTEMLOG_FILE`; tune the
heuristics inline in `write_handoff.sh` if they over-fire for your repo.
Absent file → no nudge.

## What the handoff actually looks like

After `/handoff` (or any session exit) you get
`<repo>/.claude/handoff_current.md`:

````markdown
# myproject — session handoff (auto-generated)

**Generated:** 2026-05-12 14:59 UTC

---

## Repo: myproject

**HEAD:** `abc1234` — wire up the new endpoint

**Branch:** `feature/new-endpoint` (feature/new-endpoint...origin/feature/new-endpoint [ahead 2])

### Recent commits

```
abc1234 wire up the new endpoint
def5678 add request validator
9012abc move shared types out of the handler
```

### Working tree

```
 M src/handler.ts
?? docs/design-new-endpoint.md
```

## In-flight (untracked or modified .md under `docs/`)

- `docs/design-new-endpoint.md`

## Verify state matches reality

```bash
git -C /path/to/myproject status && git -C /path/to/myproject log --oneline -5
```

---

## Notes from this session

Decided to ship the single-tenant version first; multi-tenant deferred
to a follow-up. Open question: whether to validate the upload size on
the client or rely on the server limit. The design doc at
`docs/design-new-endpoint.md` is the source of truth; next session
should start by reading it.
````

The auto-snapshot above the `---` is git state — cheap, mechanical,
always correct. The "Notes from this session" block is the part git
can't see: decisions, in-flight tracks, open questions. The
`SessionEnd` hook leaves that block as a placeholder. Running
`/handoff` is what fills it in, so for any session that involved real
discussion, `/handoff` is the preferred path; `SessionEnd` is the
safety net for unplanned exits.

## Install

```bash
git clone https://github.com/Sting25/claude-code-handoff.git ~/code/claude-code-handoff
cd ~/code/claude-code-handoff
./install.sh
```

That:

1. Symlinks the bin scripts and skills into `~/.claude/`.
2. Patches `~/.claude/settings.json` to add four hooks
   (`SessionStart`, `SessionEnd`, `Stop`, `UserPromptSubmit`) and
   four permission entries.

Settings.json is backed up before any change and the patch is
idempotent — existing hooks and permissions are detected by marker
substring and skipped on re-runs. Unrelated entries in your
settings.json (other hooks, theme, etc.) are left untouched.

Requires `jq` for the settings.json patch. If you don't have it, the
installer prints the JSON snippet for you to paste manually.

## Updating

Because the install is symlink-based, updating the scripts is just:

```bash
cd ~/code/claude-code-handoff && git pull
```

No re-install needed. Edits in the repo are live in the next Claude
Code session. The exception is if a future release changes the hook
command string or adds a new hook — that's called out in
[`CHANGELOG.md`](CHANGELOG.md), and re-running `./install.sh` after
`git pull` re-patches your settings.json.

## Uninstall

```bash
./install.sh --uninstall
```

Removes the symlinks and strips the patched hooks + permissions from
settings.json (backup first). The repo itself is untouched.

## What's in the repo

```
.
├── bin/
│   ├── write_handoff.sh           # snapshot script (used by skill + SessionEnd hook); also rotates history
│   ├── handoff_session_start.sh   # SessionStart hook: cats current + previous-as-fallback + history pointer
│   ├── handoff_turn_append.sh     # Stop hook: per-turn dump + records transcript size
│   └── handoff_ctx_check.sh       # UserPromptSubmit hook: flags /handoff past threshold
├── skills/
│   ├── handoff/
│   │   ├── SKILL.md               # /handoff slash command spec
│   │   └── README.md              # full docs: env vars, customization, limitations
│   ├── handoff-more/
│   │   └── SKILL.md               # /handoff-more slash command: load older handoffs into context
│   └── handoff-recover/
│       └── SKILL.md               # /handoff-recover slash command: retroactively compose Notes when the previous session crashed
├── install.sh                     # symlink + settings.json patcher
├── CHANGELOG.md
├── LICENSE                        # MIT
└── README.md                      # this file
```

For the skill spec, env vars (substrate pattern, in-flight directories,
gitignore bootstrap), and the limitations worth knowing about —
notably that Claude Code can't actually force a session restart at a
context threshold, so the human keystroke is still required — see
[`skills/handoff/README.md`](skills/handoff/README.md).

## Develop

Edits land live (symlink install). Commit, push, pull on other
machines. If you change any of the hook command strings or add a new
hook / permission, update `CHANGELOG.md` so users know to re-run
`./install.sh` after pulling.

## License

[MIT](LICENSE).
