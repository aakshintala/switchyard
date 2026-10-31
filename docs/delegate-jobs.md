# Delegate job records

`cancel`, `status`, `watch`, `resume` and `bin/job-record` use the same lookup order. The first regular record file wins.

## Lookup order

Readers check these sources in order:

1. `DELEGATE_JOBS_DIR`, when it is set and non-empty.
2. The caller's `$TMPDIR/delegate-jobs` (the OS temp directory when `TMPDIR` is unset).
3. `/tmp/delegate-jobs`.
4. The per-user locator for the job ID.

The locator fills misses only. An earlier regular file stays the winner, even if later reading or parsing fails.

When no source contains a regular record, the command reports `unknown job <id>` and lists the directories it searched. If a locator names a missing record, the diagnostic also lists that record's parent directory.

## Empty and relative override

An empty `DELEGATE_JOBS_DIR` is ignored. A relative value resolves against the caller's current directory. For example, a caller in `/jobs/cwd` with `DELEGATE_JOBS_DIR=relative/dir` searches `/jobs/cwd/relative/dir` first.

## Duplicate directories

The three legacy directories are searched once when two sources name the same directory. The first position wins. If `DELEGATE_JOBS_DIR` equals the caller's `$TMPDIR/delegate-jobs`, the list is that directory, then `/tmp/delegate-jobs`, then the locator.

## Locator format and lifecycle

Each job has one locator at `${XDG_CACHE_HOME:-$HOME/.cache}/delegate/locators/<job ID>`. `XDG_CACHE_HOME` must be absolute. An empty or relative value uses `$HOME/.cache`.

The locator contains one absolute record path as plain text, followed by a newline. Spaces are preserved. Readers also accept the path without its final newline. Empty, relative or multiline values are invalid.

The supervisor publishes the locator atomically before dispatching the agent or writing the first `RUNNING` record. This does not move the record or change its JSON format. A cache write failure stops startup. A record path containing a newline cannot be represented, so the supervisor skips its locator and keeps the existing record placement.

Missing, unreadable or malformed locators are lookup misses. A valid locator whose target is missing or not a regular file is also a miss. Old records without locators remain readable through the legacy directories; there is no migration. The tool does not expire locators or run a global cleanup sweep.

## Writers

New records stay in the writer directory (`jobs_dir` / `job_record_path`): `DELEGATE_JOBS_DIR` when set, resolved as above, else the supervisor's `$TMPDIR/delegate-jobs`. The locator does not change new-record placement.

Updates, including cancel and dead-supervisor fallbacks, write to the path where the reader found the record (`record_path`). They fall back to `job_record_path` when no record exists. Resume reads the old record through the same lookup and links the new record to it.

`bin/job-record <id>` uses this same order and prints the winning path. It does not need the delegate binary or a JSON parser.
