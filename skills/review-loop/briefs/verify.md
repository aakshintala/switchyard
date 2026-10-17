Scoped verify of the repair on PR #__PR__ in __REPO__. Do not edit, push or comment. Do not delegate further.

Follow the scoped-verify mode of `__SKILLS__/code-review/SKILL.md`. Your working directory is a checkout of the PR head; the repair diff is `git diff __SINCE__..HEAD`. The findings it answers:

__FINDINGS__

A repair that detects a bad state at entry (a drift or precondition check) and stops there fixes a finding about detection; a finding about recovering from that state stays open until a path recovers.

Max 150 words. End with exactly `FIX-OK` when every finding is fixed or refuted, else `FIX-INCOMPLETE` followed by every still-open and every new finding in the finding format, then a STATUS line.
