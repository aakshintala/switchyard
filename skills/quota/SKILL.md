---
name: quota
description: Quota left on the AI subscriptions (Claude, Codex, Cursor, OpenCode Go, Muse), read live from QuotaBar. Use when asked how much quota remains or when it resets, or when a pick rule needs headroom.
---

# Quota

Run the script; it prints one line per provider:

```bash
~/.agents/bin/quota          # claude [healthy]: Session 94% (Resets in 2h), Weekly 82% (Resets in 6d), ...
~/.agents/bin/quota --json   # the raw feed, for fields the lines hide: resetsAt, unitsUsed, balanceCap
```

Done when every enabled provider has a line. The feed refreshes before it answers, so a run can take up to 20 s.

Exit 1 means QuotaBar is not running or its feed is off: report the message the script prints.

## Reading it

**`status`** (`healthy`, `warning`, `critical`, `depleted`) is pace-aware: it weighs the percent left against the time left until reset. A low percent that will last to the reset is `healthy`, so judge urgency by `status` over the raw percent.
