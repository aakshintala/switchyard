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

On top of whatever the repo documents, the Standards axis always carries the **smell baseline** below: three structural smells that apply even when a repo documents nothing. Two rules bind it:

- **The repo overrides.** A documented repo standard always wins; where it endorses something the baseline would flag, suppress the smell.
- **Always a judgement call, always P3.** Each smell is a labelled heuristic ("possible Data Clump"), never a hard violation, and never starts a fix round by itself. Like any standard here, skip anything tooling already enforces.

Each smell reads *what it is* → *how to fix*; match it against the diff:

- **Duplicated Code**: the same logic shape appears in more than one hunk or file in the change, or the change adds a copy of something the codebase already has. → extract the shared shape, or call the existing one.
- **Data Clumps**: the same few fields or params keep travelling together (a type wanting to be born). → bundle them into one type, pass that.
- **Parallel APIs**: a new API lands beside the legacy one it replaces, with callers split between them, or a second path exists that only tests call. → migrate the callers, then delete the other path.

Names, message chains, middle men and other matters of taste are findings only when a documented standard covers them.

### 4. Review

Read the diff once per axis, and follow each hunk into the code around it as far as the finding needs.

- **Standards**: every place the diff breaks a documented standard (cite the file and rule), and any baseline smell the diff shows at named sites (name it, quote each site, such as both copies of duplicated code). Skip anything tooling enforces.
- **Spec**: requirements missing or partial; requirements that look implemented but wrong (quote the spec line). A criterion that asks for evidence the code can no longer produce, such as a repro of a path this diff or a merged fix deleted, is met by a construction argument in the PR body, quoted from the code, that shows every candidate path is gone: judge whether it holds, and raise a finding only when it doesn't.
- **Scope check** (Spec axis): every file or hunk the diff modified that the ticket didn't ask for. An unrequested edit is a finding even when it looks like an improvement.
- **Behaviour is its own review.** Whether the change works across inputs, states, failures and environments is `behaviour-review`'s question. When that axis runs alongside, leave wrong behaviour to it unless you trip over it while checking a standard or a criterion; when it does not run, a wrong behaviour you find is still a P1 here.
- When the change touches security, permission, authentication or persistence, add the adversarial branch: try spelling tricks, fail-open inputs, weaker fallback identities, unresolvable indirection and TOCTOU gaps, plus one bypass family beyond the list.

### 5. Report

Write the report where the workflow doc says findings go (a PR comment, for example), else in chat:

```
VERDICT standards: APPROVE|CHANGES
P2 src/order.ts:41 — catches and drops the write error (AGENTS.md: "never swallow errors") — rethrow, or return it to the caller
VERDICT spec: APPROVE|CHANGES
P1 src/order.ts:88 — refund skips the ledger entry the spec requires — write the entry before returning
```

Each finding is `P1|P2|P3 file:line — defect — fix`, under its axis's verdict, most severe first: lead with the one finding that matters most, and spend the words there before listing smaller ones. P1 is wrong behaviour or a security hole. P2 is a missed acceptance criterion, an unrequested edit or a breach of a standard that changes what the code does or what a test proves. P3 is anything smaller: baseline smells, wording, comments, and a breach of a rule about form (how a pull request body, a commit or a citation is laid out). An axis with any P1 or P2 is `CHANGES`. A merge needs both axes `APPROVE`.

Every finding names its evidence: a concrete input or state that goes wrong, or the doc line or ruling it breaks (for a standard, the doc's rule and the code line; for a baseline smell, every site that shows it, such as both copies of duplicated code). A finding with neither is not written, whatever its severity. That drops a hypothetical input nothing in the code or ticket produces, a request to cite the ticket line that asks for the code, a name or shape that no doc rule covers and no second site shows, and remarks on process. Standards, spec and overbuild verdict lines may end with one period. Verify verdicts may stand alone, continue with whitespace and detail, or have exactly one of `.`, `:`, `;` or `,` immediately after the verdict, followed by whitespace and optional detail or the end of the line.

When the defect is a pattern that can recur, the finding names its class and a search shaped like the defect itself, so every instance is a hit and every hit an instance, bounded to the lines the PR adds or changes: `P2 src/order.ts:41 — catches and drops the write error (class: empty catch blocks; find: rg -nU 'catch \(\w*\) \{\s*\}' on the PR's changed hunks) — rethrow`. Code the PR didn't touch is outside the class.

## Scoped verify

Judge only findings in the `--verify` findings file against the repair diff (the change since the reviewed head, with any rebase onto a moved base factored out); posted rounds provide context, not findings to judge. Check each finding against the code: fixed, refuted, or still open. A finding that carries a `refuted: <evidence>` line is refuted when that evidence holds on the PR head (the cited test exists and asserts it, the cited call site or doc line reads as quoted); otherwise it stays open. A P3 answered with a well-formed `debt:` marker (ceiling and upgrade trigger) on the PR head is closed; one the marker could close only by weakening a rule a doc, spec or ticket states stays open. A refutation by construction argument holds only when the argument does: read the code it quotes and judge the reasoning, beyond checking that the quotes match. For a finding with a class, run its search on the PR head: one instance left inside its bounds keeps it open. Run the scope check (step 4) on the repair diff: a repair that edits beyond its findings and the instances of their classes is a new finding.

```
FIX-OK
```

or `FIX-INCOMPLETE`, followed by every finding still open and every new one, in the finding format above. A verify verdict may stand alone, continue with whitespace and detail, or have exactly one of `.`, `:`, `;` or `,` immediately after its name, followed by whitespace and optional detail or the end of the line.

## Answering the findings

When you own the change under review, every finding ends **fixed** or **refuted** with evidence: a test, a doc line, a command's output. Sort each before acting:

- A defect the diff shows: fix it.
- A hypothetical ("what if this is null?"): trace the call site. Fix it when a real caller reaches it; refute it citing the call site when none does.
- A preference with no concrete failure ("I'd have structured this differently"): refute it, naming the failure it lacks.
- A report made only of nits reads as a pass: answer each nit in a line.

A fix's diff gets a scoped verify: each finding checked as fixed, and the repair checked for new problems. The full review does not rerun.
