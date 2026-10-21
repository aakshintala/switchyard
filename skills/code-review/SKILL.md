---
name: code-review
description: "Review the changes since a fixed point (commit, branch, tag, or merge-base) on two axes: Standards (does the code follow this repo's documented standards?) and Spec (does it do what the issue or spec asked, and nothing else?). Ends in one verdict per axis. Use when asked to review a branch, a PR or work in progress, to review since X, or to verify a repair against earlier findings."
---

One review pass on the diff between `HEAD` and a fixed point, on two axes:

- **Standards**: does the code conform to this repo's documented standards?
- **Spec**: does the code do what the originating issue or spec asked, and nothing else?

The axes stay separate: code can follow every standard and build the wrong thing, or build the right thing against the project's conventions. Reporting them apart stops one from masking the other.

Read the workflow doc `docs/agents/workflow.md` points at; its review rules win where they speak. Fetch issues through `docs/agents/issue-tracker.md`. When anything this review needs is missing (the fixed point, the diff, the spec), report a failed review naming what is missing to whoever started you; a review that guesses its inputs is worse than none.

When earlier findings are passed in, skip to **Scoped verify**.

## Process

### 1. Pin the fixed point

Run `git fetch origin`, then take the diff against the remote base: `git diff origin/<base>...HEAD` (three-dot, so the comparison is against the merge-base). A worktree's local `main` may predate landed merges, and diffing against it both fabricates scope creep and hides real creep. List the commits with `git log <fixed-point>..HEAD --oneline`.

Done when the fixed point resolves (`git rev-parse <fixed-point>`) and the diff is non-empty.

### 2. Find the spec

In order: issue references in the commit messages or PR body (`#123`, `Resolves #45`), a path passed as an argument, a spec file under `docs/`, `specs/` or `.scratch/` matching the branch. With no spec, the Spec axis reports `no spec available` and its verdict is `CHANGES`.

### 3. Find the standards

Start from the repo's `AGENTS.md` or `CLAUDE.md`: the docs it indexes for code rules and review are the standards sources, and a list headed as the reviewer's checks is the core of the Standards brief. Then add any other file that documents how code should be written, such as `CODING_STANDARDS.md` or `CONTRIBUTING.md`.

On top of whatever the repo documents, the Standards axis always carries the **smell baseline** below: a fixed set of Fowler code smells (_Refactoring_, ch.3) that applies even when a repo documents nothing. Two rules bind it:

- **The repo overrides.** A documented repo standard always wins; where it endorses something the baseline would flag, suppress the smell.
- **Always a judgement call.** Each smell is a labelled heuristic ("possible Feature Envy"), never a hard violation. Like any standard here, skip anything tooling already enforces.

Each smell reads *what it is* → *how to fix*; match it against the diff:

- **Mysterious Name**: a function, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design's murky.
- **Duplicated Code**: the same logic shape appears in more than one hunk or file in the change. → extract the shared shape, call it from both.
- **Feature Envy**: a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps**: the same few fields or params keep travelling together (a type wanting to be born). → bundle them into one type, pass that.
- **Primitive Obsession**: a primitive or string standing in for a domain concept that deserves its own type. → give the concept its own small type.
- **Repeated Switches**: the same `switch`/`if`-cascade on the same type recurs across the change. → replace with polymorphism, or one map both sites share.
- **Shotgun Surgery**: one logical change forces scattered edits across many files in the diff. → gather what changes together into one module.
- **Divergent Change**: one file or module is edited for several unrelated reasons. → split so each module changes for one reason.
- **Speculative Generality**: abstraction, parameters, or hooks added for needs the spec doesn't have. → delete it; inline back until a real need shows.
- **Message Chains**: long `a.b().c().d()` navigation the caller shouldn't depend on. → hide the walk behind one method on the first object.
- **Middle Man**: a class or function that mostly just delegates onward. → cut it, call the real target direct.
- **Refused Bequest**: a subclass or implementer that ignores or overrides most of what it inherits. → drop the inheritance, use composition.
- **Parallel APIs**: a new API lands beside the legacy one it replaces, with callers split between them. → migrate the callers, then delete the legacy API.

### 4. Review

Read the diff once per axis, and follow each hunk into the code around it as far as the finding needs.

- **Standards**: every place the diff breaks a documented standard (cite the file and rule), and any baseline smell (name it, quote the hunk). Skip anything tooling enforces.
- **Spec**: requirements missing or partial; requirements that look implemented but wrong (quote the spec line). A criterion that asks for evidence the code can no longer produce, such as a repro of a path this diff or a merged fix deleted, is met by a construction argument in the PR body, quoted from the code, that shows every candidate path is gone: judge whether it holds, and raise a finding only when it doesn't.
- **Scope check** (Spec axis): every file or hunk the diff modified that the ticket didn't ask for. An unrequested edit is a finding even when it looks like an improvement.
- When the change touches security, permission, authentication or persistence, add the adversarial branch: try spelling tricks, fail-open inputs, weaker fallback identities, unresolvable indirection and TOCTOU gaps, plus one bypass family beyond the list.

### 5. Report

Write the report where the workflow doc says findings go (a PR comment, for example), else in chat:

```
VERDICT standards: APPROVE|CHANGES
P2 src/order.ts:41 — catches and drops the write error (AGENTS.md: "never swallow errors") — rethrow, or return it to the caller
VERDICT spec: APPROVE|CHANGES
P1 src/order.ts:88 — refund skips the ledger entry the spec requires — write the entry before returning
```

Each finding is `P1|P2|P3 file:line — defect — fix`, under its axis's verdict, most severe first. P1 is wrong behaviour or a security hole, P2 a missed acceptance criterion, an unrequested edit or a hard standards breach, P3 anything smaller, baseline smells included. An axis with any P1 or P2 is `CHANGES`. A merge needs both axes `APPROVE`.

When the defect is a pattern that can recur, the finding names its class and a search shaped like the defect itself, so every instance is a hit and every hit an instance, bounded to the lines the PR adds or changes: `P2 src/order.ts:41 — catches and drops the write error (class: empty catch blocks; find: rg -nU 'catch \(\w*\) \{\s*\}' on the PR's changed hunks) — rethrow`. Code the PR didn't touch is outside the class.

## Scoped verify

The input is the earlier findings and the repair diff (the change since the reviewed head, with any rebase onto a moved base factored out). Check each finding against the code: fixed, refuted, or still open. A finding that carries a `refuted: <evidence>` line is refuted when that evidence holds on the PR head (the cited test exists and asserts it, the cited call site or doc line reads as quoted); otherwise it stays open. A P3 answered with a well-formed `debt:` marker (ceiling and upgrade trigger) on the PR head is closed; one the marker could close only by weakening a rule a doc, spec or ticket states stays open. A refutation by construction argument holds only when the argument does: read the code it quotes and judge the reasoning, beyond checking that the quotes match. For a finding with a class, run its search on the PR head: one instance left inside its bounds keeps it open. Run the scope check (step 4) on the repair diff: a repair that edits beyond its findings and the instances of their classes is a new finding.

```
FIX-OK
```

or `FIX-INCOMPLETE`, followed by every finding still open and every new one, in the finding format above.

## Answering the findings

When you own the change under review, every finding ends **fixed** or **refuted** with evidence: a test, a doc line, a command's output. Sort each before acting:

- A defect the diff shows: fix it.
- A hypothetical ("what if this is null?"): trace the call site. Fix it when a real caller reaches it; refute it citing the call site when none does.
- A preference with no concrete failure ("I'd have structured this differently"): refute it, naming the failure it lacks.
- A report made only of nits reads as a pass: answer each nit in a line.

A fix's diff gets a scoped verify: each finding checked as fixed, and the repair checked for new problems. The full review does not rerun.
