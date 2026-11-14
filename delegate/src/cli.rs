//! The `delegate` CLI: `run` starts a detached supervisor, `watch` reads job records.
//! The record file is the only link between them. `cancel`, `status`, `watch`, `resume` and
//! `ack` search `DELEGATE_JOBS_DIR`, the active cache's `delegate/jobs`,
//! `$TMPDIR/delegate-jobs`, `/tmp/delegate-jobs`, then the job's per-user locator.
//! See `docs/delegate-jobs.md`.

use crate::backends::Backend;
use crate::config::build_deps;
use crate::git::capture_head;
use crate::job::{JobDeps, JobHandle};
use crate::models::{allowed_pool, base_model_id, resolve_model};
use crate::prompt::status_block;
use crate::status_record::{
    CliRecordWriter, find_record_path, job_record_path, locator_path, locator_record_path,
    read_marker_path, record_path, search_dirs, valid_job_id, write_atomic, write_cancelled,
    write_locator, write_supervisor_died,
};
use crate::types::{Config, JobSpec, ResolvedModel, ResumeContext};
use crate::util::{captured_command, json_compact, random_uuid, resolve_path};
use std::io::{IsTerminal, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, Instant};

pub(crate) const USAGE: &str =
    "usage: delegate run --model M [--model-ruling URL] [--cwd D] [--add-dir D ...] [--gate CMD] [--tool-idle-ms N] [--idle-ms N] [--wall-ms N] [--prompt-file F | stdin]
       delegate resume <jobId> [--model M] [--model-ruling URL] [--gate CMD] [--tool-idle-ms N] [--idle-ms N] [--wall-ms N] [--prompt-file F | stdin]
       delegate model-check <model> [--model-ruling URL]
       delegate cancel <jobId>
       delegate watch <jobId>... [--timeout S]  (exit 1: timed out; exit 2: refusing to watch a job this process runs inside)
       delegate status <jobId>  (print state and finished job result summary without waiting)
       delegate ack <jobId>... [--any]  (mark one or more job reports as read)
       delegate models
       delegate doctor
       delegate version
       delegate run --model muse/MODEL ...  (muse exec; standard and strong rungs)
       delegate session start --model muse/MODEL|PROVIDER/MODEL[:LEVEL] [--model-ruling URL] --brief FILE --inbox DIR [--json]
       delegate session status <id-or-prefix> [--json]
       delegate session send <id-or-prefix> TEXT|- [--json]
       delegate session logs <id-or-prefix> [--follow] [--json]
       delegate session watch <id-or-prefix> [--json]
       delegate session stop <id-or-prefix> [--interrupt] [--json]
       delegate session list [--json]
       Session exit codes: 0 ok, 1 failed, 2 usage, 3 no session, 4 dead, 5 busy";

/// Bad input: reason on stderr, exit 2.
pub(crate) struct Usage(pub(crate) String);

fn usage<T>(msg: impl Into<String>) -> Result<T, Usage> {
    Err(Usage(msg.into()))
}

pub fn main() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("session") {
        return crate::session::main(&args[1..]);
    }
    if args
        .iter()
        .any(|arg| matches!(arg.as_str(), "--help" | "-h"))
        || matches!(args.first().map(String::as_str), Some("help"))
    {
        println!("{USAGE}");
        return 0;
    }
    let res = match args.first().map(String::as_str) {
        Some("run") => run(&args[1..]),
        Some("resume") => resume(&args[1..]),
        Some("model-check") => model_check(&args[1..]),
        Some("cancel") => cancel(&args[1..]),
        Some("watch") => watch(&args[1..]),
        Some("status") => status(&args[1..]),
        Some("ack") => ack(&args[1..]),
        Some("models") => crate::cli_info::models().map_err(Usage),
        Some("doctor") => crate::cli_info::doctor().map_err(Usage),
        Some("version") => Ok(crate::cli_info::version()),
        Some("__supervise") => return supervise(&args[1..]),
        Some(name) => usage(format!(
            "unknown subcommand {name}; `delegate status <jobId>` prints a job's state, `delegate watch <jobId>` prints a job's state and result, and the id that superseded it\n{USAGE}"
        )),
        None => usage(USAGE),
    };
    match res {
        Ok(code) => code,
        Err(Usage(m)) => {
            eprintln!("{m}");
            2
        }
    }
}

/// Splits `--flag value` pairs from positionals.
fn parse(args: &[String], flags: &[&str]) -> Result<(Vec<(String, String)>, Vec<String>), Usage> {
    let (mut kv, mut pos) = (vec![], vec![]);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a.starts_with("--") {
            if !flags.contains(&a.as_str()) {
                return usage(format!("unknown flag {a}\n{USAGE}"));
            }
            let Some(v) = it.next() else {
                return usage(format!("{a} needs a value"));
            };
            kv.push((a.clone(), v.clone()));
        } else {
            pos.push(a.clone());
        }
    }
    Ok((kv, pos))
}

fn flag<'a>(kv: &'a [(String, String)], name: &str) -> Option<&'a str> {
    kv.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
}

fn current_job_contains(id: &str) -> bool {
    std::env::var("DELEGATE_JOB_ID").is_ok_and(|own| !own.is_empty() && own == id)
        || std::env::var("DELEGATE_JOB_CHAIN")
            .is_ok_and(|chain| chain.split_whitespace().any(|entry| entry == id))
}

fn flag_values<'a>(kv: &'a [(String, String)], name: &str) -> Vec<&'a str> {
    kv.iter()
        .filter(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
        .collect()
}

fn add_directories(kv: &[(String, String)], backend: &str) -> Result<Vec<String>, Usage> {
    let values = flag_values(kv, "--add-dir");
    if !values.is_empty() && backend != "fiber" {
        return usage("--add-dir is only supported by the fiber backend");
    }
    values
        .into_iter()
        .map(|dir| {
            let path = resolve_path(dir);
            if !std::path::Path::new(&path).is_dir() {
                return usage(format!("add-dir {path} is not a directory"));
            }
            Ok(path)
        })
        .collect()
}

/// A millisecond flag: `None` when absent, else a finite number above zero.
fn positive_ms_flag(kv: &[(String, String)], name: &str) -> Result<Option<f64>, String> {
    match flag(kv, name) {
        None => Ok(None),
        Some(s) => match s.parse::<f64>() {
            Ok(n) if n.is_finite() && n > 0.0 => Ok(Some(n)),
            _ => Err(format!("invalid {name} {s}")),
        },
    }
}

fn resume_ms_flag(
    kv: &[(String, String)],
    name: &str,
    stored: Option<f64>,
) -> Result<Option<f64>, String> {
    Ok(positive_ms_flag(kv, name)?.or(stored))
}

/// `run`'s unknown-id message, reused wherever a model flag is resolved.
fn unknown_model(config: &Config, model: &str) -> String {
    let mut ids: Vec<_> = config.models.keys().cloned().collect();
    ids.sort();
    format!("unknown model {model}; valid models: {}", ids.join(", "))
}

fn valid_model_ruling_url(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://github.com/") else {
        return false;
    };
    let parts: Vec<_> = rest.split('/').collect();
    let [owner, repo, kind, tail] = parts.as_slice() else {
        return false;
    };
    let valid_component = |value: &str| {
        !value.is_empty()
            && value != "."
            && value != ".."
            && value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    };
    if !valid_component(owner) || !valid_component(repo) || !["issues", "pull"].contains(kind) {
        return false;
    }
    let Some((number, comment)) = tail.split_once("#issuecomment-") else {
        return false;
    };
    !number.is_empty()
        && number.bytes().all(|b| b.is_ascii_digit())
        && !comment.is_empty()
        && comment.bytes().all(|b| b.is_ascii_digit())
}

pub(crate) fn validate_model_ruling(ruling: Option<&str>) -> Result<(), String> {
    match ruling {
        None => Ok(()),
        Some(url) if valid_model_ruling_url(url) => Ok(()),
        Some(_) => Err(
            "invalid --model-ruling; expected https://github.com/<owner>/<repo>/(issues|pull)/<n>#issuecomment-<digits>".into(),
        ),
    }
}

pub(crate) fn check_model_allowed(
    config: &Config,
    resolved: &ResolvedModel,
    ruling: Option<&str>,
) -> Result<(), String> {
    if resolved.allowed || ruling.is_some() {
        return Ok(());
    }
    Err(format!(
        "model \"{}\" is not in the allowed pool (models.json rows with \"allowed\": true: {}); pass --model-ruling <comment URL> for a ruled exception",
        resolved.model,
        allowed_pool(config).join(", ")
    ))
}

pub(crate) fn check_resolved_model(config: &Config, model: &str) -> Result<ResolvedModel, Usage> {
    match resolve_model(Some(model), config) {
        Ok(resolved) => Ok(resolved),
        Err(e)
            if e.downcast_ref::<crate::models::ModelNotAllowedError>()
                .is_some() =>
        {
            Err(Usage(unknown_model(config, model)))
        }
        Err(e) => Err(Usage(e.to_string())),
    }
}

/// The shared half of `run` and `resume`: stash the prompt, spawn the detached
/// supervisor and wait for its first record. Returns the new job id. `Usage` means exit
/// 2; `Done` means the reason is already on stderr, return the code.
enum LaunchErr {
    Usage(String),
    Done(i32),
}

struct LaunchParams<'a> {
    prompt: &'a str,
    model: &'a str,
    model_ruling: Option<&'a str>,
    cwd: &'a str,
    gate: &'a str,
    tool_idle_ms: Option<f64>,
    idle_ms: Option<f64>,
    wall_ms: Option<f64>,
    add_dirs: &'a [String],
    session: Option<&'a str>,
    resumed_from: Option<&'a str>,
}

struct CallerInfo {
    caller: String,
    pid: u32,
    command: Option<String>,
    cwd: Option<String>,
}

fn caller_cwd() -> Option<String> {
    std::env::var_os("DELEGATE_CALLER_CWD")
        .filter(|cwd| !cwd.is_empty())
        .map(|cwd| cwd.to_string_lossy().into_owned())
        .or_else(|| {
            std::env::current_dir()
                .ok()
                .map(|cwd| cwd.to_string_lossy().into_owned())
        })
}

fn canonicalize_with_missing_tail(path: &std::path::Path) -> std::path::PathBuf {
    // A relative path resolves against the acker's cwd. caller_cwd() records DELEGATE_CALLER_CWD
    // verbatim, so a caller that exports a relative value gets a relative record cwd.
    let absolute_path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        let Ok(cwd) = std::env::current_dir() else {
            return path.to_path_buf();
        };
        cwd.join(path)
    };

    let mut ancestor = absolute_path.as_path();
    loop {
        if let Ok(mut canonical) = std::fs::canonicalize(ancestor) {
            if let Ok(missing_tail) = absolute_path.strip_prefix(ancestor) {
                for component in missing_tail.components() {
                    match component {
                        std::path::Component::CurDir => {}
                        std::path::Component::ParentDir => {
                            canonical.pop();
                        }
                        std::path::Component::Normal(part) => canonical.push(part),
                        std::path::Component::Prefix(_) | std::path::Component::RootDir => {}
                    }
                }
            }
            return canonical;
        }
        let Some(parent) = ancestor.parent() else {
            return absolute_path;
        };
        if parent == ancestor {
            return absolute_path;
        }
        ancestor = parent;
    }
}

fn cwd_paths_related(record_cwd: &str, ack_cwd: &str) -> bool {
    let record_path = canonicalize_with_missing_tail(std::path::Path::new(record_cwd));
    let ack_path = canonicalize_with_missing_tail(std::path::Path::new(ack_cwd));
    record_path.starts_with(&ack_path) || ack_path.starts_with(&record_path)
}

fn caller_label_matches(record_caller: &str, ack_caller: &str) -> bool {
    record_caller == ack_caller || record_caller.starts_with(&format!("{ack_caller}/"))
}

/// Capture attribution in the invoking CLI, before it detaches the supervisor.
/// Scripts may provide a more meaningful label and source cwd explicitly.
fn caller_info() -> CallerInfo {
    let pid = unsafe { libc::getppid() } as u32;
    let command = std::process::Command::new("ps")
        .args(["-o", "command=", "-p", &pid.to_string()])
        .output()
        .ok()
        .filter(|out| out.status.success())
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|command| !command.is_empty());
    let cwd = caller_cwd();
    let caller = std::env::var("DELEGATE_CALLER")
        .ok()
        .filter(|caller| !caller.is_empty())
        .or_else(|| command.clone())
        .unwrap_or_else(|| format!("pid:{pid}"));
    CallerInfo {
        caller,
        pid,
        command,
        cwd,
    }
}

fn launch(p: LaunchParams<'_>) -> Result<String, LaunchErr> {
    let caller = caller_info();
    let id = random_uuid();
    // Publish before creating the cache-backed job directory so a blocked
    // cache root fails as a locator error, not as a partial job launch.
    if let Err(e) = write_locator(&id) {
        eprintln!("cannot write job locator for {id}: {e}");
        return Err(LaunchErr::Done(1));
    }
    let discard_locator = || {
        if let Some(locator) = locator_path(&id) {
            let _ = std::fs::remove_file(locator);
        }
    };
    let record = job_record_path(&id);
    let dir = record.parent().expect("record has a parent");
    if let Err(e) = std::fs::create_dir_all(dir) {
        discard_locator();
        return Err(LaunchErr::Usage(format!("{}: {e}", dir.display())));
    }
    let prompt_file = dir.join(format!("{id}.prompt"));
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&prompt_file)
        .and_then(|mut f| f.write_all(p.prompt.as_bytes()));
    if let Err(e) = written {
        let _ = std::fs::remove_file(&prompt_file);
        discard_locator();
        return Err(LaunchErr::Usage(format!("{}: {e}", prompt_file.display())));
    }

    let mut supervise_args = vec![
        "__supervise".to_string(),
        id.clone(),
        p.model.to_string(),
        p.cwd.to_string(),
    ];
    if let Some(ruling) = p.model_ruling {
        supervise_args.push("--model-ruling".into());
        supervise_args.push(ruling.to_string());
    }
    if !p.gate.is_empty() {
        supervise_args.push("--gate".into());
        supervise_args.push(p.gate.to_string());
    }
    if let Some(ms) = p.tool_idle_ms {
        supervise_args.push("--tool-idle-ms".into());
        // Shortest round-trip so the supervisor parses the same number back.
        supervise_args.push(ms.to_string());
    }
    if let Some(ms) = p.idle_ms {
        supervise_args.push("--idle-ms".into());
        supervise_args.push(ms.to_string());
    }
    if let Some(ms) = p.wall_ms {
        supervise_args.push("--wall-ms".into());
        supervise_args.push(ms.to_string());
    }
    for dir in p.add_dirs {
        supervise_args.push("--add-dir".into());
        supervise_args.push(dir.clone());
    }
    if let Some(s) = p.session {
        supervise_args.push("--session".into());
        supervise_args.push(s.to_string());
    }
    if let Some(r) = p.resumed_from {
        supervise_args.push("--resumed-from".into());
        supervise_args.push(r.to_string());
    }
    supervise_args.push("--caller".into());
    supervise_args.push(caller.caller.clone());
    supervise_args.push("--caller-pid".into());
    supervise_args.push(caller.pid.to_string());
    if let Some(command) = &caller.command {
        supervise_args.push("--caller-command".into());
        supervise_args.push(command.clone());
    }
    if let Some(cwd) = &caller.cwd {
        supervise_args.push("--caller-cwd".into());
        supervise_args.push(cwd.clone());
    }
    // Own session and process group, stdio closed: the supervisor outlives this process.
    let exe = std::env::current_exe().map_err(|e| {
        let _ = std::fs::remove_file(&prompt_file);
        discard_locator();
        LaunchErr::Usage(e.to_string())
    })?;
    let mut cmd = captured_command(&exe).map_err(|e| {
        let _ = std::fs::remove_file(&prompt_file);
        discard_locator();
        LaunchErr::Usage(format!("cannot write cargo-mutants shim: {e}"))
    })?;
    let chain = std::env::var("DELEGATE_JOB_CHAIN")
        .ok()
        .map(|chain| chain.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|chain| !chain.is_empty())
        .map(|chain| format!("{chain} {id}"))
        .unwrap_or_else(|| id.clone());
    cmd.env("DELEGATE_JOB_ID", &id)
        .env("DELEGATE_JOB_CHAIN", chain); // debt: fiber workers do not see these (the hub daemon, not __supervise, owns their tools); upgrade when fiber's hub run request takes an env field, pass DELEGATE_JOB_ID and DELEGATE_JOB_CHAIN on it.
    let mut child = unsafe {
        cmd.args(&supervise_args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .pre_exec(|| {
                libc::setsid();
                Ok(())
            })
            .spawn()
    }
    .map_err(|e| {
        let _ = std::fs::remove_file(&prompt_file);
        discard_locator();
        LaunchErr::Usage(format!("cannot start supervisor: {e}"))
    })?;
    // The supervisor writes the first RUNNING record before the agent starts; wait for it.
    let t = Instant::now();
    while !record.exists() {
        let exited = child.try_wait().ok().flatten().is_some();
        if exited || t.elapsed() > Duration::from_secs(10) {
            let _ = std::fs::remove_file(&prompt_file);
            if exited {
                discard_locator();
            }
            eprintln!("supervisor failed to write {}", record.display());
            return Err(LaunchErr::Done(1));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(id)
}

/// The prompt from `--prompt-file`, else stdin. A terminal stdin is a usage error:
/// reading it would block waiting for input nobody meant to type (#168).
fn read_prompt(kv: &[(String, String)]) -> Result<String, Usage> {
    let mut prompt = String::new();
    match flag(kv, "--prompt-file") {
        Some(f) => prompt = std::fs::read_to_string(f).map_err(|e| Usage(format!("{f}: {e}")))?,
        None => {
            if std::io::stdin().is_terminal() {
                return usage("no prompt: pass it on stdin or with --prompt-file");
            }
            let _ = std::io::stdin().read_to_string(&mut prompt);
        }
    }
    if prompt.trim().is_empty() {
        return usage("prompt is empty");
    }
    Ok(prompt)
}

fn run(args: &[String]) -> Result<i32, Usage> {
    let (kv, pos) = parse(
        args,
        &[
            "--model",
            "--model-ruling",
            "--cwd",
            "--gate",
            "--tool-idle-ms",
            "--idle-ms",
            "--wall-ms",
            "--add-dir",
            "--prompt-file",
        ],
    )?;
    if let Some(p) = pos.first() {
        return usage(format!(
            "unexpected argument {p:?}: pass the prompt on stdin or with --prompt-file"
        ));
    }
    let Some(model) = flag(&kv, "--model") else {
        return usage("--model is required");
    };
    let model_ruling = flag(&kv, "--model-ruling");
    validate_model_ruling(model_ruling).or_else(usage)?;
    let gate = flag(&kv, "--gate").unwrap_or("").to_string();
    let tool_idle_ms = positive_ms_flag(&kv, "--tool-idle-ms").or_else(usage)?;
    let idle_ms = positive_ms_flag(&kv, "--idle-ms").or_else(usage)?;
    let wall_ms = positive_ms_flag(&kv, "--wall-ms").or_else(usage)?;
    let deps = match build_deps() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("{e}");
            return Ok(1);
        }
    };
    let resolved = check_resolved_model(&deps.config, model)?;
    check_model_allowed(&deps.config, &resolved, model_ruling).or_else(usage)?;
    let add_dirs = add_directories(&kv, &resolved.backend)?;
    let prompt = read_prompt(&kv)?;
    let cwd = match flag(&kv, "--cwd") {
        Some(d) => resolve_path(d),
        None => std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .map_err(|e| Usage(e.to_string()))?,
    };
    if !std::path::Path::new(&cwd).is_dir() {
        return usage(format!("cwd {cwd} is not a directory"));
    }

    match launch(LaunchParams {
        prompt: &prompt,
        model,
        model_ruling,
        cwd: &cwd,
        gate: &gate,
        tool_idle_ms,
        idle_ms,
        wall_ms,
        add_dirs: &add_dirs,
        session: None,
        resumed_from: None,
    }) {
        Ok(id) => {
            println!("{id}");
            Ok(0)
        }
        Err(LaunchErr::Usage(m)) => Err(Usage(m)),
        Err(LaunchErr::Done(c)) => Ok(c),
    }
}

fn model_check(args: &[String]) -> Result<i32, Usage> {
    let (kv, pos) = parse(args, &["--model-ruling"])?;
    let [model] = pos.as_slice() else {
        return usage("delegate model-check <model> [--model-ruling URL]");
    };
    let ruling = flag(&kv, "--model-ruling");
    validate_model_ruling(ruling).or_else(usage)?;
    let deps = match build_deps() {
        Ok(d) => d,
        Err(e) => return Err(Usage(e.to_string())),
    };
    let resolved = check_resolved_model(&deps.config, model)?;
    check_model_allowed(&deps.config, &resolved, ruling).or_else(usage)?;
    Ok(0)
}

fn resume(args: &[String]) -> Result<i32, Usage> {
    let (kv, pos) = parse(
        args,
        &[
            "--model",
            "--model-ruling",
            "--gate",
            "--tool-idle-ms",
            "--idle-ms",
            "--wall-ms",
            "--prompt-file",
        ],
    )?;
    let [old_id] = pos.as_slice() else {
        return usage(USAGE);
    };
    let model_ruling_flag = flag(&kv, "--model-ruling");
    validate_model_ruling(model_ruling_flag).or_else(usage)?;
    let Some(raw) = read_record(old_id) else {
        return Err(missing_record(old_id));
    };
    let old: serde_json::Value =
        serde_json::from_str(&raw).map_err(|e| Usage(format!("cannot read job {old_id}: {e}")))?;
    if old["status"] == "RUNNING" {
        return usage(format!("cannot resume {old_id}: job is RUNNING"));
    }
    let stored_model = old["resume"]["model"].as_str().unwrap_or("").to_string();
    if stored_model.is_empty() {
        return usage(format!("cannot resume {old_id}: record has no model"));
    }
    let session: Option<String> = old["resume"]["sessionId"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .map(String::from);
    let stored_cwd = old["resume"]["cwd"].as_str().unwrap_or("").to_string();
    let stored_gate = old["resume"]["gate"].as_str().unwrap_or("").to_string();
    let add_dirs = old["resume"]["addDirs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .map(str::to_string)
        .collect::<Vec<_>>();
    let tool_idle_ms = resume_ms_flag(&kv, "--tool-idle-ms", old["resume"]["toolIdleMs"].as_f64())
        .or_else(usage)?;
    let idle_ms =
        resume_ms_flag(&kv, "--idle-ms", old["resume"]["idleMs"].as_f64()).or_else(usage)?;
    let wall_ms =
        resume_ms_flag(&kv, "--wall-ms", old["resume"]["wallMs"].as_f64()).or_else(usage)?;

    let deps = match build_deps() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("{e}");
            return Ok(1);
        }
    };
    // Overrides replace stored values. A model on another backend would continue the
    // wrong session, so it is rejected before anything spawns. Both ids go through
    // `base_model_id` first so a suffixed Claude, pi or fiber id compares on its
    // base (#157); a bad level is a usage error of its own, not the allow-list.
    let model = flag(&kv, "--model").unwrap_or(&stored_model).to_string();
    if flag(&kv, "--model").is_some() {
        let stored_base = match base_model_id(&stored_model, &deps.config.models) {
            Ok(b) => b.to_string(),
            Err(msg) => return usage(msg),
        };
        let new_base = match base_model_id(&model, &deps.config.models) {
            Ok(b) => b.to_string(),
            Err(msg) => return usage(msg),
        };
        let stored_backend = deps
            .config
            .models
            .get(&stored_base)
            .map(|e| e.backend.as_str());
        let new_backend = deps
            .config
            .models
            .get(&new_base)
            .map(|e| e.backend.as_str());
        match (stored_backend, new_backend) {
            (Some(a), Some(b)) if a != b => {
                return usage(format!(
                    "cannot resume {old_id}: model {model} uses backend \"{b}\", \
                     but {stored_model} ran on backend \"{a}\""
                ));
            }
            (_, None) => return usage(unknown_model(&deps.config, &model)),
            _ => {}
        }
        // Unknown ids are rejected below; what remains is a same-backend id the
        // resolver may still refuse (e.g. a backend that is not implemented yet).
    }
    let resolved = check_resolved_model(&deps.config, &model)?;
    let inherited_ruling = (model == stored_model)
        .then(|| old["resume"]["modelRuling"].as_str())
        .flatten();
    let model_ruling = model_ruling_flag.or(inherited_ruling);
    validate_model_ruling(model_ruling).or_else(usage)?;
    check_model_allowed(&deps.config, &resolved, model_ruling).or_else(usage)?;
    if session.is_none() {
        // Fiber mints the session id on its first output line, so a job
        // killed before that has no id to resume. An explicit resume of
        // such a record runs fresh; a cancelled record is still refused,
        // as is a record from any other backend.
        let cancelled = old["status"] == "CANCELLED";
        if cancelled || resolved.backend != "fiber" {
            return usage(format!("cannot resume {old_id}: record has no session id"));
        }
    }
    let gate = flag(&kv, "--gate").unwrap_or(&stored_gate).to_string();

    let prompt = read_prompt(&kv)?;
    if !std::path::Path::new(&stored_cwd).is_dir() {
        return usage(format!("cwd {stored_cwd} is not a directory"));
    }

    let new_id = match launch(LaunchParams {
        prompt: &prompt,
        model: &model,
        model_ruling,
        cwd: &stored_cwd,
        gate: &gate,
        tool_idle_ms,
        idle_ms,
        wall_ms,
        add_dirs: &add_dirs,
        session: session.as_deref(),
        resumed_from: Some(old_id),
    }) {
        Ok(id) => id,
        Err(LaunchErr::Usage(m)) => return Err(Usage(m)),
        Err(LaunchErr::Done(c)) => return Ok(c),
    };
    // B is spawned and its record exists; link A to it, preserving everything else.
    // Re-read so a concurrent `watch` settle is not clobbered. B is already running,
    // so a failed link is a warning: the caller still needs B's id.
    let link = read_record(old_id)
        .ok_or_else(|| format!("record for {old_id} is gone"))
        .and_then(|raw| {
            serde_json::from_str::<serde_json::Value>(&raw)
                .map_err(|e| format!("cannot read job {old_id}: {e}"))
        });
    match link {
        Ok(mut old) => {
            if let Some(obj) = old.as_object_mut() {
                obj.insert("supersededBy".into(), new_id.clone().into());
            }
            if let Err(e) = write_atomic(&record_path(old_id), &json_compact(&old)) {
                eprintln!("warning: cannot link {old_id} to {new_id}: {e}");
            }
        }
        Err(reason) => eprintln!("warning: {reason}"),
    }
    println!("{new_id}");
    Ok(0)
}

fn cancel(args: &[String]) -> Result<i32, Usage> {
    let (_, pos) = parse(args, &[])?;
    let [id] = pos.as_slice() else {
        return usage(USAGE);
    };
    let Some(raw) = read_record(id) else {
        return Err(missing_record(id));
    };
    let rec: serde_json::Value =
        serde_json::from_str(&raw).map_err(|e| Usage(format!("cannot read job {id}: {e}")))?;
    if rec["status"] != "RUNNING" {
        println!("{rec}");
        return Ok(0);
    }
    let Some(pid) = rec["supervisorPid"].as_i64() else {
        return usage(format!("cannot cancel {id}: record has no supervisor pid"));
    };
    if pid <= 0 || pid > i32::MAX as i64 {
        return usage(format!("cannot cancel {id}: bad supervisor pid {pid}"));
    }
    let pid = pid as i32;
    // A recycled pid must never be signalled: confirm it is still this job's supervisor.
    // If it is gone or something else, there is nothing to signal; report CANCELLED.
    if !supervisor_cmd_matches(pid, id) {
        return cancel_write(id, &rec);
    }
    // The supervisor is a session leader, so its pgid is its pid: one signal reaches it.
    // It translates that into `registry.cancel`, which SIGTERMs the agent's own group.
    unsafe {
        libc::kill(-pid, libc::SIGTERM);
    }
    if let Some(final_rec) = wait_for_terminal_record(id, Duration::from_secs(5)) {
        println!("{final_rec}");
        return Ok(0);
    }
    // The supervisor is hung or already dead: take down its group and the agent's group
    // (a direct child still parented to the supervisor) with SIGKILL, then report CANCELLED.
    for child in child_pids(pid) {
        unsafe {
            libc::kill(-child, libc::SIGKILL);
        }
    }
    unsafe {
        libc::kill(-pid, libc::SIGKILL);
    }
    if let Some(final_rec) = wait_for_terminal_record(id, Duration::from_secs(2)) {
        println!("{final_rec}");
        return Ok(0);
    }
    let Some(raw) = read_record(id).and_then(|s| serde_json::from_str(&s).ok()) else {
        return Err(missing_record(id));
    };
    cancel_write(id, &raw)
}

/// `ps -o command= -p <pid>` contains `__supervise <id>` only while this job's
/// supervisor is that pid. A reused pid shows another command (or nothing).
fn supervisor_cmd_matches(pid: i32, id: &str) -> bool {
    let out = std::process::Command::new("ps")
        .args(["-o", "command=", "-p", &pid.to_string()])
        .output();
    let Ok(out) = out else { return false };
    if !out.status.success() {
        return false;
    }
    let want = format!("__supervise {id}");
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .any(|l| l.contains(&want))
}

/// Nobody is left to finalize, so write the CANCELLED terminal record and print it.
fn cancel_write(id: &str, prior: &serde_json::Value) -> Result<i32, Usage> {
    if let Err(e) = write_cancelled(id, prior) {
        eprintln!(
            "cannot write status record {}: {e}",
            record_path(id).display()
        );
        return Ok(1);
    }
    println!("{}", read_record(id).unwrap_or_else(|| "{}".to_string()));
    Ok(0)
}

/// The record when it is no longer RUNNING; `None` while it still is (or is unreadable).
fn terminal_record(id: &str) -> Option<serde_json::Value> {
    let raw = read_record(id)?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
    if v["status"] == "RUNNING" {
        None
    } else {
        Some(v)
    }
}

/// Poll the record until it turns terminal, or `timeout` passes. Returns the terminal
/// record, or `None` if it is still RUNNING when the time is up.
fn wait_for_terminal_record(id: &str, timeout: Duration) -> Option<serde_json::Value> {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if let Some(rec) = terminal_record(id) {
            return Some(rec);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    terminal_record(id)
}

/// Direct children of `ppid`, via `ps`. Used only to find the agent after its supervisor
/// stopped answering SIGTERM; best-effort, so an empty list just means SIGKILL the
/// supervisor's group and write the record ourselves.
fn child_pids(ppid: i32) -> Vec<i32> {
    let out = std::process::Command::new("ps")
        .args(["-ax", "-o", "pid=", "-o", "ppid="])
        .output();
    let Ok(out) = out else { return vec![] };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            let pid: i32 = it.next()?.parse().ok()?;
            let pp: i32 = it.next()?.parse().ok()?;
            (pp == ppid).then_some(pid)
        })
        .collect()
}

/// The detached half of `run`: drives one job, keeping its record fresh until it ends.
fn supervise(args: &[String]) -> i32 {
    let fail = |m: String| {
        eprintln!("{m}");
        1
    };
    let (kv, pos) = match parse(
        args,
        &[
            "--gate",
            "--tool-idle-ms",
            "--idle-ms",
            "--wall-ms",
            "--model-ruling",
            "--add-dir",
            "--session",
            "--resumed-from",
            "--caller",
            "--caller-pid",
            "--caller-command",
            "--caller-cwd",
        ],
    ) {
        Ok(v) => v,
        Err(Usage(m)) => return fail(m),
    };
    let [id, model, cwd] = pos.as_slice() else {
        return 2;
    };
    let model_ruling = flag(&kv, "--model-ruling");
    if let Err(message) = validate_model_ruling(model_ruling) {
        return fail(message);
    }
    let gate = flag(&kv, "--gate").unwrap_or("").to_string();
    let (Ok(tool_idle_ms), Ok(idle_ms), Ok(wall_ms)) = (
        positive_ms_flag(&kv, "--tool-idle-ms"),
        positive_ms_flag(&kv, "--idle-ms"),
        positive_ms_flag(&kv, "--wall-ms"),
    ) else {
        return 2;
    };
    let deps = match build_deps() {
        Ok(d) => d,
        Err(e) => return fail(e.to_string()),
    };
    let config = deps.config;
    let resolved = match resolve_model(Some(model), &config) {
        Ok(r) => r,
        Err(e) => return fail(e.to_string()),
    };
    if let Err(message) = check_model_allowed(&config, &resolved, model_ruling) {
        // The launcher wrote the prompt for this job; a refused job never
        // reads it, so remove it here rather than leave it in the jobs dir.
        let _ = std::fs::remove_file(job_record_path(id).with_extension("prompt"));
        return fail(message);
    }
    let Some(backend) = Backend::from_name(&resolved.backend) else {
        return fail(format!(
            "model \"{model}\" uses backend \"{}\", which is not implemented yet",
            resolved.backend
        ));
    };
    let prompt_file = job_record_path(id).with_extension("prompt");
    let Ok(prompt) = std::fs::read_to_string(&prompt_file) else {
        return fail(format!("cannot read {}", prompt_file.display()));
    };
    let _ = std::fs::remove_file(&prompt_file);
    let prompt = format!("{prompt}\n\n---\n\n{}", status_block()).replace('\0', "");
    let session = flag(&kv, "--session").map(str::to_string);
    let resumed_from = flag(&kv, "--resumed-from").map(str::to_string);
    let Some(caller) = flag(&kv, "--caller").map(str::to_string) else {
        return fail("missing caller metadata".into());
    };
    let Some(caller_pid) = flag(&kv, "--caller-pid").and_then(|pid| pid.parse::<u32>().ok()) else {
        return fail("invalid caller pid metadata".into());
    };
    let caller_command = flag(&kv, "--caller-command").map(str::to_string);
    let caller_cwd = flag(&kv, "--caller-cwd").map(str::to_string);
    let add_dirs = flag_values(&kv, "--add-dir")
        .into_iter()
        .map(str::to_string)
        .collect::<Vec<_>>();
    let mut argv = backend.argv(model, session.as_deref(), &prompt);
    // The catalogue selects this reviewer; rows without one leave Fiber's own defaults intact.
    if backend == Backend::Fiber
        && let Some(reviewer) = resolved.reviewer.as_deref()
    {
        argv = crate::backends::fiber::with_reviewer(argv, reviewer);
    }
    // The muse sandbox flag comes from the per-host config, default off:
    // with the sandbox off the worktree is the only containment.
    let argv = if backend == Backend::Muse {
        crate::backends::muse::with_sandbox(argv, config.profile.muse_sandbox == Some(true))
    } else {
        argv
    };
    // Cost is keyed on the full id; a suffixed id prices as its base row (#157).
    let mut price_map = config.price_map.clone();
    price_map.insert(model.to_string(), resolved.price);
    let spec = JobSpec {
        bin: backend.bin(),
        argv,
        cwd: cwd.clone(),
        model: model.clone(),
        backend: backend.name().into(),
        reviewer: resolved.reviewer.clone(),
        path: Some(resolve_path(cwd)),
        head_before: capture_head(cwd, None),
        gate: gate.clone(),
        idle_ms: idle_ms.map(Some),
        tool_idle_ms: tool_idle_ms.map(Some).or(config.profile.tool_idle_ms),
        wall_ms,
        add_dirs: add_dirs.clone(),
        price_map,
        resume_context: ResumeContext {
            model: model.clone(),
            gate: gate.clone(),
        },
    };

    let idle = |v: Option<Option<f64>>, d| match v {
        None => Some(d),
        Some(inner) => inner,
    };
    let mut rd = JobDeps::new(
        Arc::new(backend),
        idle(config.profile.idle_ms, 300_000.0),
        idle(config.profile.tool_idle_ms, 1_800_000.0),
    );
    if let Some(ms) = std::env::var("DELEGATE_HEARTBEAT_MS")
        .ok()
        .and_then(|v| v.parse().ok())
    {
        rd.heartbeat_ms = ms;
    }
    // `DELEGATE_IDLE_MS`: test-only override of the model-idle window.
    if let Some(ms) = std::env::var("DELEGATE_IDLE_MS")
        .ok()
        .and_then(|v| v.parse().ok())
    {
        rd.idle_ms = Some(ms);
    }
    // `DELEGATE_RETRY_DELAYS_MS`: test-only override of the retry backoff, comma-separated.
    if let Ok(v) = std::env::var("DELEGATE_RETRY_DELAYS_MS") {
        rd.retry_delays_ms = v.split(',').filter_map(|d| d.trim().parse().ok()).collect();
    }
    rd.record_id = Some(id.clone());
    rd.status_writer = Arc::new(CliRecordWriter {
        job_id: id.clone(),
        model: model.clone(),
        backend: Some(resolved.backend.clone()),
        cwd: cwd.clone(),
        caller,
        caller_pid,
        caller_command,
        caller_cwd,
        model_ruling: model_ruling.map(str::to_string),
        started_at_ms: std::sync::Mutex::new(None),
        ended_at_ms: std::sync::Mutex::new(None),
        last_session_id: std::sync::Mutex::new(None),
        gate: gate.clone(),
        tool_idle_ms,
        idle_ms,
        wall_ms,
        add_dirs,
        resumed_from: resumed_from.clone(),
    });
    let registry = JobHandle::new(rd);
    let cancel_fd = install_cancel_handler();
    let job = registry.dispatch(spec);
    if let Some(fd) = cancel_fd {
        spawn_cancel_waiter(Arc::clone(&registry), job.clone(), fd);
    }
    while registry.wait(&job, None) == "RUNNING" {}
    0
}

/// Write end of the self-pipe; the SIGTERM handler drops one byte in it.
static CANCEL_PIPE_W: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_cancel_sigterm(_: libc::c_int) {
    // Async-signal-safe: just wake the cancel thread.
    let b = 0u8;
    unsafe {
        libc::write(
            CANCEL_PIPE_W.load(Ordering::Relaxed),
            (&b as *const u8).cast(),
            1,
        )
    };
}

/// `cancel` SIGTERMs the supervisor's process group. Translate that into
/// `registry.cancel`, which SIGTERMs the agent's own group and writes the CANCELLED
/// terminal record. A handler plus self-pipe (not a blocked mask plus sigwait) carries
/// the signal: a blocked mask would be inherited by the agent child and make it
/// unkillable by SIGTERM, and the pipe fds are CLOEXEC so the agent never holds them.
/// Returns the read end; the caller spawns the waiter once the job id exists.
fn install_cancel_handler() -> Option<i32> {
    let mut fds = [0 as libc::c_int; 2];
    unsafe {
        if libc::pipe(fds.as_mut_ptr()) != 0 {
            return None;
        }
        for fd in fds {
            let flags = libc::fcntl(fd, libc::F_GETFD);
            if flags >= 0 {
                libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
            }
        }
    }
    CANCEL_PIPE_W.store(fds[1], Ordering::Relaxed);
    let handler = on_cancel_sigterm as extern "C" fn(libc::c_int) as libc::sighandler_t;
    unsafe {
        libc::signal(libc::SIGTERM, handler);
    }
    Some(fds[0])
}

fn spawn_cancel_waiter(registry: Arc<JobHandle>, job: String, fd: i32) {
    std::thread::spawn(move || {
        let mut b = 0u8;
        // One SIGTERM is all `cancel` ever sends before escalating to SIGKILL.
        unsafe { libc::read(fd, (&mut b as *mut u8).cast(), 1) };
        unsafe { libc::close(fd) };
        registry.cancel(&job);
    });
}

fn read_record(id: &str) -> Option<String> {
    let path = find_record_path(id)?;
    // The record can vanish or become unreadable between the lookup and the
    // read; either reads as missing and gets the unknown-job error.
    std::fs::read_to_string(path).ok()
}

/// No record in any searched directory: name the id and every directory tried,
/// keeping the `unknown job <id>` prefix existing tests match.
fn missing_record(id: &str) -> Usage {
    let mut searched = search_dirs();
    if let Some(locator) = locator_path(id)
        && let Some(parent) = locator.parent()
    {
        searched.push(parent.to_path_buf());
    }
    if let Some(target) = locator_record_path(id)
        && let Some(parent) = target.parent()
    {
        searched.push(parent.to_path_buf());
    }
    let mut seen = std::collections::HashSet::new();
    searched.retain(|path| seen.insert(path.clone()));
    let dirs = searched
        .iter()
        .map(|d| d.display().to_string())
        .collect::<Vec<_>>()
        .join(", ");
    Usage(format!(
        "unknown job {id} (searched: {dirs}); the record may have been cleared by a reboot or a different TMPDIR, so set DELEGATE_JOBS_DIR to the directory the job ran under."
    ))
}

/// The stored age is as of `lastHeartbeatAt`, so `watch` adds the time since
/// that heartbeat. Records from an older supervisor carry no stored age and
/// give no note. A heartbeat newer than now (a clock step) adds nothing.
fn last_event_note(record: &serde_json::Value, now_ms: f64) -> Option<String> {
    let stored_ms = record["progress"]["lastEventAgeMs"].as_f64()?;
    let heartbeat_ms = record["lastHeartbeatAt"].as_f64().unwrap_or(now_ms);
    let extra_ms = (now_ms - heartbeat_ms).max(0.0);
    let total_ms = stored_ms + extra_ms;
    Some(format!("last event {}s ago", (total_ms / 1000.0).floor()))
}

fn watch_now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}

/// Build the status output, including a commit-and-gate recommendation for an ERROR record
/// with changed files but no commits.
fn status_line(id: &str, rec: &serde_json::Value) -> String {
    let state = rec
        .get("status")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("UNKNOWN");
    let result = rec.get("result").filter(|value| value.is_object());
    let change_set = result.and_then(|value| value.get("changeSet"));
    let complete_uncommitted_tree = state == "ERROR"
        && change_set
            .and_then(|value| value.get("filesChanged"))
            .and_then(serde_json::Value::as_array)
            .is_some_and(|files| !files.is_empty())
        && change_set
            .and_then(|value| value.get("newCommits"))
            .and_then(serde_json::Value::as_array)
            .is_some_and(Vec::is_empty);
    let mut parts = Vec::new();
    if let Some(caller) = rec.get("caller").and_then(serde_json::Value::as_str)
        && !caller.is_empty()
    {
        parts.push(format!("caller={caller}"));
    }

    if result
        .and_then(|value| value.get("gateResult"))
        .and_then(|gate| gate.get("refused"))
        .and_then(serde_json::Value::as_bool)
        == Some(true)
    {
        parts.push("gate refused, nothing tested".to_string());
    }

    if state != "DONE"
        && state != "RUNNING"
        && let Some(text) = result
            .and_then(|value| value.get("text"))
            .and_then(serde_json::Value::as_str)
            .and_then(|text| {
                text.split(['\n', '\r'])
                    .map(str::trim)
                    .find(|line| !line.is_empty())
            })
    {
        parts.push(text.to_string());
    }

    if state != "RUNNING"
        && let Some(files) = result
            .and_then(|value| value.get("changeSet"))
            .and_then(|change_set| change_set.get("filesChanged"))
            .and_then(serde_json::Value::as_array)
            .filter(|files| !files.is_empty())
    {
        let file_count = files.len();
        let mut changes = format!(
            "{file_count} file{} changed",
            if file_count == 1 { "" } else { "s" }
        );
        let uncommitted =
            result
                .and_then(|value| value.get("changeSet"))
                .is_some_and(|change_set| {
                    change_set
                        .get("uncommittedFiles")
                        .and_then(serde_json::Value::as_array)
                        .is_some_and(|files| !files.is_empty())
                        || change_set
                            .get("dirtyAfter")
                            .and_then(serde_json::Value::as_bool)
                            == Some(true)
                });
        if uncommitted {
            changes.push_str(", uncommitted");
        }
        let commit_count = result
            .and_then(|value| value.get("changeSet"))
            .and_then(|change_set| change_set.get("newCommits"))
            .and_then(serde_json::Value::as_array)
            .map_or(0, Vec::len);
        changes.push_str(&format!(
            ", {commit_count} commit{}",
            if commit_count == 1 { "" } else { "s" }
        ));
        parts.push(changes);
    }

    let status = if parts.is_empty() {
        format!("{id}: {state}")
    } else {
        format!("{id}: {state} ({})", parts.join("; "))
    };
    if complete_uncommitted_tree {
        format!("uncommitted complete tree: commit and run the gate; do not resume\n{status}")
    } else {
        status
    }
}

/// `status` prints the job's state at once and adds available result text and
/// change details on the same line for finished jobs. It never waits: any known
/// job exits 0, whatever its state. Unknown ids reuse `watch`'s `missing_record` error.
fn status(args: &[String]) -> Result<i32, Usage> {
    let (_, pos) = parse(args, &[])?;
    let [id] = pos.as_slice() else {
        return usage(USAGE);
    };
    settle_dead_supervisor(id);
    let Some(raw) = read_record(id) else {
        return Err(missing_record(id));
    };
    let rec: serde_json::Value =
        serde_json::from_str(&raw).map_err(|e| Usage(format!("cannot read job {id}: {e}")))?;
    println!("{}", status_line(id, &rec));
    Ok(0)
}

fn ack(args: &[String]) -> Result<i32, Usage> {
    let any = args.iter().any(|arg| arg == "--any");
    let ids: Vec<_> = args.iter().filter(|arg| arg.as_str() != "--any").collect();
    if ids.is_empty() {
        return usage(USAGE);
    }

    let (ack_cwd, caller_label) = if any {
        (None, None)
    } else {
        (
            caller_cwd(),
            std::env::var("DELEGATE_CALLER")
                .ok()
                .filter(|caller| !caller.is_empty()),
        )
    };
    let mut valid_ids = Vec::with_capacity(ids.len());
    let mut errors = Vec::new();
    for id in ids {
        if !valid_job_id(id) {
            errors.push(format!("invalid job id {id}"));
            continue;
        }
        let Some(raw) = read_record(id) else {
            errors.push(missing_record(id).0);
            continue;
        };
        if !any {
            let record: serde_json::Value = match serde_json::from_str(&raw) {
                Ok(record) => record,
                Err(error) => {
                    errors.push(format!("cannot read job {id}: {error}"));
                    continue;
                }
            };
            match record.get("callerCwd").and_then(serde_json::Value::as_str) {
                Some(record_cwd) => match ack_cwd.as_deref() {
                    Some(ack_cwd) if cwd_paths_related(record_cwd, ack_cwd) => {}
                    Some(ack_cwd) => errors.push(format!(
                        "job {id} cwd check failed: record cwd {record_cwd} is unrelated to caller cwd {ack_cwd}; use --any to override"
                    )),
                    None => errors.push(format!(
                        "job {id} cwd check failed: acknowledgement caller cwd is unavailable; use --any to override"
                    )),
                },
                None => errors.push(format!(
                    "job {id} cwd check failed: record has no callerCwd; use --any to override"
                )),
            }
            if let Some(caller) = caller_label.as_deref()
                && !record
                    .get("caller")
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|record_caller| caller_label_matches(record_caller, caller))
            {
                let record_caller = record
                    .get("caller")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("<missing>");
                errors.push(format!(
                    "job {id} caller check failed: caller label {caller} does not match record caller {record_caller}; use --any to override"
                ));
            }
        }
        valid_ids.push(id);
    }
    if !errors.is_empty() {
        return Err(Usage(errors.join("\n")));
    }

    let paths: Vec<_> = valid_ids
        .iter()
        .map(|id| read_marker_path(id))
        .collect::<Option<_>>()
        .ok_or_else(|| Usage("no absolute cache root for read markers".to_string()))?;
    for path in paths {
        let result = (|| {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(&path)
        })();
        if let Err(error) = result {
            eprintln!("cannot write read marker {}: {error}", path.display());
            return Ok(1);
        }
    }
    Ok(0)
}

/// Under Claude Code short `watch` waits run in the background, so a `--timeout`
/// below 600 s is dropped and the wait runs without a timeout; every other
/// input passes through unchanged, and 600 itself is honoured.
fn effective_watch_timeout(secs: Option<f64>, claudecode: bool) -> Option<f64> {
    if claudecode && secs.is_some_and(|t| t < 600.0) {
        None
    } else {
        secs
    }
}

fn watch(args: &[String]) -> Result<i32, Usage> {
    let (kv, ids) = parse(args, &["--timeout"])?;
    if ids.is_empty() {
        return usage(USAGE);
    }
    if let Some(id) = ids.iter().find(|id| current_job_contains(id)) {
        return usage(format!(
            "delegate watch: refusing to watch {id}: it is the job this process runs inside (DELEGATE_JOB_ID/DELEGATE_JOB_CHAIN); report to your orchestrator instead"
        ));
    }
    let timeout_arg = flag(&kv, "--timeout");
    let secs = match timeout_arg {
        None => None,
        Some(s) => match s.parse::<f64>() {
            Ok(t) if t >= 0.0 => Some(t),
            _ => return usage(format!("invalid --timeout {s}")),
        },
    };
    // A short wait under Claude Code runs in the background without a timeout.
    let claudecode = std::env::var_os("CLAUDECODE").is_some_and(|v| !v.is_empty());
    let effective = effective_watch_timeout(secs, claudecode);
    if secs.is_some() && effective.is_none() {
        let s = timeout_arg.expect("timeout ignored without a --timeout");
        eprintln!(
            "delegate watch: --timeout {s} ignored under Claude Code (waits run in the background); waiting without a timeout"
        );
    }
    let timeout = effective.map(Duration::from_secs_f64);
    // An id is a file stem; a separator would escape the jobs directory.
    if let Some(id) = ids
        .iter()
        .find(|i| i.contains('/') || read_record(i).is_none())
    {
        return Err(missing_record(id));
    }
    let start = Instant::now();
    loop {
        for id in &ids {
            settle_dead_supervisor(id);
        }
        // A read can land on no file only if the record was deleted under us; treat as running.
        let recs: Vec<Option<serde_json::Value>> = ids
            .iter()
            .map(|i| read_record(i).and_then(|s| serde_json::from_str(&s).ok()))
            .collect();
        let all_done = recs
            .iter()
            .all(|r| r.as_ref().is_some_and(|v| v["status"] != "RUNNING"));
        let timed_out = timeout.is_some_and(|t| start.elapsed() >= t);
        if all_done || timed_out {
            for r in recs.iter().flatten() {
                println!("{r}");
            }
            if timed_out {
                let elapsed = format!("{}s", timeout_arg.expect("timeout elapsed without timeout"));
                for (id, record) in ids.iter().zip(&recs) {
                    let Some(record) = record.as_ref().filter(|r| r["status"] == "RUNNING") else {
                        continue;
                    };
                    let progress = &record["progress"];
                    let mut details = Vec::new();
                    if let Some(phase) = progress["phase"].as_str() {
                        details.push(format!("phase {phase}"));
                    }
                    if let Some(tool) = progress["lastTool"].as_str() {
                        details.push(format!("last tool {tool}"));
                    }
                    if let Some(note) = last_event_note(record, watch_now_ms()) {
                        details.push(note);
                    }
                    let details = if details.is_empty() {
                        String::new()
                    } else {
                        format!(" ({})", details.join(", "))
                    };
                    eprintln!(
                        "delegate watch: timed out after {elapsed}; {id} still RUNNING{details}; see its progress field; run watch again"
                    );
                }
            }
            return Ok(if all_done { 0 } else { 1 });
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// `kill(pid, 0)` fails with `ESRCH` only when the process is gone. `EPERM` means it exists.
fn process_missing(pid: i32) -> bool {
    let rc = unsafe { libc::kill(pid, 0) };
    rc != 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

/// A RUNNING record whose supervisor has died is terminal: rewrite it once and let the
/// caller print the ERROR record. Re-read after the liveness check so a supervisor that
/// finished and exited in between is not overwritten.
///
/// ponytail: pid-only liveness. A reused pid hides a dead supervisor; add a heartbeat-age check if that shows up.
fn settle_dead_supervisor(id: &str) {
    let Some(v) = read_record(id).and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
    else {
        return;
    };
    if v["status"] != "RUNNING" {
        return;
    }
    let Some(pid) = v["supervisorPid"].as_i64() else {
        return;
    };
    if pid <= 0 || pid > i32::MAX as i64 || !process_missing(pid as i32) {
        return;
    }
    let Some(v) = read_record(id).and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
    else {
        return;
    };
    if v["status"] != "RUNNING" {
        return;
    }
    if let Err(e) = write_supervisor_died(id, &v) {
        eprintln!(
            "cannot write status record {}: {e}",
            record_path(id).display()
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::status_record::CliResume;

    #[test]
    fn canonicalizes_missing_tail_parent_components() {
        let root = std::env::temp_dir().join(format!(
            "delegate-canonicalize-missing-tail-{}",
            random_uuid()
        ));
        let real = root.join("real");
        std::fs::create_dir_all(&real).unwrap();
        let canonical_real = std::fs::canonicalize(&real).unwrap();

        let normalized = canonicalize_with_missing_tail(&real.join("gone/../../x"));
        assert!(
            !normalized.starts_with(&canonical_real),
            "{normalized:?} should not remain under {canonical_real:?}"
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    fn kv(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn model_ruling_requires_a_github_comment_url() {
        for url in [
            "https://github.com/example/repo/issues/1686#issuecomment-6844642628",
            "https://github.com/example/repo/pull/42#issuecomment-123456",
        ] {
            assert_eq!(validate_model_ruling(Some(url)), Ok(()), "{url}");
        }
        for url in [
            "https://github.com/example/repo/issues/42",
            "http://github.com/example/repo/issues/42#issuecomment-123456",
            "https://example.com/example/repo/issues/42#issuecomment-123456",
            "https://github.com/example/repo/issues/42#issuecomment-123456trailing",
        ] {
            assert!(validate_model_ruling(Some(url)).is_err(), "accepted {url}");
        }
        assert_eq!(validate_model_ruling(None), Ok(()));
    }

    #[test]
    fn hidden_supervisor_refuses_an_unruled_off_pool_model_before_backend_start() {
        use crate::test_env::{EnvGuard, lock};

        let _env = lock();
        let root =
            std::env::temp_dir().join(format!("delegate-supervisor-refusal-{}", random_uuid()));
        let jobs = root.join("jobs");
        let _jobs = EnvGuard::set("DELEGATE_JOBS_DIR", jobs.to_str().unwrap());
        let _profile = EnvGuard::set(
            "DELEGATE_HOST_PROFILE",
            root.join("missing-profile.json").to_str().unwrap(),
        );
        let job_id = "unruled-off-pool";
        let args = [
            job_id,
            "openai/gpt-6.1-sol",
            "/tmp",
            "--caller",
            "test",
            "--caller-pid",
            "1",
        ]
        .map(String::from);
        std::fs::create_dir_all(&jobs).unwrap();
        std::fs::write(job_record_path(job_id).with_extension("prompt"), "prompt").unwrap();

        assert_eq!(supervise(&args), 1);
        assert!(!job_record_path(job_id).exists());
        assert!(!job_record_path(job_id).with_extension("prompt").exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn add_dir_accepts_repeated_existing_directories() {
        let root = std::env::temp_dir().join(format!("delegate-add-dir-{}", random_uuid()));
        let first = root.join("first");
        let second = root.join("second");
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();
        let args = vec![
            "--add-dir".into(),
            first.to_string_lossy().into_owned(),
            "--add-dir".into(),
            second.to_string_lossy().into_owned(),
        ];
        let (kv, pos) =
            parse(&args, &["--add-dir"]).unwrap_or_else(|Usage(message)| panic!("{message}"));
        assert!(pos.is_empty());
        assert_eq!(
            add_directories(&kv, "fiber").unwrap_or_else(|Usage(message)| panic!("{message}")),
            [
                resolve_path(first.to_str().unwrap()),
                resolve_path(second.to_str().unwrap())
            ]
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn add_dir_rejects_a_missing_path_before_launch() {
        let missing = resolve_path(&format!("/tmp/delegate-add-dir-missing-{}", random_uuid()));
        let parsed = vec![("--add-dir".into(), missing.clone())];
        let Err(Usage(message)) = add_directories(&parsed, "fiber") else {
            panic!("a missing add-dir path must be a usage error");
        };
        assert_eq!(message, format!("add-dir {missing} is not a directory"));
    }

    #[test]
    fn add_dir_is_rejected_for_non_fiber_backends() {
        let parsed = vec![("--add-dir".into(), "/tmp".into())];
        let Err(Usage(message)) = add_directories(&parsed, "cursor") else {
            panic!("--add-dir must be refused for non-Fiber models");
        };
        assert_eq!(message, "--add-dir is only supported by the fiber backend");
    }

    #[test]
    fn idle_ms_flag_parses_a_positive_number() {
        let args: Vec<String> = ["--idle-ms", "1200000"].map(String::from).to_vec();
        let Ok((parsed, pos)) = parse(&args, &["--idle-ms"]) else {
            panic!("--idle-ms must be a known run flag");
        };
        assert!(pos.is_empty());
        assert_eq!(
            positive_ms_flag(&parsed, "--idle-ms"),
            Ok(Some(1_200_000.0))
        );
        assert_eq!(positive_ms_flag(&[], "--idle-ms"), Ok(None));
    }

    #[test]
    fn idle_ms_flag_rejects_non_numbers_zero_and_negatives() {
        for bad in ["abc", "0", "-5", "NaN", "inf"] {
            let parsed = kv(&[("--idle-ms", bad)]);
            assert_eq!(
                positive_ms_flag(&parsed, "--idle-ms"),
                Err(format!("invalid --idle-ms {bad}"))
            );
        }
    }

    #[test]
    fn run_rejects_a_bad_idle_ms_before_it_starts_anything() {
        let args: Vec<String> = ["--model", "x", "--idle-ms", "0"]
            .map(String::from)
            .to_vec();
        let Err(Usage(msg)) = run(&args) else {
            panic!("a zero --idle-ms must be a usage error");
        };
        assert_eq!(msg, "invalid --idle-ms 0");
    }

    #[test]
    fn run_rejects_a_bad_wall_ms_before_it_starts_anything() {
        for bad in ["0", "-5", "abc", "NaN", "inf"] {
            let args: Vec<String> = ["--model", "x", "--wall-ms", bad]
                .map(String::from)
                .to_vec();
            let Err(Usage(msg)) = run(&args) else {
                panic!("a bad --wall-ms {bad} must be a usage error");
            };
            assert_eq!(msg, format!("invalid --wall-ms {bad}"));
        }
    }

    #[test]
    fn wall_ms_flag_parses_a_positive_number() {
        for good in ["1", "600000", "1e6"] {
            let parsed = kv(&[("--wall-ms", good)]);
            let got = positive_ms_flag(&parsed, "--wall-ms");
            assert!(matches!(got, Ok(Some(_))), "{good}: {got:?}");
            assert_eq!(positive_ms_flag(&[], "--wall-ms"), Ok(None));
        }
    }

    #[test]
    fn resume_timing_flags_override_stored_values() {
        for (name, stored, passed) in [
            ("--tool-idle-ms", 1_200_000.0, "2400000"),
            ("--idle-ms", 900_000.0, "1800000"),
            ("--wall-ms", 10_800_000.0, "21600000"),
        ] {
            let parsed = kv(&[(name, passed)]);
            let expected = passed.parse::<f64>().unwrap();
            assert_eq!(
                resume_ms_flag(&parsed, name, Some(stored)),
                Ok(Some(expected))
            );
        }
    }

    #[test]
    fn resume_timing_flags_keep_stored_values_when_omitted() {
        for (name, stored) in [
            ("--tool-idle-ms", 1_200_000.0),
            ("--idle-ms", 900_000.0),
            ("--wall-ms", 10_800_000.0),
        ] {
            assert_eq!(resume_ms_flag(&[], name, Some(stored)), Ok(Some(stored)));
            assert_eq!(resume_ms_flag(&[], name, None), Ok(None));
        }
    }

    #[test]
    fn resume_timing_flags_reject_zero_and_non_numeric_values() {
        for name in ["--tool-idle-ms", "--idle-ms", "--wall-ms"] {
            for bad in ["0", "not-a-number"] {
                let parsed = kv(&[(name, bad)]);
                assert_eq!(
                    resume_ms_flag(&parsed, name, Some(123.0)),
                    Err(format!("invalid {name} {bad}"))
                );
            }
        }
    }

    #[test]
    fn resume_record_keeps_idle_ms_under_resume_as_idle_ms() {
        let resume = CliResume {
            model: "muse/m".into(),
            model_ruling: Some("https://github.com/example/repo/issues/1#issuecomment-2".into()),
            backend: Some("muse".into()),
            cwd: "/tmp".into(),
            session_id: None,
            gate: String::new(),
            tool_idle_ms: None,
            idle_ms: Some(1_200_000.0),
            wall_ms: None,
            add_dirs: vec!["/tmp/additional".into()],
        };
        let rec = serde_json::to_value(&resume).unwrap();
        // `resume()` reads these values back for the next run.
        assert_eq!(
            rec["modelRuling"],
            "https://github.com/example/repo/issues/1#issuecomment-2"
        );
        assert_eq!(rec["idleMs"].as_f64(), Some(1_200_000.0));
        assert_eq!(rec["addDirs"], serde_json::json!(["/tmp/additional"]));
        assert!(rec.get("toolIdleMs").is_some());
        assert!(rec["wallMs"].is_null());

        let capped = CliResume {
            wall_ms: Some(10_800_000.0),
            ..resume.clone()
        };
        let rec = serde_json::to_value(&capped).unwrap();
        // No `.0`: the record keeps the number compact.
        assert_eq!(rec["wallMs"], serde_json::json!(10_800_000));
        assert_eq!(rec["idleMs"].as_f64(), Some(1_200_000.0));

        let unset = CliResume {
            idle_ms: None,
            ..resume
        };
        let rec = serde_json::to_value(&unset).unwrap();
        assert!(rec["idleMs"].is_null());
    }

    fn running_record_with(age_ms: f64, heartbeat_ms: Option<f64>) -> serde_json::Value {
        let mut progress = serde_json::json!({"lastEventAgeMs": age_ms});
        if age_ms.is_nan() {
            progress = serde_json::json!({});
        }
        let mut record = serde_json::json!({"status": "RUNNING", "progress": progress});
        if let Some(h) = heartbeat_ms {
            record["lastHeartbeatAt"] = serde_json::json!(h);
        }
        record
    }

    #[test]
    fn last_event_note_adds_the_time_since_the_heartbeat() {
        let record = running_record_with(2000.0, Some(10_000.0));
        assert_eq!(
            last_event_note(&record, 13_000.0),
            Some("last event 5s ago".to_string())
        );
    }

    #[test]
    fn last_event_note_floors_to_whole_seconds() {
        let record = running_record_with(1999.0, Some(10_000.0));
        assert_eq!(
            last_event_note(&record, 13_000.0),
            Some("last event 4s ago".to_string())
        );
    }

    #[test]
    fn last_event_note_is_absent_without_a_stored_age() {
        let record = running_record_with(f64::NAN, Some(10_000.0));
        assert_eq!(last_event_note(&record, 13_000.0), None);
    }

    #[test]
    fn effective_watch_timeout_keeps_none_without_a_flag() {
        assert_eq!(
            effective_watch_timeout(None, true),
            None,
            "(None, true) stays None"
        );
        assert_eq!(
            effective_watch_timeout(None, false),
            None,
            "(None, false) stays None"
        );
    }

    #[test]
    fn effective_watch_timeout_honours_every_value_off_claude_code() {
        assert_eq!(
            effective_watch_timeout(Some(5.0), false),
            Some(5.0),
            "(Some(5.0), false) is honoured"
        );
        assert_eq!(
            effective_watch_timeout(Some(0.0), false),
            Some(0.0),
            "(Some(0.0), false) is honoured"
        );
    }

    #[test]
    fn effective_watch_timeout_drops_short_timeouts_on_claude_code() {
        assert_eq!(
            effective_watch_timeout(Some(599.0), true),
            None,
            "(Some(599.0), true) is ignored"
        );
        assert_eq!(
            effective_watch_timeout(Some(599.9), true),
            None,
            "(Some(599.9), true) is ignored"
        );
        assert_eq!(
            effective_watch_timeout(Some(0.0), true),
            None,
            "(Some(0.0), true) is ignored"
        );
    }

    #[test]
    fn effective_watch_timeout_honours_600_and_above_on_claude_code() {
        assert_eq!(
            effective_watch_timeout(Some(600.0), true),
            Some(600.0),
            "(Some(600.0), true) is honoured"
        );
        assert_eq!(
            effective_watch_timeout(Some(601.0), true),
            Some(601.0),
            "(Some(601.0), true) is honoured"
        );
    }

    #[test]
    fn last_event_note_ignores_a_heartbeat_newer_than_now() {
        let record = running_record_with(2000.0, Some(10_000.0));
        assert_eq!(
            last_event_note(&record, 9_000.0),
            Some("last event 2s ago".to_string())
        );
        let no_heartbeat = running_record_with(2000.0, None);
        assert_eq!(
            last_event_note(&no_heartbeat, 13_000.0),
            Some("last event 2s ago".to_string())
        );
    }
}
