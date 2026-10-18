# Findings for PR #<n>, reviewed head <sha>

One entry per finding raised since the reviewed head, earlier rounds' included; the verify reads each against the whole range. An entry starts with the one-line finding as `code-review` defines it, so `^P[123] ` finds it, and its detail follows as bullets:

```
P1 <file:line> — <defect> — <fix>
- Source: <review axis and comment link, or the CI job and log line>
- Evidence: <for a CI failure, the failing line; for a refuted finding, the fix worker's `refuted: <evidence>` line, copied>
```

A file with no open finding holds the single line `no open findings`.
