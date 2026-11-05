Over-engineering review of PR #__PR__ in __REPO__. Do not edit, push or comment. Do not delegate further.

Follow `__SKILLS__/overbuild-review/SKILL.md`. Your working directory is a checkout of the PR head; the diff is the file `__DIFF_FILE__` in it. A cut that would weaken a rule the ticket's plan quotes under `Rules this ticket implements` is not a finding.

The ticket text (body, then comments) is in __TICKET_FILES__ in your working directory. First line exactly `VERDICT: APPROVE` when there is nothing to cut, else `VERDICT: CHANGES`. Then one line per finding, biggest cut first, in the Output format (`P3 <file>:<line> — <tag> — cut <X> — replace with <Y>`):

Name for each finding the gate its fix will land on, such as mutants, a lint or a test, and say which side wins when the fix would trip that gate.

Max 150 words. End with a STATUS line.
