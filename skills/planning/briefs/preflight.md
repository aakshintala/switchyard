Doc preflight for issue #__ISSUE__ in __REPO__. Do not edit anything. Do not delegate further.

Read #__ISSUE__ and spec #__SPEC__, each body and then its comments (`gh issue view <n> --repo __REPO__`, then the same with `--comments`, which prints no body). Read the project's workflow doc (__WORKFLOW_DOC__). Then read the code at __BASE__, in your working directory, that #__ISSUE__ touches: the files it names, their callers, and their tests. You check by reading and searching; the lane builds and runs the tests, so your list needs no build or test output. Gather in batches: put every grep, `git show` range and `sed` slice one question needs into a single Bash call, and read the pack (`__PACK__`) before any of them.

List, max 250 words, one line each:
1. Contradictions between #__ISSUE__, #__SPEC__, the workflow doc and the code, including a site, flag, command or field #__ISSUE__ names that the code at __BASE__ lacks or has changed: ticket bodies go stale.
2. Defaults or formats #__ISSUE__ leaves unstated that the implementer must pick.
3. Failure cases with no stated behaviour.
4. Acceptance criteria that fight the spec or the code.
5. Open PRs that change the same files: compare each path over REST, which spares the GraphQL rate limit: list them with `gh api --paginate "repos/__REPO__/pulls?state=open&per_page=100" -q '.[].number'`, then read each one's paths with `gh api --paginate "repos/__REPO__/pulls/<n>/files?per_page=100" -q '.[].filename'`.

Start each finding line with its tag, `core` or `non-blocking`. A line with nothing to report ends at the nil word (`- core: none`), with any reason on the next line. Tag a line `core` only when it touches the ticket's core outcome and its answer depends on something outside the repository: someone's intent, a budget, or a doc that must change. Tag every other line `non-blocking`. A choice the ticket hands to the plan, one the ticket's goal, the spec, the project docs or the code answer, and one with a cheap reversible default are all `non-blocking`. Severity alone never makes a line `core`. Give each line your recommended ruling in a few words, preferring the smallest change, and on a `non-blocking` line cite what settles it: the ticket's goal, a doc line or a code line. Then sweep, so the plan's Files fence holds every consumer: for each type, variant, field, function, signature, command or path #__ISSUE__ changes, deletes or moves, grep the whole tree at __BASE__, tests, examples, benches, build scripts and docs included, and every module that reaches a moved name through a `use` or re-export (it never writes the name you grep). List every file with a hit, one path per line, marked `writes` when the change must edit it (every hit of a deleted, renamed or moved item does) or `reads` when the plan's author must only read it, with the grep you ran above the list. Mark each hit from its lines in the file, read yourself; a summary or a subagent's table is a lead to read, never a mark. Grep tests, benches and snapshots for each output text #__ISSUE__ changes, by its old text, and mark each hit `writes`. When #__ISSUE__ names a fence, name each function the change must edit outside it. End with a STATUS line. Reply with the list and write no file: whoever started you saves your reply.

Just before the STATUS line, put exactly these two field lines, in this order, with n as a decimal count. The STATUS line stays last.

Core items: <n>
Non-blocking items: <n>

Do not count a core item that a ruling (in the issue comments or a resolution the brief carries) already settles. The two lines are what tkt-start reads, so they must match the items listed above.
