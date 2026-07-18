# Session Handoff — a discipline for stateful agent loops

A handoff is what one agent session leaves for the next. Its natural failure
mode is growth: every session appends its lessons, the document swells, and it
eventually reproduces — across sessions — the very context bloat that ending
the session was meant to escape.

This is the discipline that avoids that, and the principle behind how the
`/handoff` tool is built. One rule drives it: **the filesystem holds state; the
handoff holds only what the filesystem can't.** A handoff that grows every
session is a smell, not a record. It should trend smaller as it matures.

> **What the tool does vs. what you do.** The tool is mechanical and reliable:
> at session end it snapshots git state (HEAD, branch, commits, working tree)
> and a verify-state command, then asks the agent to write a prose `Notes`
> block; at session start it loads that file into the next session's context.
> Everything below the snapshot — the tiers, the triage, re-deriving claims — is
> *discipline the agent follows*, not automation the tool performs. The split is
> the point: deterministic where a machine can be, prose where only judgment
> works.

It runs in two phases — WRITE at session end, READ at session start — and it's
useful to sort what goes into the Notes through three lenses.

---

## WRITE (session end)

### Lens 1 — The verifiable spine: claims that should be re-derivable, not believed
Prefer facts a later session can confirm from version control or disk, written
as *checks to run*, not verdicts to trust.

- Commit identifiers, branch, and push state — the snapshot already captures
  these above the Notes; don't restate them as prose.
- State claims expressed as their proof, not their conclusion. Instead of "the
  migration is done," write the condition that demonstrates it — e.g. "done iff
  the schema-version row reads 7 and the smoke test exits 0."

If a claim can be checked, write the check.

### Lens 2 — Carry-forward and fences: the rules layer
- In-flight work and the explicit next action.
- Scope fences: "do NOT begin X without a fresh decision."

### Lens 3 — Irreducible intent: prose only
The part the repository genuinely can't tell you. Why the next action is next.
Why an exception is an exception. What you're deliberately *not* doing yet, and
why. Keep this to intent — anything factual belongs in Lens 1.

### Garbage collection — do this before writing; it's what keeps the handoff small
For each lesson the *incoming* handoff carried forward, decide its fate:

- **Settled** — now fixed in code, or written into whatever spec/source your
  system treats as authoritative → move it to that permanent home, then **drop
  it from the handoff.** A learned gotcha graduates into the codebase and leaves
  the handoff for good.
- **Still live** — could still cause a mistake next session → carry it forward.
- **Stale** — no longer applies → drop it.

A failure is fed forward only while it can still bite. If nothing dropped this
session, note why — silent monotonic growth is the signal the loop has stopped
maintaining itself.

---

## READ (session start)

The tool loads the handoff into context; verifying it is the new session's job.

1. **Re-derive the spine.** Run the verify-state block and every checkable
   claim. Confirm each commit exists and is pushed; re-run each state check
   against actual disk. Don't trust the prose verdict — produce it fresh.
2. **On any mismatch, stop and surface it** before doing anything else. A
   handoff that disagrees with the repository is an exception to escalate, not
   an obstacle to work around.
3. **Then** load the fences and intent as the session's starting context.
   In the shipped tool the fences layer (the `## Rules` block and the pin)
   loads as *binding* rules — not just reference data — when the handoff's
   provenance verifies (written locally and signed, not clone-delivered);
   see the main README's "Trusted rules" section.

---

## Standing discipline

- One change at a time. Verify before the next.
- Never widen scope without confirming first.
- Prose is expensive — spend it only on intent. If a sentence could have been a
  check, write the check.
- The agent reports; the human decides what counts as done.

---

## Why the split

Facts you can verify should be verified, never believed; rules constrain what
may happen next; only irreducible intent is carried as prose. Deterministic
where you can be, prose only where you must. A handoff built this way stays
honest with the repository and stays small over time, instead of drifting into
an archive no one can trust or afford to read.
