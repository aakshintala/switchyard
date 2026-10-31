use crate::types::PollResult;
use crate::util::{json_compact, random_uuid};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub trait StatusRecordWriter: Send + Sync {
    fn write(&self, job_id: &str, record: &PollResult);
}

/// Delegate's state directory: job records, gate logs, and the `cargo-mutants`
/// shim (`shim/`) every job's `PATH` starts with (#435). An explicit
/// `DELEGATE_JOBS_DIR` override wins, so the switchyard operator's setting on
/// the box reaches the records supervisors write (#386); otherwise the
/// supervisor's `$TMPDIR/delegate-jobs`.
pub fn jobs_dir() -> PathBuf {
    let cwd = std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir());
    writer_dir_from(
        &std::env::var_os("DELEGATE_JOBS_DIR"),
        &std::env::temp_dir(),
        &cwd,
    )
}

/// The writer side of the lookup rule: the resolved `DELEGATE_JOBS_DIR` when
/// set and non-empty, else `tmp/delegate-jobs`. A relative override resolves
/// against the caller's current directory, exactly like the lookup's first
/// entry, so writers and readers agree on one rule.
fn writer_dir_from(over: &Option<std::ffi::OsString>, tmp: &Path, cwd: &Path) -> PathBuf {
    if let Some(o) = over
        && !o.is_empty()
    {
        let p = PathBuf::from(&o);
        return if p.is_absolute() { p } else { cwd.join(p) };
    }
    tmp.join("delegate-jobs")
}

/// Status JSON for one job in the writer directory (`jobs_dir`).
/// Readers find it through the legacy directories or the job's per-user locator.
pub fn job_record_path(job_id: &str) -> PathBuf {
    jobs_dir().join(format!("{job_id}.json"))
}

/// Every directory a job record could live in: an explicit `DELEGATE_JOBS_DIR`
/// override first, then the caller's `$TMPDIR/delegate-jobs`, then the
/// system `/tmp/delegate-jobs`. The override is dropped when empty; a
/// relative override resolves against the caller's current directory.
/// Duplicates are removed, keeping the first position. Never empty.
pub fn search_dirs() -> Vec<PathBuf> {
    let cwd = std::env::current_dir().unwrap_or_else(|_| std::env::temp_dir());
    dirs_from(
        std::env::var_os("DELEGATE_JOBS_DIR"),
        &std::env::temp_dir(),
        &cwd,
    )
}

fn dirs_from(over: Option<std::ffi::OsString>, tmp: &Path, cwd: &Path) -> Vec<PathBuf> {
    let mut dirs = vec![writer_dir_from(&over, tmp, cwd)];
    if over.as_ref().is_some_and(|o| !o.is_empty()) {
        dirs.push(tmp.join("delegate-jobs"));
    }
    dirs.push(PathBuf::from("/tmp/delegate-jobs"));
    let mut seen = std::collections::HashSet::new();
    dirs.retain(|d| seen.insert(d.clone()));
    dirs
}

/// The first regular-file hit in the legacy directories, then the job's locator.
/// `None` for an empty id or one holding a path separator, which must never
/// reach a path join.
pub fn find_record_path(job_id: &str) -> Option<PathBuf> {
    find_record_path_with_locator(job_id, &search_dirs(), || locator_record_path(job_id))
}

fn valid_job_id(job_id: &str) -> bool {
    !job_id.is_empty() && !job_id.contains('/')
}

fn find_in_dirs(job_id: &str, dirs: &[PathBuf]) -> Option<PathBuf> {
    if !valid_job_id(job_id) {
        return None;
    }
    dirs.iter()
        .map(|d| d.join(format!("{job_id}.json")))
        .find(|p| p.is_file())
}

fn find_record_path_with_locator(
    job_id: &str,
    dirs: &[PathBuf],
    locator: impl FnOnce() -> Option<PathBuf>,
) -> Option<PathBuf> {
    if !valid_job_id(job_id) {
        return None;
    }
    find_in_dirs(job_id, dirs).or_else(|| locator().filter(|path| path.is_file()))
}

fn locator_cache_root_from(
    xdg: Option<&std::ffi::OsStr>,
    home: Option<&std::ffi::OsStr>,
) -> Option<PathBuf> {
    if let Some(xdg) = xdg.filter(|path| !path.is_empty()) {
        let path = PathBuf::from(xdg);
        if path.is_absolute() {
            return Some(path);
        }
    }
    let home = PathBuf::from(home?);
    home.is_absolute().then(|| home.join(".cache"))
}

fn locator_path_from(
    job_id: &str,
    xdg: Option<&std::ffi::OsStr>,
    home: Option<&std::ffi::OsStr>,
) -> Option<PathBuf> {
    if !valid_job_id(job_id) {
        return None;
    }
    Some(
        locator_cache_root_from(xdg, home)?
            .join("delegate/locators")
            .join(job_id),
    )
}

/// The per-user path where one job's locator is stored. Invalid ids or an
/// unavailable absolute cache root are lookup misses.
pub(crate) fn locator_path(job_id: &str) -> Option<PathBuf> {
    let xdg = std::env::var_os("XDG_CACHE_HOME");
    let home = std::env::var_os("HOME");
    locator_path_from(job_id, xdg.as_deref(), home.as_deref())
}

fn parse_locator_target(contents: &str) -> Option<PathBuf> {
    let target = contents.strip_suffix('\n').unwrap_or(contents);
    if target.is_empty() || target.contains('\n') {
        return None;
    }
    let path = PathBuf::from(target);
    path.is_absolute().then_some(path)
}

/// Read and validate a locator without requiring its target to still exist.
/// A stale target remains available for the unknown-job diagnostic.
pub(crate) fn locator_record_path(job_id: &str) -> Option<PathBuf> {
    let path = locator_path(job_id)?;
    let contents = fs::read_to_string(path).ok()?;
    parse_locator_target(&contents)
}

/// Publish the absolute record path once before the supervisor dispatches the job.
pub(crate) fn write_locator(job_id: &str) -> std::io::Result<()> {
    if !valid_job_id(job_id) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "invalid job id",
        ));
    }
    let record = job_record_path(job_id);
    let record = if record.is_absolute() {
        record
    } else {
        std::env::current_dir()?.join(record)
    };
    let target = record.to_str().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "job record path is not valid UTF-8",
        )
    })?;
    if target.contains('\n') {
        return Ok(());
    }
    let locator = locator_path(job_id).ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "unavailable absolute cache root",
        )
    })?;
    let contents = format!("{target}\n");
    if parse_locator_target(&contents).as_ref() != Some(&record) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "job record path does not round-trip through locator format",
        ));
    }
    write_atomic(&locator, &contents)
}

/// Writers only: the found path, else `job_record_path` when no record exists.
pub fn record_path(job_id: &str) -> PathBuf {
    find_record_path(job_id).unwrap_or_else(|| job_record_path(job_id))
}

pub struct FileStatusRecordWriter;

impl StatusRecordWriter for FileStatusRecordWriter {
    fn write(&self, job_id: &str, record: &PollResult) {
        let _ = write_atomic(&job_record_path(job_id), &json_compact(record));
    }
}

/// Write to a unique tmp sibling, then rename over `path`, so readers never see a partial file.
pub fn write_atomic(path: &Path, contents: &str) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{}.tmp", random_uuid()));
    fs::write(&tmp, contents)
        .and_then(|_| fs::rename(&tmp, path))
        .inspect_err(|_| {
            let _ = fs::remove_file(&tmp);
        })
}

pub fn file_status_record_writer() -> FileStatusRecordWriter {
    FileStatusRecordWriter
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliResume {
    pub model: String,
    pub backend: Option<String>,
    pub cwd: String,
    pub session_id: Option<String>,
    pub gate: String,
    #[serde(serialize_with = "crate::util::js_num_opt")]
    pub tool_idle_ms: Option<f64>,
    #[serde(serialize_with = "crate::util::js_num_opt")]
    pub idle_ms: Option<f64>,
    #[serde(serialize_with = "crate::util::js_num_opt")]
    pub wall_ms: Option<f64>,
}

/// `PollResult` plus what a watcher needs to find and resume the job, plus the resume
/// chain links: `resumedFrom` (this job continues that one) and `supersededBy` (written
/// into the old record once the new job is spawned).
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliRecord {
    #[serde(flatten)]
    pub poll: PollResult,
    pub supervisor_pid: u32,
    pub resume: CliResume,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resumed_from: Option<String>,
}

/// Writes the CLI record for the one job this supervisor runs. A failed write exits the
/// supervisor: the file is the only truth, so a job that cannot report is not worth running.
/// ponytail: the agent child is orphaned on that exit; `watch` reports the dead supervisor.
pub struct CliRecordWriter {
    pub job_id: String,
    pub model: String,
    pub backend: Option<String>,
    pub cwd: String,
    pub gate: String,
    pub tool_idle_ms: Option<f64>,
    pub idle_ms: Option<f64>,
    pub wall_ms: Option<f64>,
    pub resumed_from: Option<String>,
    pub last_session_id: Mutex<Option<String>>,
}

impl StatusRecordWriter for CliRecordWriter {
    fn write(&self, _registry_id: &str, record: &PollResult) {
        let mut poll = record.clone();
        if let PollResult::Terminal { result, .. } = &mut poll {
            result.job_id = Some(self.job_id.clone());
        }
        let current_session_id = match &poll {
            PollResult::Running { progress, .. } => progress.session_id.clone(),
            PollResult::Terminal { result, .. } => result.session_id.clone(),
            PollResult::NotFound { .. } => None,
        };
        let session_id = {
            let mut last = self
                .last_session_id
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            if current_session_id.is_some() {
                *last = current_session_id;
            }
            last.clone()
        };
        let rec = CliRecord {
            poll,
            supervisor_pid: std::process::id(),
            resume: CliResume {
                model: self.model.clone(),
                backend: self.backend.clone(),
                cwd: self.cwd.clone(),
                session_id,
                gate: self.gate.clone(),
                tool_idle_ms: self.tool_idle_ms,
                idle_ms: self.idle_ms,
                wall_ms: self.wall_ms,
            },
            resumed_from: self.resumed_from.clone(),
        };
        let path = job_record_path(&self.job_id);
        let res = write_atomic(&path, &json_compact(&rec));
        if let Err(e) = res {
            eprintln!("cannot write status record {}: {e}", path.display());
            std::process::exit(1);
        }
    }
}

/// A RUNNING record whose supervisor is gone. Keeps resume so a later command can still
/// see what the job was; the result text is the whole reason.
pub fn write_supervisor_died(job_id: &str, prior: &serde_json::Value) -> std::io::Result<()> {
    let mut rec = prior.clone();
    let Some(obj) = rec.as_object_mut() else {
        return Err(std::io::Error::other("status record is not an object"));
    };
    obj.insert("status".into(), "ERROR".into());
    obj.remove("lastHeartbeatAt");
    obj.remove("progress");
    let resume = &prior["resume"];
    obj.insert(
        "result".into(),
        serde_json::json!({
            "status": "ERROR",
            "text": "supervisor died",
            "sessionId": resume["sessionId"].clone(),
            "backend": resume["backend"].clone(),
            "model": resume["model"].as_str().unwrap_or(""),
            "usage": null,
            "costUsd": null,
            "costEstimated": false,
            "durationMs": null,
            "jobId": job_id,
        }),
    );
    write_atomic(&record_path(job_id), &json_compact(&rec))
}

/// A RUNNING record whose supervisor is gone or had to be SIGKILLed: nobody is left to
/// finalize, so `cancel` writes the CANCELLED terminal record itself.
pub fn write_cancelled(job_id: &str, prior: &serde_json::Value) -> std::io::Result<()> {
    let mut rec = prior.clone();
    let Some(obj) = rec.as_object_mut() else {
        return Err(std::io::Error::other("status record is not an object"));
    };
    let resume = &prior["resume"];
    let session_id = resume["sessionId"].clone();
    let backend = resume["backend"].clone();
    let model = resume
        .get("model")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_string();
    obj.insert("status".into(), "CANCELLED".into());
    obj.remove("lastHeartbeatAt");
    obj.remove("progress");
    obj.insert(
        "result".into(),
        serde_json::json!({
            "status": "CANCELLED",
            "text": "Cancelled by user.",
            "sessionId": session_id,
            "backend": backend,
            "model": model,
            "usage": null,
            "costUsd": null,
            "costEstimated": true,
            "durationMs": null,
            "jobId": job_id,
        }),
    );
    write_atomic(&record_path(job_id), &json_compact(&rec))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn written_record(id: &str) -> serde_json::Value {
        serde_json::from_str(&fs::read_to_string(job_record_path(id)).unwrap()).unwrap()
    }

    #[test]
    fn locator_cache_selection_uses_absolute_xdg_or_home_fallback() {
        use crate::test_env::EnvGuard;
        let _env = crate::test_env::lock();
        let home = std::env::temp_dir().join(format!("delegate-locator-home-{}", random_uuid()));
        let cache = std::env::temp_dir().join("cache root with spaces");
        let _home = EnvGuard::set("HOME", home.to_str().unwrap());
        let _unset = EnvGuard::remove("XDG_CACHE_HOME");
        let expected = home.join(".cache/delegate/locators/job-id");
        assert_eq!(locator_path("job-id"), Some(expected.clone()));
        {
            let _empty = EnvGuard::set("XDG_CACHE_HOME", "");
            assert_eq!(locator_path("job-id"), Some(expected.clone()));
        }
        {
            let _relative = EnvGuard::set("XDG_CACHE_HOME", "relative/cache");
            assert_eq!(locator_path("job-id"), Some(expected));
        }
        {
            let _absolute = EnvGuard::set("XDG_CACHE_HOME", cache.to_str().unwrap());
            assert_eq!(
                locator_path("job-id"),
                Some(cache.join("delegate/locators/job-id"))
            );
        }
        assert_eq!(locator_path(""), None);
        assert_eq!(locator_path("a/b"), None);
    }

    #[test]
    fn locator_contents_require_one_absolute_path_line_and_keep_spaces() {
        let path = PathBuf::from("/home/operator/cache root/jobs/job-id.json");
        assert_eq!(
            parse_locator_target(path.to_str().unwrap()),
            Some(path.clone())
        );
        assert_eq!(
            parse_locator_target(&format!("{}\n", path.display())),
            Some(path)
        );
        for invalid in ["", "relative/job.json", "/jobs/a\n/jobs/b", "/jobs/a\n\n"] {
            assert_eq!(parse_locator_target(invalid), None, "{invalid:?}");
        }
    }

    #[test]
    fn locator_publication_is_absolute_and_keeps_each_job_separate() {
        use crate::test_env::EnvGuard;
        let _env = crate::test_env::lock();
        let root = std::env::temp_dir().join(format!("delegate-locator-{}", random_uuid()));
        let cache = root.join("cache root");
        let jobs = root.join("jobs root");
        let _home = EnvGuard::set("HOME", root.to_str().unwrap());
        let _xdg = EnvGuard::set("XDG_CACHE_HOME", cache.to_str().unwrap());
        let _jobs = EnvGuard::set("DELEGATE_JOBS_DIR", jobs.to_str().unwrap());
        let first = random_uuid();
        let second = random_uuid();
        let first_record = jobs.join(format!("{first}.json"));
        let first_locator = cache.join("delegate/locators").join(&first);
        write_locator(&first).unwrap();
        assert_eq!(
            fs::read_to_string(&first_locator).unwrap(),
            first_record.display().to_string() + "\n"
        );
        assert_eq!(locator_record_path(&first), Some(first_record.clone()));
        assert_eq!(find_record_path(&first), None, "a stale target is a miss");
        fs::create_dir_all(first_record.parent().unwrap()).unwrap();
        fs::write(&first_record, "{}").unwrap();
        assert_eq!(find_record_path(&first), Some(first_record.clone()));

        write_locator(&second).unwrap();
        assert_eq!(
            fs::read_to_string(&first_locator).unwrap(),
            first_record.display().to_string() + "\n",
            "publishing a second job does not overwrite the first locator"
        );
        assert_eq!(
            fs::read_to_string(cache.join("delegate/locators").join(&second)).unwrap(),
            jobs.join(format!("{second}.json")).display().to_string() + "\n"
        );

        let relative_jobs = PathBuf::from(format!("relative-jobs-{}", random_uuid()));
        let relative_id = random_uuid();
        let _relative = EnvGuard::set("DELEGATE_JOBS_DIR", relative_jobs.to_str().unwrap());
        write_locator(&relative_id).unwrap();
        assert_eq!(
            fs::read_to_string(cache.join("delegate/locators").join(&relative_id)).unwrap(),
            std::env::current_dir()
                .unwrap()
                .join(relative_jobs)
                .join(format!("{relative_id}.json"))
                .display()
                .to_string()
                + "\n",
            "a relative record directory is published as an absolute path"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn newline_record_path_skips_locator_publication_without_truncation() {
        use crate::test_env::EnvGuard;
        let _env = crate::test_env::lock();
        let root = std::env::temp_dir().join(format!("delegate-locator-newline-{}", random_uuid()));
        let jobs = root.join("jobs\nwith-newline");
        let _home = EnvGuard::remove("HOME");
        let _xdg = EnvGuard::set("XDG_CACHE_HOME", "relative-cache");
        let _jobs = EnvGuard::set("DELEGATE_JOBS_DIR", jobs.to_str().unwrap());
        let id = random_uuid();
        write_locator(&id).unwrap();
        assert!(
            !root
                .join("relative-cache/delegate/locators")
                .join(&id)
                .exists(),
            "no truncated locator is written for a newline-containing target"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn locator_lookup_waits_for_legacy_hits_and_requires_regular_files() {
        let root = std::env::temp_dir().join(format!("delegate-locator-order-{}", random_uuid()));
        let dirs: Vec<_> = ["override", "caller-tmp", "system"]
            .into_iter()
            .map(|name| root.join(name))
            .collect();
        let locator_record = root.join("outside/record.json");
        fs::create_dir_all(locator_record.parent().unwrap()).unwrap();
        fs::write(&locator_record, "not parsed here").unwrap();
        let id = "order-id";

        assert_eq!(
            find_record_path_with_locator(id, &dirs, || Some(locator_record.clone())),
            Some(locator_record.clone()),
            "locator is used only after all legacy directories miss"
        );
        for (index, dir) in dirs.iter().enumerate().rev() {
            fs::create_dir_all(dir).unwrap();
            let record = dir.join(format!("{id}.json"));
            fs::write(&record, if index == 0 { "not JSON" } else { "{}" }).unwrap();
            assert_eq!(
                find_record_path_with_locator(id, &dirs, || Some(locator_record.clone())),
                Some(record),
                "legacy directory {index} outranks later sources, even with invalid record contents"
            );
        }
        let locator_read = std::cell::Cell::new(false);
        assert_eq!(
            find_record_path_with_locator(id, &dirs, || {
                locator_read.set(true);
                Some(locator_record.clone())
            }),
            Some(dirs[0].join(format!("{id}.json")))
        );
        assert!(!locator_read.get(), "legacy hits do not read the locator");
        let directory = root.join("outside/directory.json");
        fs::create_dir(&directory).unwrap();
        assert_eq!(
            find_record_path_with_locator("directory", &[], || Some(directory.clone())),
            None,
            "a directory is not a locator record"
        );
        assert_eq!(
            find_record_path_with_locator("", &[], || Some(locator_record.clone())),
            None,
            "an empty id cannot be resolved through a locator"
        );
        assert_eq!(
            find_record_path_with_locator("a/b", &[], || Some(locator_record.clone())),
            None,
            "a slash id cannot be resolved through a locator"
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn invalid_and_stale_locator_files_are_lookup_misses() {
        use crate::test_env::EnvGuard;
        let _env = crate::test_env::lock();
        let root = std::env::temp_dir().join(format!("delegate-locator-invalid-{}", random_uuid()));
        let cache = root.join("cache");
        let locator_dir = cache.join("delegate/locators");
        let jobs = root.join("legacy");
        let tmp = root.join("tmp");
        let _home = EnvGuard::set("HOME", root.to_str().unwrap());
        let _xdg = EnvGuard::set("XDG_CACHE_HOME", cache.to_str().unwrap());
        let _jobs = EnvGuard::set("DELEGATE_JOBS_DIR", jobs.to_str().unwrap());
        let _tmp = EnvGuard::set("TMPDIR", tmp.to_str().unwrap());
        fs::create_dir_all(&locator_dir).unwrap();
        let stale = format!("stale-{}", random_uuid());
        let stale_target = root.join("jobs/stale.json");
        fs::write(
            locator_dir.join(&stale),
            stale_target.display().to_string() + "\n",
        )
        .unwrap();
        assert_eq!(
            locator_record_path(&stale),
            Some(stale_target.clone()),
            "a stale locator remains available for diagnostics"
        );
        assert_eq!(
            find_record_path(&stale),
            None,
            "a stale target is not a hit"
        );

        for (name, contents) in [
            (
                format!("relative-{}", random_uuid()),
                "jobs/relative.json\n",
            ),
            (format!("empty-{}", random_uuid()), "\n"),
            (
                format!("multiline-{}", random_uuid()),
                "/jobs/one.json\n/jobs/two.json\n",
            ),
        ] {
            fs::write(locator_dir.join(&name), contents).unwrap();
            assert_eq!(locator_record_path(&name), None, "{name}");
            assert_eq!(find_record_path(&name), None, "{name}");
        }
        let unreadable = format!("unreadable-{}", random_uuid());
        fs::create_dir(locator_dir.join(&unreadable)).unwrap();
        assert_eq!(locator_record_path(&unreadable), None);
        assert_eq!(locator_record_path("missing"), None);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn fallback_writers_preserve_the_session_and_configured_backend() {
        // Writes and reads through `job_record_path`, which follows the
        // process-global job-dir env (#681).
        let _env = crate::test_env::lock();
        let prior = json!({
            "status": "RUNNING",
            "resume": {"model": "model", "backend": "pi", "sessionId": "s-init"}
        });
        let cancelled_id = random_uuid();
        write_cancelled(&cancelled_id, &prior).unwrap();
        let cancelled = written_record(&cancelled_id);
        assert_eq!(cancelled["resume"]["sessionId"], "s-init");
        assert_eq!(cancelled["result"]["sessionId"], "s-init");
        assert_eq!(cancelled["result"]["backend"], "pi");
        let _ = fs::remove_file(job_record_path(&cancelled_id));

        let dead_id = random_uuid();
        write_supervisor_died(&dead_id, &prior).unwrap();
        let dead = written_record(&dead_id);
        assert_eq!(dead["resume"]["sessionId"], "s-init");
        assert_eq!(dead["result"]["sessionId"], "s-init");
        assert_eq!(dead["result"]["backend"], "pi");
        let _ = fs::remove_file(job_record_path(&dead_id));
    }

    #[test]
    fn search_order_is_override_then_tmp_then_system_tmp() {
        // docs/delegate-jobs.md#lookup-order
        let dirs = dirs_from(
            Some("/jobs/ship-tmp/delegate-jobs".into()),
            Path::new("/jobs/caller-tmp"),
            Path::new("/jobs/cwd"),
        );
        assert_eq!(
            dirs,
            vec![
                PathBuf::from("/jobs/ship-tmp/delegate-jobs"),
                PathBuf::from("/jobs/caller-tmp/delegate-jobs"),
                PathBuf::from("/tmp/delegate-jobs"),
            ]
        );
    }

    #[test]
    fn search_resolves_a_relative_override_against_cwd_and_drops_empty() {
        // docs/delegate-jobs.md#empty-and-relative-override
        let cwd = Path::new("/jobs/cwd");
        let no_over = dirs_from(None, Path::new("/jobs/caller-tmp"), cwd);
        assert_eq!(
            dirs_from(Some("".into()), Path::new("/jobs/caller-tmp"), cwd),
            no_over
        );
        assert_eq!(
            dirs_from(
                Some("relative/dir".into()),
                Path::new("/jobs/caller-tmp"),
                cwd
            )[0],
            PathBuf::from("/jobs/cwd/relative/dir")
        );
        assert_eq!(
            dirs_from(Some("/abs/dir".into()), Path::new("/jobs/caller-tmp"), cwd)[0],
            PathBuf::from("/abs/dir")
        );
    }

    #[test]
    fn writer_dir_prefers_the_override_else_tmp_jobs() {
        // docs/delegate-jobs.md#writers
        let cwd = Path::new("/jobs/cwd");
        let tmp = Path::new("/jobs/caller-tmp");
        assert_eq!(
            writer_dir_from(&Some("/jobs/ship/jobs".into()), tmp, cwd),
            PathBuf::from("/jobs/ship/jobs")
        );
        assert_eq!(
            writer_dir_from(&Some("relative/dir".into()), tmp, cwd),
            PathBuf::from("/jobs/cwd/relative/dir")
        );
        assert_eq!(
            writer_dir_from(&Some("".into()), tmp, cwd),
            PathBuf::from("/jobs/caller-tmp/delegate-jobs")
        );
        assert_eq!(
            writer_dir_from(&None, tmp, cwd),
            PathBuf::from("/jobs/caller-tmp/delegate-jobs")
        );
    }

    #[test]
    fn search_removes_duplicate_directories_keeping_the_first() {
        // docs/delegate-jobs.md#duplicates
        assert_eq!(
            dirs_from(
                Some("/jobs/caller-tmp/delegate-jobs".into()),
                Path::new("/jobs/caller-tmp"),
                Path::new("/jobs/cwd"),
            ),
            vec![
                PathBuf::from("/jobs/caller-tmp/delegate-jobs"),
                PathBuf::from("/tmp/delegate-jobs"),
            ]
        );
        assert_eq!(
            dirs_from(None, Path::new("/tmp"), Path::new("/jobs/cwd")),
            vec![PathBuf::from("/tmp/delegate-jobs")]
        );
    }

    #[test]
    fn lookup_returns_the_first_directory_holding_the_record() {
        // docs/delegate-jobs.md#lookup-order
        let root = std::env::temp_dir().join(format!("delegate-search-{}", random_uuid()));
        let first = root.join("a");
        let second = root.join("b");
        fs::create_dir_all(&first).unwrap();
        fs::create_dir_all(&second).unwrap();
        let id = random_uuid();
        assert_eq!(find_in_dirs(&id, &[first.clone(), second.clone()]), None);
        fs::write(second.join(format!("{id}.json")), "{}").unwrap();
        assert_eq!(
            find_in_dirs(&id, &[first.clone(), second.clone()]),
            Some(second.join(format!("{id}.json")))
        );
        fs::write(first.join(format!("{id}.json")), "{}").unwrap();
        assert_eq!(
            find_in_dirs(&id, &[first.clone(), second.clone()]),
            Some(first.join(format!("{id}.json")))
        );
        assert_eq!(find_in_dirs("../x", &[first.clone(), second.clone()]), None);
        assert_eq!(find_in_dirs("", &[first, second]), None);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn supervisor_fallback_does_not_guess_missing_backend_or_session() {
        // Writes and reads through `job_record_path`, which follows the
        // process-global job-dir env (#681).
        let _env = crate::test_env::lock();
        let id = random_uuid();
        let prior = json!({
            "status": "RUNNING",
            "resume": {"model": "old-model", "sessionId": null}
        });
        write_supervisor_died(&id, &prior).unwrap();
        let dead = written_record(&id);
        assert!(dead["result"]["backend"].is_null());
        assert!(dead["result"]["sessionId"].is_null());
        let _ = fs::remove_file(job_record_path(&id));
    }
}
