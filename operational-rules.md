# Operational rules

Process, collaboration, and judgment rules for working effectively
with AI agents (and as a human engineer). These are durable patterns
extracted from real failure modes — not code-level rules (those live
in [`coding-rules.md`](./coding-rules.md)) but session-level
discipline that no linter can enforce.

For Claude Code with the full scaffold, this file is referenced
from `AGENTS.md`, which is auto-loaded via `CLAUDE.md`.

To use this file **standalone** (no linter / hook / CI scaffolding),
drop it in your project root and add `@operational-rules.md` to your
`CLAUDE.md` — that auto-loads it into context on session start. No
`install.sh`, no hooks, no CI workflow needed.

For Cursor, Cline, Aider, or other AI tools, add an equivalent
reference to whatever config file the tool uses (`.cursorrules`,
`.clinerules`, `CONVENTIONS.md`, etc.). The goal is that the agent
sees this document at the start of every session.

If you're using this without an AI agent, the document still works
as a reference for human engineers. Read it before writing code,
revisit it when something goes wrong, add to it when you find a
new failure mode.

---

## Engineering

### Pass structured types, not primitive tuples, across boundaries
The structured value is what crosses the wire. Tests should both
`assert isinstance(...)` AND touch named attributes — a duck-typed
stand-in with wrong fields fails the second check. Type annotations
alone don't enforce structure; they only document intent.
*Anchor:* orchestrator returned a 4-tuple where worker expected a
typed dataclass; the type annotation lied and the bug surfaced only
after compute had been spent.

### Read schema constraints before composing writes
Enum-style columns and check constraints have allowed-value lists
baked into the model. Open the model file and scan constraint blocks
before writing any INSERT, UPDATE, or migration. AI tools frequently
generate plausible-looking values that violate constraints they
didn't see.
*Anchor:* every per-record INSERT failed because the agent passed a
descriptive string when the schema required a specific enum value
defined elsewhere in the codebase.

### Use the canonical helper; bench code is bench-only
Before writing math, format, or utility helpers, grep production for
existing implementations. Bench scripts and exploratory notebooks
shortcut things that production must do correctly. AI tools will
happily reach for bench-style patterns when generating production
code if you don't redirect.
*Anchor:* a driver inherited bench-style coordinate math when a
canonical helper already existed in production code; the bench
version had edge-case bugs the canonical version had already fixed.

### Plan storage shape before scaling compute
For any per-unit output (tile, record, document, embedding), multiply
size by realistic scale before committing to a format. Tiered
retention designed in from day 1, not retrofitted. Storage cost
surprises kill more personal projects than any other failure mode.
*Anchor:* per-unit output measured at multiple GB; full-scale
projection ran into petabytes. Format and tiering decisions had to
be redone after significant ingestion was already complete.

### Heartbeats must not block on long synchronous I/O
If a worker reports liveness via heartbeats, those heartbeats must
tick from a daemon thread independent of work, OR async I/O must
yield between operations. Synchronous I/O during work blocks the
heartbeat and triggers false-positive reaping.
*Anchor:* reaper killed workers that were busy with large uploads,
not actually dead, because the heartbeat thread was blocked on the
same synchronous I/O the worker was performing.

### Validate inputs at component boundaries
Each component in a federated or distributed system should validate
its inputs at the boundary, not assume the upstream component
honored the contract. AI-generated code often skips boundary
validation because it trusts the type system or the upstream
implementation it just wrote.
*Anchor:* a downstream component crashed on malformed input that an
upstream component should have rejected; both components were
AI-generated and neither validated the contract between them.

### Integration tests hit a real database, not mocks
Mocked tests pass against the mock's behavior, not against the
database's actual behavior. Schema constraints, migration drift,
and dialect quirks only surface against a real instance. Spin up
an ephemeral DB per test run if isolation matters — but don't
substitute a mock object for the connection.
*Anchor:* mocked tests passed for months while the production
migration silently broke; the divergence was invisible until a
deploy hit the real schema.

### Tests cover every code path; back claims with measurement
"We have tests" is not the same as "this is tested." Every branch,
every error path, every contract assertion needs an explicit test.
When claiming correctness or performance, back the claim with a
number from a real run against a real system — not a narrative
about what the code "should" do.
*Anchor:* untested code paths routinely shipped with undiscovered
bugs that surfaced as production incidents months after merge,
because "looks right" beat "measured to work."

### No silent failures
When a unit of work fails — a request, a record, a cell, a job —
log a WARN-or-higher event with the failure reason AND surface the
failure in the response payload (e.g. via a `partial` status,
explicit error field, or non-success HTTP code). Catching an
exception and returning a "success" response without signaling
the failure is the most expensive habit in production code;
downstream consumers act on stale or wrong data, and the problem
only surfaces hours later as a derived failure that's harder to
trace back.
*Anchor:* a batch job swallowed per-record errors and reported
"complete"; downstream pipelines built on the missing-rows-without-error
state spent days untangling the resulting derived corruption.

### Hold shared-resource locks for contiguous work, not per operation
When multiple processes contend for a single shared resource (GPU,
DB connection from a small pool, hardware port, file lock),
acquire the lock once for the contiguous stretch of work and
release after — never per individual operation. Per-operation
locking causes thrash, partial-state failures under contention,
and starvation when one worker can never acquire long enough to
complete a unit of work.
*Anchor:* per-CUDA-call GPU lock acquisition caused worker thrash
and out-of-memory failures because no single worker ever held the
lock long enough to complete a contiguous compute unit.

### Never print, cat, or echo secret files
`.env` files, `credentials.json`, key files, OAuth tokens — never
`cat`, `print`, `echo`, or log them. AI agents have a particular
habit of running `cat .env` during debugging "to check something";
the values then live in chat transcripts, log files, or git
diffs forever and require rotation. To verify a value exists or
matches an expected shape: check length, compare against a known
hash, or count non-empty lines. The cheapest path is never to
expose the secret in the first place.
*Anchor:* AI-agent-driven `cat .env` to "verify the file is
loaded" landed credentials into a permanent chat transcript;
rotation across multiple services took hours.

### Clean up leftovers after hands-on work
Whatever a task spins up, the same task tears down: containers,
dev servers, background processes, temp/scratch files, browser
panes. Surface pre-existing orphans as things to remove, not
noise to shrug at. The exception is state the user explicitly
wants kept (a long-lived test stack, persistent data volumes) —
confirm before removing those, and never remove them by default.
Force-removing a container/process not created this session needs
explicit user OK first.
*Anchor:* a stub stack left an orphaned proxy container running
from a run days earlier; flagging it as "harmless" rather than
cleaning it drew an explicit "always clean up after ourselves."

---

## Process

### One canonical decisions file; archive everything else
All locked decisions live in a single file (`CURRENT.md`,
`DECISIONS.md`, or similar). Old files move to `_archive/`. New
decisions update the canonical file, not new files. AI agents take
shortcuts when reading everything isn't tractable, so the canonical
file must be loadable into context.
*Anchor:* project accumulated dozens of decision documents and
memory entries; agent began making decisions inconsistent with
locked ones because it couldn't read everything in a single pass.

### Pre-flight catches beat mid-run discovery
For any job longer than 5 minutes wall-clock, write a pre-flight
check per external dependency. Fail fast in seconds before committing
to compute. Database reachable? Schema migrated? API auth valid?
Disk space? Output bucket writable?
*Anchor:* pre-flight check caught an unmigrated database and an
unreachable bucket in seconds; would have wasted 38 minutes
mid-run discovering the same problems.

### Smoke at the smallest scale that exercises the full path
After any non-trivial change, run 1 unit / 1 batch / 1 record first.
Scale only after small succeeds. Note the qualifier: smoke tests
that don't exercise the full path are theater. The smoke test must
hit every component that fails at scale.
*Anchor:* a 4-unit smoke caught contention between workers; a
1-unit smoke proved the fix. Both were necessary. A test that
skipped any component would have failed to catch the bug.

### Commit each fix immediately; don't batch
Each logical fix is its own commit. Group only when tightly coupled
(a fix plus the test that prevents its regression). AI tools love
to batch fixes into larger diffs because each individual change
feels small and the cumulative work feels productive.
*Anchor:* mixed commits become unrevertable when one fix turns out
to be wrong; pre-commit failures force re-stage cycles when many
unrelated changes are batched together.

### Locked decisions are revisitable on new evidence
Surfacing new evidence and proposing a revisit IS appropriate.
Re-litigating with the SAME evidence the lock was made with is not.
Classify new evidence: was it available at lock time? load-bearing
on the original decision? strategy update or full unlock?
*Anchor:* a format decision was locked before per-unit size was
measured; the measurement constituted real challenge evidence, not
noise, and warranted explicit revisit rather than silent override.

### Write down why, not just what
Code comments and decision documents should explain why a choice
was made, not just what the code does. AI tools regenerate "what"
on demand from any "why." Without "why," future sessions can't
distinguish load-bearing decisions from incidental ones.
*Anchor:* a refactor session removed a workaround whose reason had
never been written down; the original bug returned weeks later
and required rediscovery from scratch.

---

## Collaboration

### Agent reports measurements; user calls "fixed" / "done"
Concrete numbers (test counts, throughput, byte sizes, gate pass
rates, latency) come from the agent. Verdicts ("fixed", "done",
"verified", "working") come from the user. AI tools tend to declare
victory based on surface pattern matching rather than verified
behavior; reserving the verdict for the human prevents premature
"fixed" claims.

### Plans default to PROPOSED; mark every assumption
Each value the agent picked itself gets PROPOSED plus a one-line
"alternative would be Y because Z." User scans, redirects where
needed, accepts the rest. Cheaper than a multi-question pre-survey
and more honest than presenting decisions as facts.

### Pause signals stop work, surface state, ask
Words like "hold on" / "wait" / "hmm" / "actually" mean the user
spotted something the agent missed but hasn't articulated yet.
Finish the in-flight edit, summarize current state, ask the
question that prompted the pause. Don't barrel through pauses
treating them as conversational noise.

### Ask before expanding scope
A request to fix bug A is not permission to refactor module B,
even if module B looks improvable. Surface the proposed scope
expansion as a separate question. Scope creep within a single
change is one of the most common ways AI-assisted edits introduce
unintended regressions.

### Surface uncertainty rather than guessing
When the agent doesn't have enough context to make a decision
confidently, the right move is to ask, not to guess and proceed.
Confident-sounding wrong answers are more expensive than honest
"I'm not sure, here's what I'd need to know" responses.

### Suggest a cheaper model when the task doesn't need a big one
When a sub-task is mechanical — verifying a static edit landed,
running a smoke test, reformatting, a grep-and-report, a yes/no
check — proactively offer to run it on a smaller/faster model
(e.g. Haiku for a subagent, or a model downgrade) instead of
silently spending premium tokens. The trigger is task difficulty,
not just the user flagging cost: name the cheaper option, say why
it's adequate, and let the user decide. Reserve the large model
for genuine reasoning, design, and ambiguous judgment. Don't
downgrade silently — surface it as a suggestion so the user keeps
the call.

---

## Working rules (process doctrine — distilled from real incidents)

### Scope discipline
- Do the literal ask, nothing adjacent. Related bugs/smells get LISTED, not
  fixed, and end the turn. The broader goal ("make CI green", "fix the suite")
  doesn't exist unless the user wrote the broader words.
- One-file default: any same-edit change touching >1 file stops for approval
  first. Refactors/renames/pattern-fixes are sweeps — approval first.
- Vague or high-blast-radius asks get a 5-line contract before work:
  Goal / In-scope / Out-of-scope / Done-when / Files-touched — then WAIT for a go.
- When unsure: do less and ask. Under-reach is cheap; over-reach costs a revert.

### Verification (the trust bar)
- Numeric gates alone can be fooled by coherent-but-wrong results — a
  self-consistent wrong answer passes RMS/error checks. Every result must
  also be verified against INDEPENDENT ground truth (overlay on a known-good
  reference, end-to-end render, real output inspected).
- Add physical-plausibility gates: reject results whose implied parameters
  are impossible (e.g. zero rotation + non-square scale from a scanned photo).
  When a class of failure is found once, encode a deterministic gate for it.
- Smoke at the smallest scale that exercises the FULL path before any long or
  expensive run. Pre-flight checks before long jobs.
- The agent reports measurements; the human calls done. Never mark something
  verified without saying who/what verified it and how.
- Never fabricate a number you can't measure (progress %, context %, cost) —
  say "unmeasured" instead.

### Determinism over LLM judgment
- Anything done twice becomes a script. Verification must be machine-checkable
  (exit codes, diffable outputs), not "the model looked at it".
- LLMs propose; deterministic code disposes. Where a deterministic method
  exists (feature-matching, checksums, direct API data), prefer it over
  model judgment — use models only where determinism can't reach.
- Prefer authoritative upstream data over model-reconstructed data
  (e.g. natively-georeferenced products over model-placed ones).

### Model economics
- At session start, confirm the operating mode with the user: DELEGATE (offload
  substantial work to subagents/workflows to preserve the main context window —
  the default) or STAY IN-WINDOW (work inline). Ask when it's unclear, before
  starting substantial work.
- Model ladder floor = cheapest model PROVEN on that task class (Haiku for
  mechanical/scouting, Sonnet for moderate reasoning, Opus for hard judgment);
  escalate one tier on failure (Haiku → Sonnet → Opus). A failed cheap attempt
  surfaces to the human before burning top-tier tokens — no silent
  auto-escalation; if the top tier also fails, stop and let the human decide.
- Main session orchestrates only (triage, synthesis, judgment, review, writing
  the change); scouting, probes, builds, bulk work, verification, and
  browser-driving go to cheaper subagents. Context preservation is itself a
  reason to delegate. Trivial one-liners stay inline — agent spin-up costs more
  than the task.
- Parallel agents that WRITE each get their own git worktree; only one agent
  runs DB-backed integration tests at a time.
- Pilot before scale ("make it work first"); pilot outputs become the
  benchmark set for any later model/provider bake-off.

### Data & failure hygiene
- When a result is found bad, demote it EVERYWHERE it landed: registry files,
  DB rows, object storage, generated artifacts — with a written note saying
  why, so no future session trusts it. Record the postmortem in-repo as
  standing doctrine, not just in chat.
- Report failures honestly: zero defensible rows beats plausible fabricated
  ones. If a build can't meet its bar, it stays NOT-BUILT with the reason.
- Fix lint/guardrail violations in the code; never noqa/ignore/exempt.
  If the hook is wrong, fix the hook.
- Big/produced artifacts live in object storage; local disk is scratch.
  Highest quality at lowest file size for produced media.
- Never risk service lockouts: few pages, slow, back off on challenges,
  never evade blocks — for probes AND ingests.

### Product completeness
- A backend feature isn't done until it's VISIBLE in the product (renders on
  the map/UI). No invisible backends; track owed wiring explicitly.
- Done = walled: a finished module gets do-not-touch status, ideally
  machine-enforced (import checks in pre-commit/CI). Unwall grants are
  change-scoped and expire on merge.

### Git
- Never push unless asked. Never amend pushed commits. Never force-push.
  Never bypass hooks (--no-verify). One commit per logical change.
- No destructive tree ops (reset --hard / checkout . / clean -fd) on a dirty
  tree without confirming.

### Collaboration
- The user is not a programmer: plain language, no unexplained jargon,
  ask don't assume, and draft the prompts/contracts/messages for them.
- Surface uncertainty instead of guessing; give a recommendation, not a
  survey. When the user's eyes catch something the gates missed, that's a
  missing gate — build it.

---

## Adding rules to this document

A rule earns its place when:
- A real incident demonstrated the failure mode
- The fix is generalizable beyond the specific incident
- Tool-enforcement (lint, hooks) can't catch it
- The rule can be stated as an imperative + anchor in under 5 lines

A rule should be retired when:
- The original anchor no longer applies in current tooling
- The pattern has been absorbed into a tool-enforceable rule
- The rule has been superseded by a better-articulated version

Anchors should reference the type of incident, not project-specific
details, so the document remains useful across projects.
