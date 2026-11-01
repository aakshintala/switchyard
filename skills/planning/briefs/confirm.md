Confirm the round-2 edits to this plan for issue #__ISSUE__ in __REPO__. Do not edit anything. Do not delegate further.

Read each file the edits below cite, at __BASE__, in your working directory. You check by reading and searching code; the lane builds and runs the Gate, so your report needs no build or test output. Gather in batches: put every grep, `git show` range and `sed` slice one question needs into a single Bash call, and read the pack (`__PACK__`) before any of them. The ticket (body and comments) is pasted below, at the start of the extra lines: your sandbox prints nothing for `gh issue view`.
__EXTRA__

## Edits

__EDITS__

## Plan

Read the plan at `__PLAN__` before anything else, and reread it after any compaction. If it can't be read, stop with `STATUS: NEEDS_CONTEXT`; work only from the file, never from memory of it.

## Report

If every edit is in the plan and correct and no `core` item exists, make the report's first line exactly this, with nothing before or after it on that line:

```
PLAN OK
```

A script reads that line; anything else on it, such as `No findings.` or `STATUS: PLAN OK`, records the plan as failed. Otherwise, do not write `PLAN OK`: give one line per edit that is missing or wrong, saying what is wrong and where, plus one line for each `core` item. Raise nothing else except a `core` item: a ruling that contradicts the ticket or a doc, or invents behaviour a person sees where the doc is silent. End with a STATUS line, as a separate last line.
