---
name: overbuild-review
description: >
  Over-engineering review of a diff: what to delete, or replace with stdlib or
  a native feature. Use when asked to review for over-engineering, or what a
  change could cut. Reports only; applies nothing.
---

<!-- Adapted from DietrichGebert/ponytail 4.9.0 (MIT, see LICENSE). -->

Review the diff for complexity it doesn't need. The diff's best outcome is getting shorter. Every finding is a hypothesis: the implementer applies it only when the cut costs no memory, behaviour or lines.

## Tags

- `delete:` dead code, unused flexibility, speculative feature. Replacement: nothing.
- `stdlib:` hand-rolled thing the standard library ships. Name the function.
- `native:` dependency or code doing what the platform already does. Name the feature.
- `yagni:` abstraction with one implementation, config nobody sets, layer with one caller.
- `shrink:` same logic, fewer lines. Show the shorter form.

## Output

First line: `VERDICT: APPROVE` when there is nothing to cut, else `VERDICT: CHANGES`. Then one line per finding, biggest cut first:

`P3 <file>:<line> — <tag> — cut <X> — replace with <Y>`

- ✅ `P3 src/email.py:12 — stdlib — cut 27-line validator class — replace with "@" in email; the confirmation mail is the real check`
- ✅ `P3 src/date.ts:4 — native — cut moment.js for one format call — replace with Intl.DateTimeFormat`
- ✅ `P3 repo.py:88 — yagni — cut AbstractRepository with one implementation — replace with the implementation, inlined`
- ❌ "This class might be more complex than necessary; have you considered whether all these rules are needed?"

A finding names a concrete cut: duplication at named sites, code with no caller, or the shorter form shown. "Could be shorter" with no named cut is not written. A concrete finding blocks like any other.

End with `net: -<N> lines possible.`

## Scope

Over-engineering only. Send correctness, security and performance to `code-review`. A smoke test or an `assert`-based self-check is the required minimum, never bloat.
