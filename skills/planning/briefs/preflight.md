Doc preflight for issue #__ISSUE__ in __REPO__. Do not edit anything. Do not delegate further.

Read #__ISSUE__ (`gh issue view __ISSUE__ --repo __REPO__ --comments`), spec #__SPEC__ (`gh issue view __SPEC__ --repo __REPO__ --comments`), and the project's workflow doc (__WORKFLOW_DOC__). Then read the code at __BASE__, in your working directory, that #__ISSUE__ touches: the files it names, their callers, and their tests.

List, max 250 words, one line each:
1. Contradictions between #__ISSUE__, #__SPEC__, the workflow doc and the code, including a site, flag, command or field #__ISSUE__ names that the code at __BASE__ lacks or has changed: ticket bodies go stale.
2. Defaults or formats #__ISSUE__ leaves unstated that the implementer must pick.
3. Failure cases with no stated behaviour.
4. Acceptance criteria that fight the spec or the code.
5. Open PRs that change the same files: compare each path over REST, which spares the GraphQL rate limit: list them with `gh api "repos/__REPO__/pulls?state=open&per_page=100" -q '.[].number'`, then read each one's paths with `gh api "repos/__REPO__/pulls/<n>/files?per_page=100" -q '.[].filename'`.

Tag a line `core` only when it touches the ticket's core outcome and nothing settles or delegates it; tag every other line `non-blocking`. A choice the ticket hands to the plan, one the spec or project docs answer, and one with a cheap reversible default are all `non-blocking`. Give each line your recommended ruling in a few words, preferring the smallest change. Then list every file the plan's author must read, one path per line. End with a STATUS line.
