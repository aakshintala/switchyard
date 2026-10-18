Write the implementation plan for issue #__ISSUE__ in __REPO__. Do not delegate further.

Follow `~/.agents/skills/planning/SKILL.md` steps 1 and 2 and the project's workflow doc (__WORKFLOW_DOC__), which wins where it speaks. Read the ticket (`gh issue view __ISSUE__ --repo __REPO__ --comments`), the preflight report (`__PREFLIGHT__`; `none` when the preflight was skipped) and the pack (`__PACK__`) first, then the code at __BASE__, in your working directory. Gather in batches: put every grep, `git show` range and `sed` slice one question needs into a single Bash call.
__EXTRA__

## Rules

- Your working directory stays unedited: the one file you write is the plan. The lane builds and runs tests; you build only in a scratch copy of __BASE__ (outside the working directory), and only for the Files sweep that step 2 calls for.
- Step 2's rules on `core` rulings and on a ticket's stated behaviour bind you: a doc-reading choice is `core`, and no stated behaviour is deferred.
- You stop at a blocked seam, or a `core` item the preflight missed: end the plan file with a `Blocked` section (the seam or item, the options, a recommendation) and write no task past it.

## Plan file

Write the plan to `__PLAN__`, with every section step 2 lists under its own heading.

## Report

The plan file's path, the rung you chose, and each `core` ruling in one line. End with a STATUS line.
