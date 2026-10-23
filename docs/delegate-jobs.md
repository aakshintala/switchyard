# Delegate jobs directory

How `cancel`, `watch`, and `resume` find job records on disk.

## Lookup order

`cancel`, `watch`, and `resume` search these directories in order and the
first hit wins:

1. `DELEGATE_JOBS_DIR`, when set (see below).
2. The caller's `$TMPDIR/delegate-jobs` (the OS temp directory when `TMPDIR`
   is unset).
3. `/tmp/delegate-jobs`.

When no searched directory holds `<jobId>.json`, the command fails with
`unknown job <id>` and lists every directory searched.

## Empty and relative override

An empty `DELEGATE_JOBS_DIR` is ignored. A relative `DELEGATE_JOBS_DIR`
resolves against the caller's current directory: a caller that runs from
`/jobs/cwd` with `DELEGATE_JOBS_DIR=relative/dir` searches
`/jobs/cwd/relative/dir` first.

## Duplicates

When two sources name the same directory, it is searched once, at its first
position. For example, when `DELEGATE_JOBS_DIR` already equals the caller's
`$TMPDIR/delegate-jobs`, the search list is that directory followed by
`/tmp/delegate-jobs`.

## Writers

New records are created only under the supervisor's `$TMPDIR/delegate-jobs`
(`jobs_dir` / `job_record_path`); `DELEGATE_JOBS_DIR` is read-side only.
Updates (`cancel` finalizing a record, the supervisor-died and cancelled
fallbacks) write back to the path where the record was found (`record_path`),
falling back to `job_record_path` when no record exists.
