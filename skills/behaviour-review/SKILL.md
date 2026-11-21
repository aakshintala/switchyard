---
name: behaviour-review
description: "Behaviour review of a diff: find an input, state or environment where the change does the wrong thing for its consumer, with the trigger that shows it. Use when asked to review a change for bugs or correctness, or as the Behaviour axis of a PR review. Reports only; applies nothing."
---

One read-only pass whose only question is: where does this change behave wrongly for someone who uses it? Standards, scope and over-engineering belong to `code-review` and `overbuild-review`; a finding of those kinds is not written here.

Read the workflow doc `docs/agents/workflow.md` points at; its review rules win where they speak. When the diff, the ticket or the checkout is missing, report a failed review naming what is missing.

## Process

### 1. State the claims

From the ticket, the docs it cites and the diff, write the change's behaviour claims, each as `when <trigger>, <consumer> sees <result>`. A consumer is whoever observes the result: a person at the screen, a caller of the API, a reader of the file or event. Include the claims the diff makes without the ticket asking (a changed default, a new error path).

Done when every changed function with a consumer-visible effect sits under at least one claim.

### 2. Trace the reach

For each claim, find how the changed code is reached and what it touches, by searching the checkout rather than reading the diff alone:

- every caller of each changed function, type, event or format, including callers the diff did not edit;
- the state it reads and writes, and what of that outlives the process;
- the place the shipped product assembles the pieces (the real entry point), and whether the changed code is installed there.

Done when each claim names its entry points and its state, or says `not reachable from the product` with the search that shows it. Changed code no product path reaches is itself a finding.

### 3. Attack by dimension

Take every dimension below against every claim. The list is the same for every change so that a review covers the kinds of failure nobody has hit yet as well as the ones that have. For each dimension end with one of: a finding; `checked: <what you traced or ran, in a few words>`; or `n/a: <why this change cannot fail this way>`.

- **Input**: empty, absent, one, many, the largest allowed, malformed, duplicate, wide or combining characters, a value from an older version.
- **State and lifecycle**: first use, second use, use after an interruption midway, after a restart, after a resume or reload, after an upgrade that left old data.
- **Identity and scope**: every key, id, flag or cache entry the change stores or looks up. Is it unique across everything that shares that store (sessions, clients, connections, runs), and is it cleared when its owner goes away?
- **Concurrency and order**: two actors at once, the same events in another order, a cancel or a close arriving at each step.
- **Failure**: list every fallible call the diff adds or newly reaches (in the diff, search for each place a result is propagated, discarded, defaulted or unwrapped), and take each one failing. Is the failure reported to the consumer, or dropped, defaulted or retried forever? What is left half-written, and does the work the failure interrupted still finish or get cleaned up? A failure that is dropped or defaulted is a finding unless a doc or ticket line says that is the behaviour; a `checked` line for one quotes that line.
- **Limits**: every cap the changed path runs under (memory, size, count, depth, time) is reached partway through the operation, not only before it starts. Is the result the one the doc promises for hitting that cap?
- **Environment**: another platform the product ships on, another filesystem layout, another terminal or shell, no network or a stalled one, a different clock or locale.
- **Composition**: a neighbouring feature that shares this state, a configuration combination, the feature switched off.
- **Wiring**: the pieces work alone, but does the product's real assembly connect them? Does a test go through that assembly, or through a stand-in that the product never uses?
- **Resources**: growth without a bound, work repeated per item, a thread, handle or process per unit of load, polling.
- **Contract**: every consumer of a changed type, event, file format or message handles the change, and data written before it still reads. Everyone who watches the state the change alters is told: a second client, a subscriber, a view that drew the old value. What the change shows a person survives its last step: after wrapping, truncation and expiry, can they still read and use it at a real size?
- **Time of evaluation**: a value the change makes depend on live state, but which some caller computed earlier and kept (a cached definition, a snapshot, a value captured before a yield). Who still holds the old one?

Then the repository's own list: when the workflow doc names a list of escape classes (bug classes this project has shipped before), check each one the same way.

Then one more: name one way this change could fail that no line above covers, and check it. Do not skip this; it is how the list grows.

Done when every dimension, every listed escape class and the extra one each have their line.

### 4. Confirm

A suspicion that running something can settle is settled by running it: the one test, or the built product with the input in question, never the whole suite. A suspicion you could not settle is reported as `UNDECIDED` (step 5), not as a finding and not dropped.

For each claim, name the test that would fail if the claim broke, and the level it runs at. A claim whose only tests stop below the product's real assembly, or which no test would catch, is a finding.

Done when every finding carries a trigger you traced or ran.

### 5. Report

```
VERDICT behaviour: APPROVE|CHANGES
P1 src/order.ts:88 — a refund issued after a restart skips the ledger entry (trigger: restart between charge and refund; refund() reads the in-memory map only) — read the entry from the store
P2 src/order.ts:41 — no test fails when the write error is dropped; tests reach save() through FakeStore, the product through DiskStore — add a test through the real store
UNDECIDED src/order.ts:120 — the ticket does not say what a refund larger than the charge does; the code clamps silently
coverage: input checked: empty and oversized amounts traced through parse(); concurrency n/a: single-threaded handler; ...
```

- `P1`: a consumer sees wrong behaviour, loses data or crosses a security boundary, and the trigger is one a real caller or person reaches.
- `P2`: the trigger needs an unusual but possible condition, or a claim has no test that would catch its breaking.
- No `P3`. A behaviour finding either has a reachable trigger or is not written.
- `UNDECIDED`: behaviour nobody has ruled on. It does not block and is not fixed by guessing; whoever runs the review routes it to the project's triage role for a ruling. Use it only when no doc or ticket line speaks, or two of them disagree. Code that differs from what one doc line plainly says is a finding, with that line quoted, even when the pull request calls the gap a later step.
- An axis with any P1 or P2 is `CHANGES`.

Lead with the finding that matters most. Every finding names its trigger: the concrete input, state or sequence, and the line that mishandles it. The `coverage:` line holds the step 3 results and is not counted against a word limit.

## Keeping the dimensions honest

The list in step 3 is general on purpose. When a bug ships that a behaviour review passed, record on its ticket which dimension it fell under. A bug under an existing dimension means the review was shallow there: add the bug to the repository's escape-class list as a worked example. A bug under no dimension means the list is missing one: add it here.
