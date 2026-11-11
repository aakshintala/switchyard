---
name: retro
description: "Conduct a retrospective on a coding session or a flywheel round, and file the durable lessons. Use when asked for a retro, or when a flywheel round closes."
---

The user has asked for a **retrospective**. You are suggesting improvements to the coding agent's **environment** to improve future runs.

## Steps

### 1. Load the style guide

Call the Skill tool with `writing-for-agents`.

### 2. Gather evidence

Read the primary sources for the session or round the user names, defaulting to the current one. After a flywheel round or an `implement` run, read where the lessons happened: the lanes' **Friction** bullets, the rulings made mid-lane, and the review and verify rounds on each PR.

Done when every lane, ruling and verify round in scope has been read.

### 3. Find candidates

Look in these categories:

- **Navigation**: how easy was it for the agent to find the right files? Are there hidden dependencies between files? Would a **navigation pointer** make it easier? _Use when_ the session took a long time to find a piece of information.
- **Automated checks**: are there automated checks that could catch errors the agent made? Pick the strongest that fits: a type that cannot hold the bad value, then a lint or test that fails CI, then one shared helper every caller uses, then a runtime check. Agents copy the guard the surrounding code uses, so a weak one spreads. _Use when_ the agent made a mistake that could have been caught by an automated check.
- **Tools**: did the agent build a one-off rig (a fake, a harness, a repro script) that the next run will rebuild? Propose committing it as a tool, with the prose that points at it. _Use when_ the session spent turns on setup by hand.
- **Coding standards**: should the **reviewer agent** be given a new rule to enforce? Should an existing rule be removed or clarified? _Use when_ the reviewer agent failed to catch a mistake.
- **Global AGENTS.md**: are there any steering instructions that should be moved to coding standards (or automated checks) instead? _Use when_ the AGENTS.md file is particularly large - in the repo OR the user's global scope.
- **Tool economy**: did the agent make expensive tool calls that could be streamlined? Is there any custom tooling (CLI's, MCP's) that is particularly token-inefficient? _Use when_ the agent made an expensive tool call.
- **No-ops**: look for instructions in steering files that don't modify the agent's behavior. _Use when_ the steering files are large and unwieldy.
- **Information access**: look for opportunities to increase the agent's access to information. Teeing dev server logs, readonly access to third-party services. _Use when_ a crucial piece of information was not available to the agent.

Done when every category has been checked against the evidence.

### 4. Keep only lessons

One-offs are not lessons. Keep a candidate only when it is durable (it will recur), decision-changing (it would change what an agent does), about a skill or doc that actually ran, and not already covered. Then sort what's left:

- **Mechanical**: the failure has one correct check. Turn it into an automated check, not prose.
- **Judgement**: the failure needs a call. Write it as prose in the one right place.

A repo with no guardrail at all where one failed (no CI, no lint, no tests on the failing path) is itself a finding.

Done when every surviving lesson is tagged mechanical or judgement.

### 5. Route

One rule decides where each lesson lands:

- A check or an environment change goes to the repo where the failure happened.
- A change to how one project works goes to that project's workflow doc.
- Anything else goes to switchyard.

### 6. File

When the owner is present, present the lessons in chat, most severe first, and let them reshape each one.

When the owner is away:

1. Read the "Dropped lessons" section of the wiki's retro page (`~/work/wiki/pages/flywheel-friction-and-retro.md`). A lesson listed there is a second sighting: carry both sightings into what you file.
2. A lesson the owning role will fund this week becomes an ordinary issue in the destination repo right away, through normal triage, with a priority and the evidence. A mechanical lesson the owning role can make within the round becomes a PR instead.
3. A lesson nobody funds this week is dropped, not parked: add one line under "Dropped lessons" with the lesson, the date and the round.
4. A lesson about data loss, or a destructive or out-of-scope edit, becomes a PR on its first sighting.

Do not use a holding label such as `retro-candidate`; it was retired on 2026-11-11.

Every retro PR opens with its evidence and its destination, so the owner can decide without reading the diff.

Done when every lesson is presented, filed as an issue or PR, or dropped with its line.

## Reference

### Implementation vs Review

Remember that all work goes through two stages: implementation and review. The implementation agent has the most **context pressure**. They are responsible for exploration, writing code, and debugging failures.

The review agent has the least context pressure - it receives a diff, so no exploration needed. It often does not need to write code or debug.

This means that the review agent should be responsible for imposing coding standards, not the implementation agent.

### Files

You have access to several files in the repo:

- `CLAUDE.md`/`AGENTS.md`: these files are pushed to the context window of any agent working in this repo. They should be used incredibly sparingly, usually only for **navigation pointers** to other files.
- `CODING_STANDARDS.md`, or the standards doc the repo's `AGENTS.md` or `CLAUDE.md` indexes: read during review, not implementation. Add **navigation pointers** to docs folders if the standards file gets more than 1,000 lines long.
- Docs: use docs as references files, pointed to by other files. Look for existing docs before writing new ones.
- Skills: use skills for docs (since their description goes into the agent's context window), or for user-invoked commands. Follow the advice in the `writing-for-agents` skill.
