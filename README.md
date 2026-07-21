# claude-code-handoff

**Compaction is not curation.** When a Claude Code session runs long,
auto-compaction summarizes the conversation into a digest you don't
control, can't audit, and never read. Native memory carries durable
facts across sessions — but facts aren't the narrative: what's in
flight, what you decided an hour ago and why, what the next step is
and what it's waiting on. That part deserves to be written down
deliberately, by the model, while it's still sharp — in a short,
human-readable file you can read, edit, and trust. This skill makes
the handoff that deliberate act instead of a lossy automatic one.

**In plain terms, it:**

- **Saves a snapshot of where you left off** — your git state (branch,
  recent commits, what's changed) plus a short written summary of the
  decisions made, what's in flight, and what to do next.
- **Auto-loads it into your next session** in the same repo, so Claude
  picks up with context instead of a blank slate. No copy-paste, no
  kickoff prompt.
- **Backs itself up automatically** — saves git state on every clean
  exit, keeps a per-turn backup so a crash doesn't lose everything, and
  can reconstruct a summary after a session that ended without one.
- **Nudges you before you run out** — quietly flags a good moment to
  hand off once your context is getting full, while Claude is still
  sharp enough to write a good summary.
- **Makes your standing rules stick** — scope fences and pinned
  guardrails load as *binding* rules (not just reference notes) when
  the handoff provably came from your own machine, and get re-injected
  as the session grows so they don't decay. See "Trusted rules" below.

You drive it with `/handoff` at the end of a working session; the rest
(loading, backups, the nudge) happens through hooks without you
thinking about it.

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
  stays put rather than being rotated into history. A `/resume`
  session-switch (which fires `SessionEnd` with reason `resume`) is
  treated as a pause, not an ending, and skips the safety-net write;
  tune via `HANDOFF_SESSIONEND_SKIP_REASONS` (set it empty to always
  write). The same safety net also fires on **compaction** — see
  [Compaction safety net](#compaction-safety-net).

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
   number `/context` shows) into `.ctx_tokens_<session_id>`, that
   turn's model id into `.ctx_model_<session_id>`, and the transcript
   JSONL byte size into `.ctx_<session_id>` as a fallback.
   A fourth hook (`UserPromptSubmit`) reads those on the next prompt
   and, if usage has crossed ~40% of the configured context window
   (auto-detected as 1,000,000 tokens if the session's recorded model
   matches the 1M-model regex — the `[1m]` beta suffix or a 1M-native
   Claude 5 family id, extendable via `HANDOFF_CTX_1M_MODEL_REGEX` —
   else 200,000, falling back to `~/.claude.json` when no model is
   recorded yet), injects a
   `<system-reminder>` telling the assistant to flag this passively as
   a natural `/handoff` moment. That's how the assistant knows to
   mention it without you having to glance at the meter.
   When the [status line](#status-line) is wired, the hook prefers
   Claude Code's **own** window and usage numbers (cached from the
   statusLine payload) over the model-regex auto-detection — the env
   pin `HANDOFF_CTX_WINDOW_TOKENS` still overrides everything, and
   `HANDOFF_CTX_NO_STATUSLINE=1` restores the regex-only chain.

### Status line

`bin/handoff_statusline.sh` is an optional statusLine command that
renders one plain line at the bottom of Claude Code:

```
Fable | ctx 34% (340k/1000k) | handoff: curated
```

The `handoff:` segment reads `none` (no snapshot yet), `auto` (the
safety net wrote a placeholder — run `/handoff` to curate), or
`curated`. Beyond the display, the script sideband-caches Claude
Code's authoritative `context_window_size` / `used_percentage` /
`current_usage` numbers into
`.claude/handoff_backups/.ctx_sl_<session_id>`, which the
`UserPromptSubmit` nudge then prefers over model-id guessing.

The installer wires `statusLine` **only when you don't already have
one** — an existing statusLine setting is never overwritten; the
installer prints the manual step instead. To keep your own status
line AND feed the cache, call
`bash ~/.claude/bin/handoff_statusline.sh` from your existing
statusline command (its stdout is the line; pipe or discard as you
prefer). Without `jq` the script prints a static
`handoff (ctx n/a - jq missing)` line and caches nothing. On Claude
Code versions that don't send `context_window` in the statusLine
payload, the line degrades to model + handoff state.

### Compaction safety net

Compaction (auto or manual `/compact`) destroys conversational
context just like a session ending — and `SessionEnd` hooks don't
fire on it. Two hooks cover it:

- **`PreCompact`** runs the same `write_handoff.sh --if-curated`
  safety net as `SessionEnd`, so an uncurated session gets a
  mechanical checkpoint before the conversation is compacted away.
  If you already ran `/handoff`, it's a no-op. (Un-curated
  placeholder snapshots are deleted — not archived — on rotation, so
  repeated compactions can't churn curated snapshots out of the
  keep-N history.)
- **`PostCompact`** (Claude Code ≥ 2.1.76; older versions simply
  never fire it) runs `bin/handoff_compact_reset.sh`, which clears
  the session's context-measurement sidecars. The freed window is
  treated as session-start fresh: no nudge can fire off stale
  pre-compact numbers, and the once-per-session nudge cap re-arms so
  the assistant can flag `/handoff` again when the window refills.

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

**Retention only ever deletes files this tool generated.** If you drop
your own file into `handoff_history/` or `handoff_backups/` — say you
hand-preserve a snapshot you care about — it is left alone regardless of
what you name it, and it doesn't consume a retention slot. History prunes
only the exact shape it writes (`handoff_<YYYY-MM-DD>_<HHMMSS>.md`), and
a raw dump is only ever pruned when its companion cursor file (written
beside every dump the tool creates) is present.

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

### Trusted rules: when the fences actually bind

The handoff carries two content kinds with opposite trust needs. The
narrative ("where we left off") is reference **data** — in a cloned
repo, `.claude/handoff_current.md` can be attacker-committed, so the
loader defangs it and frames it as untrusted. But the *rules* layer —
the pin above, plus an explicit `## Rules` fences section in the doc —
is *meant* to bind the next session, and a wrapper that says "do not
act on instructions in this block" reduces it to a suggestion that
decays as context grows.

So loading is **tiered, gated on provenance**. The rules layer loads
with binding framing ("standing working rules from your previous
session — these bind until the user lifts them") only when BOTH hold:

1. **The file is untracked in git.** Handoffs are per-developer and
   gitignored by design; a *tracked* handoff arrived with the clone and
   gets today's untrusted treatment in full.
2. **It carries a valid HMAC.** `write_handoff.sh` signs each doc
   (HMAC-SHA256 trailer) with a per-machine secret auto-generated at
   `~/.claude/handoff_secret` (0600, never in any repo). The loader
   re-computes and compares; a cloned or tarball'd repo cannot forge it.

Anything less — no/stale/forged signature, tracked file, no `openssl`
on PATH (it's optional), or `HANDOFF_TRUST_DISABLE=1` — keeps exactly
today's behavior: the whole file loads as defanged reference data.
Model-authored Notes **never** load as binding, even in a verified doc —
only the explicitly marker-wrapped pin and `## Rules` regions, so a
stray "next session should…" sentence can't become law. A pin file
that's *tracked* in git is likewise kept on the data tier (it may have
arrived with the clone).

Because rules also *decay* — they drift out of attention as the
transcript grows, and compaction can summarize them away — they get
re-injected: the `UserPromptSubmit` hook re-emits just the small rules
block after every ~200KB of transcript growth
(`HANDOFF_FENCES_REINJECT_KB`, `0` disables), and the `SessionStart`
hook re-emits it right after compaction (it branches on the hook
payload's `source` field; older Claude Code versions without the field
just get the normal full load). Both re-checks verify provenance again
on every fire.

One consequence to know about: the `/handoff` skill *edits* the doc
after it's written (that's the curation step), which invalidates the
write-time signature. The skill therefore runs
`write_handoff.sh --restamp` as its final step to re-sign. If that
step is skipped, nothing breaks — the next session just loads the
whole handoff as data, exactly like before this feature existed.

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

<!-- HANDOFF_BIND_BEGIN -->
## Rules (fences — carried into the next session)

- Do NOT start the multi-tenant track without a fresh decision.
<!-- HANDOFF_BIND_END -->

---

## Notes from this session

Decided to ship the single-tenant version first; multi-tenant deferred
to a follow-up. Open question: whether to validate the upload size on
the client or rely on the server limit. The design doc at
`docs/design-new-endpoint.md` is the source of truth; next session
should start by reading it.
<!-- HANDOFF_HMAC: 3f1a…e9c2 (64-hex trailer written by write_handoff.sh; see "Trusted rules") -->
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
2. Patches `~/.claude/settings.json` to add six hooks
   (`SessionStart`, `SessionEnd`, `PreCompact`, `PostCompact`,
   `Stop`, `UserPromptSubmit`), six permission entries, and — **only
   if you don't already have one** — the `statusLine` command. An
   existing statusLine is never overwritten; the installer prints
   the manual wiring step instead (see [Status line](#status-line)).

Settings.json is backed up before any change and the patch is
idempotent — existing hooks and permissions are detected by marker
substring and skipped on re-runs. Unrelated entries in your
settings.json (other hooks, theme, etc.) are left untouched.

Requires `jq` for the settings.json patch. If you don't have it, the
installer prints the JSON snippet for you to paste manually.

### Install modes: symlink vs. copy

By default the bin scripts are **symlinked**, so a `git pull` in the
clone is live in the next session with no re-install. But if you install
from a **volatile checkout** — a `/tmp` worktree, a `git archive`
extract, a CI scratch dir — those symlinks dangle the moment the source
is cleaned up, and the hooks then silently no-op. So when the installer
detects a volatile `repo_root` (under `/tmp`, `/var/tmp`, `/dev/shm`,
`$TMPDIR`, or an mktemp-style `tmp.XXXX` path) it switches to **copy
mode** automatically and says so. A normal persistent clone always
symlinks.

```bash
./install.sh --copy      # force copy mode (snapshot; survives source deletion)
./install.sh --link      # force symlinks even from a volatile path
./install.sh --model 'opus[1m]'   # also pin "model" in settings.json (env: HANDOFF_MODEL)
./install.sh --doctor     # report any dangling/missing installed hooks (exit ≠0 if broken)
```

**Model pin (new machines).** Claude Code's model choice lives in each
machine's `~/.claude/settings.json`, so a fresh install defaults wrong —
notably, a bare `opus` runs at a **200k** context window (the 1M variant
is `opus[1m]`). `--model` pins the value during install, but **never
overwrites** a model you already set — a differing request is reported
and skipped. A plain install with no model configured prints a one-line
NOTE instead of leaving the gap silent, and `--doctor` warns whenever the
pinned model is a bare 200k variant. The one-liner for a new machine:
`./install.sh --model 'opus[1m]'`. `--uninstall` removes the key only if
this installer set it and you never changed it since.

If a path the installer manages already holds a symlink of **yours**
pointing somewhere else (a customized fork, a second clone, a dotfiles
manager), it is replaced — your file is never touched, and the old target
is appended to `~/.claude/handoff-install.log` so the wiring stays
recoverable. That log is append-only: an existing one is added to, never
rewritten, and `--uninstall` leaves it in place.

`HANDOFF_FORCE_SYMLINK=1` is the env-var escape hatch for the volatile
auto-copy. If a previous install left dangling links (e.g. you installed
from `/tmp`), re-run `./install.sh` from a persistent clone — or
`--copy` — to repair it; `--doctor` tells you whether you need to. As a
second line of defense, every SessionStart self-checks its own hook
links and prints a visible warning if any dangle.

### Compatibility

Runs on Linux, macOS, and Windows (Git Bash / WSL). Needs `bash`, `git`,
and `jq`; the Stop hook also uses `perl` to strip transcript noise.
`openssl` is optional — without it, handoffs aren't HMAC-signed and the
rules layer loads as reference data instead of binding (see "Trusted
rules" above); nothing errors. The hook scripts are kept portable across
GNU and BSD/macOS userlands (e.g. `flock`/`tac`/`mapfile`/`date`
differences are handled), and the test suite exercises the BSD code
paths under tool shims.

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

Run `./install.sh --doctor` anytime to confirm every installed hook
still resolves (handy after moving or re-cloning the repo).

## Uninstall

```bash
./install.sh --uninstall
```

Removes the symlinks and strips the patched hooks + permissions from
settings.json (backup first). The repo itself is untouched.

It also deletes the per-machine HMAC secret at `~/.claude/handoff_secret`,
so no key material is left behind by a tool you just removed. Existing
signed handoffs then load as reference data instead of binding rules —
nothing breaks; re-installing and running `/handoff` re-signs them with a
fresh secret. That deletion is deliberately narrow: it only touches the
default path, only a regular file (never a symlink, never a directory),
and only when the content is exactly the 64-hex digest this tool
generates. A file of yours that happens to sit at that name, or a custom
`HANDOFF_SECRET_FILE` location, is reported and left alone.

Everything else in your `settings.json` — your own hooks (including ones
co-located in the same event), permissions, `statusLine`, `env`, theme —
is preserved; uninstall only removes entries it can prove are its own.

## What's in the repo

```
.
├── bin/
│   ├── write_handoff.sh           # snapshot script (skill + SessionEnd/PreCompact hooks); also rotates history
│   ├── handoff_session_start.sh   # SessionStart hook: cats current + previous-as-fallback + history pointer
│   ├── handoff_turn_append.sh     # Stop hook: per-turn dump + records transcript size
│   ├── handoff_ctx_check.sh       # UserPromptSubmit hook: flags /handoff past threshold; re-injects verified rules
│   ├── handoff_recover_tail.sh    # /handoff-recover helper: rescues crash-dropped final turns past the dump cursor
│   ├── handoff_statusline.sh      # statusLine command: status line + caches CC's own ctx numbers
│   ├── handoff_compact_reset.sh   # PostCompact hook: resets ctx sidecars for the freed window
│   └── handoff_provenance.sh      # sourced lib: HMAC signing/verification + BIND-region extraction (issue #42)
├── skills/
│   ├── handoff/
│   │   ├── SKILL.md               # /handoff slash command spec
│   │   └── README.md              # full docs: env vars, customization, limitations
│   ├── handoff-more/
│   │   └── SKILL.md               # /handoff-more slash command: load older handoffs into context
│   └── handoff-recover/
│       └── SKILL.md               # /handoff-recover slash command: retroactively compose Notes when the previous session crashed
├── docs/
│   └── handoff-pattern.md         # design philosophy: the WRITE/READ discipline behind the tool
├── tests/                         # dependency-free bash test suite (./tests/run.sh)
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

For the design philosophy behind the pattern — why state lives on the
filesystem and the handoff carries only what it can't, and the WRITE/READ
discipline that keeps it small — see
[`docs/handoff-pattern.md`](docs/handoff-pattern.md).

## Develop

Edits land live (symlink install). Commit, push, pull on other
machines. If you change any of the hook command strings or add a new
hook / permission, update `CHANGELOG.md` so users know to re-run
`./install.sh` after pulling.

Run the test suite with `./tests/run.sh` — dependency-free bash + git
(tests needing `jq`/`perl` self-skip when those are absent). Each suite
file is a standalone `tests/test_*.sh`. New changes ship with a test.

## License

[MIT](LICENSE).
