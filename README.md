# claude-code-handoff

Claude Code sessions hit a context limit. When they do, the next
session starts blind — you re-explain the project, the in-flight work,
the decisions you made twenty minutes ago, all from memory. This skill
makes the next session not blind.

On session exit, a hook writes a snapshot of where you left off
(`HEAD`, branch, recent commits, working tree, in-flight docs). On the
next session start in the same repo, another hook loads that snapshot
into context automatically. No `/compact` to remember, no kickoff
prompt to write, no copy-paste.

You can also invoke `/handoff` manually at any clean boundary — it
writes the same snapshot, asks the assistant to append a "Notes from
this session" block (decisions, open questions, "next session should
start with X"), and prints a loud banner telling you to start a new
session.

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

1. Symlinks the bin scripts and skill into `~/.claude/`.
2. Patches `~/.claude/settings.json` to add three hooks
   (`SessionStart`, `SessionEnd`, `Stop`) and two permission entries.

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
│   ├── write_handoff.sh         # snapshot script (used by skill + SessionEnd hook)
│   └── handoff_turn_append.sh   # Stop-hook: appends each turn to the raw-dump backup
├── skills/
│   └── handoff/
│       ├── SKILL.md             # /handoff slash command spec
│       └── README.md            # full docs: env vars, customization, limitations
├── install.sh                   # symlink + settings.json patcher
├── CHANGELOG.md
├── LICENSE                      # MIT
└── README.md                    # this file
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
