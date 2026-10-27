pub mod inbox;
pub mod ipc;
pub mod msp;
pub mod state;
pub mod supervisor;

use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::{self, IsTerminal, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const EXIT_OK: i32 = 0;
pub const EXIT_FAILED: i32 = 1;
pub const EXIT_USAGE: i32 = 2;
pub const EXIT_NO_SESSION: i32 = 3;
pub const EXIT_DEAD: i32 = 4;
pub const EXIT_BUSY: i32 = 5;
pub const START_WAIT: u64 = 45_000;
pub const CLIENT_TIMEOUT: u64 = 90_000;
const START_POLL: u64 = 20;
const WATCH_POLL: u64 = 50;
const LOGS_POLL: u64 = 100;

#[derive(Debug)]
struct SessionError {
    code: &'static str,
    message: String,
    exit: i32,
}

type Result<T> = std::result::Result<T, SessionError>;

pub fn main(args: &[String]) -> i32 {
    if args.first().map(String::as_str) == Some("__supervise") {
        if args.len() != 2 {
            eprintln!("session supervisor requires one id");
            return EXIT_USAGE;
        }
        std::panic::set_hook(Box::new(|_| std::process::exit(101)));
        let paths = state::Paths::new(state::Paths::default_root());
        return supervisor::run(supervisor::SupervisorConfig::from_env(paths), &args[1]);
    }

    if help_requested(args) || args.first().map(String::as_str) == Some("help") {
        println!("{}", crate::cli::USAGE);
        return EXIT_OK;
    }
    let json_mode = json_requested(args);
    let Some((verb, rest)) = args.split_first() else {
        return fail(json_mode, usage("delegate session requires a verb"));
    };
    let result = match verb.as_str() {
        "start" => start(rest, json_mode),
        "send" => send(rest, json_mode),
        "logs" => logs(rest, json_mode),
        "watch" => watch(rest, json_mode),
        "stop" => stop(rest, json_mode),
        "list" => list_sessions(rest, json_mode),
        other => Err(usage(format!("unknown session verb {other}"))),
    };
    match result {
        Ok(code) => code,
        Err(error) => fail(json_mode, error),
    }
}

fn usage(message: impl Into<String>) -> SessionError {
    SessionError {
        code: "usage",
        message: message.into(),
        exit: EXIT_USAGE,
    }
}

fn failed(message: impl Into<String>) -> SessionError {
    SessionError {
        code: "failed",
        message: message.into(),
        exit: EXIT_FAILED,
    }
}

fn failure(code: &str, message: impl Into<String>) -> SessionError {
    let (code, exit) = error_exit_code(code);
    SessionError {
        code,
        message: message.into(),
        exit,
    }
}

fn fail(json_mode: bool, error: SessionError) -> i32 {
    eprintln!("{}", error.message);
    if json_mode {
        println!("{}", json_error_json(error.code, &error.message));
    }
    error.exit
}

fn error_exit_code(code: &str) -> (&'static str, i32) {
    match code {
        "usage" => ("usage", EXIT_USAGE),
        "noSession" => ("noSession", EXIT_NO_SESSION),
        "dead" => ("dead", EXIT_DEAD),
        "busy" => ("busy", EXIT_BUSY),
        _ => ("failed", EXIT_FAILED),
    }
}

fn json_error_json(code: &str, message: &str) -> Value {
    json!({"ok":false,"error":{"code":code,"message":message}})
}

fn json_requested(args: &[String]) -> bool {
    args.iter()
        .take_while(|arg| arg.as_str() != "--")
        .any(|arg| arg == "--json")
}

fn help_requested(args: &[String]) -> bool {
    args.iter()
        .take_while(|arg| arg.as_str() != "--")
        .any(|arg| matches!(arg.as_str(), "--help" | "-h"))
}

fn parse_send_args(args: &[String]) -> std::result::Result<(String, bool), String> {
    let mut positional = Vec::new();
    let mut json_mode = false;
    let mut after_separator = false;
    for arg in args {
        if after_separator {
            positional.push(arg.clone());
            continue;
        }
        match arg.as_str() {
            "--" => after_separator = true,
            "--json" => json_mode = true,
            value if value.starts_with("--") => return Err(format!("unknown flag {value}")),
            value => positional.push(value.to_string()),
        }
    }
    if positional.len() != 1 {
        return Err("send takes one TEXT; quote it, or pass - for stdin".into());
    }
    Ok((positional.remove(0), json_mode))
}

fn parse_flags(
    args: &[String],
    value_flags: &[&str],
    bool_flags: &[&str],
) -> std::result::Result<(Vec<(String, String)>, Vec<String>), String> {
    let mut values = Vec::new();
    let mut positional = Vec::new();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg.starts_with("--") {
            if bool_flags.contains(&arg.as_str()) {
                if values.iter().any(|(name, _)| name == arg) {
                    return Err(format!("duplicate flag {arg}"));
                }
                values.push((arg.clone(), String::new()));
            } else if value_flags.contains(&arg.as_str()) {
                let Some(value) = iter.next() else {
                    return Err(format!("{arg} needs a value"));
                };
                if value.starts_with("--") {
                    return Err(format!("{arg} needs a value"));
                }
                if values.iter().any(|(name, _)| name == arg) {
                    return Err(format!("duplicate flag {arg}"));
                }
                values.push((arg.clone(), value.clone()));
            } else {
                return Err(format!("unknown flag {arg}"));
            }
        } else {
            positional.push(arg.clone());
        }
    }
    Ok((values, positional))
}

fn flag<'a>(values: &'a [(String, String)], name: &str) -> Option<&'a str> {
    values
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.as_str())
}

fn has_flag(values: &[(String, String)], name: &str) -> bool {
    values.iter().any(|(key, _)| key == name)
}

fn validate(bytes: Vec<u8>, label: &str) -> std::result::Result<String, String> {
    if bytes.len() > supervisor::MAX_TEXT {
        return Err(format!(
            "{label} exceeds MAX_TEXT ({} bytes)",
            supervisor::MAX_TEXT
        ));
    }
    let text =
        String::from_utf8(bytes).map_err(|error| format!("{label} is not valid UTF-8: {error}"))?;
    if text.as_bytes().contains(&0) {
        return Err(format!("{label} must not contain NUL"));
    }
    if text.trim().is_empty() {
        return Err(format!("{label} must not be empty or whitespace-only"));
    }
    Ok(text)
}

fn read_text(
    arg: &str,
    stdin: &mut dyn Read,
    stdin_is_terminal: bool,
) -> std::result::Result<String, String> {
    if arg != "-" {
        return validate(arg.as_bytes().to_vec(), "TEXT");
    }
    if stdin_is_terminal {
        return Err("send - cannot read from a terminal; provide TEXT on the command line".into());
    }
    let mut bytes = Vec::new();
    stdin
        .take(supervisor::MAX_TEXT as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("could not read stdin: {error}"))?;
    validate(bytes, "TEXT")
}

fn read_brief(path: &str) -> std::result::Result<String, String> {
    let file_path = Path::new(path);
    let metadata =
        fs::metadata(file_path).map_err(|error| format!("{}: {error}", file_path.display()))?;
    if metadata.len() > supervisor::MAX_TEXT as u64 {
        return Err(format!(
            "brief exceeds MAX_TEXT ({} bytes)",
            supervisor::MAX_TEXT
        ));
    }
    let file =
        File::open(file_path).map_err(|error| format!("{}: {error}", file_path.display()))?;
    let mut bytes = Vec::new();
    file.take(supervisor::MAX_TEXT as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("{}: {error}", file_path.display()))?;
    validate(bytes, "brief")
}

fn start(args: &[String], json_mode: bool) -> Result<i32> {
    let (values, positional) =
        parse_flags(args, &["--model", "--brief", "--inbox"], &["--json"]).map_err(usage)?;
    if !positional.is_empty() {
        return Err(usage("start does not take positional arguments"));
    }
    let model = flag(&values, "--model").ok_or_else(|| usage("start requires --model"))?;
    let brief_path = flag(&values, "--brief").ok_or_else(|| usage("start requires --brief"))?;
    let inbox_path = flag(&values, "--inbox").ok_or_else(|| usage("start requires --inbox"))?;
    let Some(model_id) = model.strip_prefix("muse/") else {
        return Err(usage("--model must use the muse/<model> form"));
    };
    if model_id.is_empty() {
        return Err(usage("--model muse/ requires a model id"));
    }
    if crate::backends::muse::base_and_effort(model).1.is_some() {
        return Err(usage(
            "--model takes no reasoning-effort suffix on a session (sessions run at Muse's default effort)",
        ));
    }
    let brief = read_brief(brief_path).map_err(usage)?;
    let cwd = std::env::current_dir()
        .map_err(|error| failed(format!("could not resolve cwd: {error}")))?;
    let cwd = crate::util::resolve_path(&cwd.to_string_lossy());
    let inbox = crate::util::resolve_path(inbox_path);
    let paths = state::Paths::new(state::Paths::default_root());
    let id = crate::util::random_uuid();
    if let Err(error) = paths.socket_path(&id) {
        return Err(failed(error.to_string()));
    }
    state::create_session_dir(&paths, &id)
        .map_err(|error| failed(format!("could not create session directory: {error}")))?;
    let brief_file = paths.brief_file(&id);
    let write_brief = (|| -> io::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&brief_file)?;
        file.write_all(brief.as_bytes())
    })();
    if let Err(error) = write_brief {
        return Err(failed(format!("{}: {error}", brief_file.display())));
    }
    let mut session = state::new_state(&id, model, &cwd, &inbox, now_ms());
    session.supervisor_pid = None;
    state::write_state(&paths, &session)
        .map_err(|error| failed(format!("could not write session state: {error}")))?;

    let executable = std::env::current_exe()
        .map_err(|error| failed(format!("could not locate delegate executable: {error}")))?;
    let mut command = Command::new(executable);
    command
        .args(["session", "__supervise", &id])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command
        .spawn()
        .map_err(|error| failed(format!("could not start session supervisor: {error}")))?;
    let wait = env_millis("DELEGATE_SESSION_START_WAIT_MS", START_WAIT);
    let poll = env_millis("DELEGATE_SESSION_START_POLL_MS", START_POLL).max(1);
    let deadline = Instant::now() + Duration::from_millis(wait);
    loop {
        let current = state::read_state(&paths, &id)
            .map_err(|error| failed(format!("state unreadable: {error}")))?;
        if current.active_turn_id.is_some()
            || (current.status == state::Status::Idle && current.turn_count >= 1)
        {
            if json_mode {
                println!("{}", json!({"ok":true,"session":current}));
            } else {
                println!("{id}");
            }
            return Ok(EXIT_OK);
        }
        if current.status == state::Status::Dead {
            return Err(failed(
                current
                    .dead
                    .map(|dead| dead.message)
                    .unwrap_or_else(|| "session died during startup".into()),
            ));
        }
        if let Some(status) = child
            .try_wait()
            .map_err(|error| failed(format!("could not wait for supervisor: {error}")))?
        {
            let fresh = state::read_state(&paths, &id).ok();
            if let Some(fresh) = fresh.filter(|current| current.status == state::Status::Dead) {
                return Err(failed(
                    fresh
                        .dead
                        .map(|dead| dead.message)
                        .unwrap_or_else(|| "session supervisor exited".into()),
                ));
            }
            state::reap_recorded_host(&paths, &id);
            mark_start_failed(
                &paths,
                &id,
                child.id(),
                format!("session supervisor exited before first turn ({status})"),
            );
            return Err(failed("session supervisor exited before first turn"));
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            state::reap_recorded_host(&paths, &id);
            mark_start_failed(&paths, &id, child.id(), "session startup timed out".into());
            return Err(failed("session startup timed out"));
        }
        thread::sleep(Duration::from_millis(poll));
    }
}

fn mark_start_failed(paths: &state::Paths, id: &str, supervisor_pid: u32, message: String) {
    if let Ok(mut current) = state::read_state(paths, id)
        && current.status != state::Status::Dead
        && current.dead.is_none()
    {
        // A supervisor that never published its pid leaves no way to find a
        // stray process, so record the parent's child pid; a published pid
        // is never overwritten.
        if current.supervisor_pid.is_none() {
            current.supervisor_pid = Some(supervisor_pid as i32);
        }
        state::mark_dead(
            &mut current,
            state::DeadReason::StartFailed,
            None,
            &message,
            now_ms(),
        );
        let _ = state::write_state(paths, &current);
    }
}

fn send(args: &[String], json_mode: bool) -> Result<i32> {
    if args.is_empty() {
        return Err(usage("send requires a session id and TEXT"));
    }
    let id = &args[0];
    if !state::valid_id(id) {
        return Err(usage("invalid session id"));
    }
    let paths = default_paths();
    let _current = load_and_settle(&paths, id)?;
    let (argument, parsed_json) = parse_send_args(&args[1..]).map_err(usage)?;
    let json_mode = json_mode || parsed_json;
    let text = if argument == "-" {
        read_text("-", &mut io::stdin(), io::stdin().is_terminal()).map_err(usage)?
    } else {
        read_text(&argument, &mut io::empty(), false).map_err(usage)?
    };
    let reply = ipc::request(
        &paths,
        id,
        &json!({"op":"send","text":text}),
        Duration::from_millis(CLIENT_TIMEOUT),
    )
    .map_err(|error| request_error(&paths, id, error))?;
    if reply.get("ok") != Some(&Value::Bool(true)) {
        return Err(reply_error(&reply));
    }
    let disposition = reply["disposition"].as_str().unwrap_or("started");
    let session = state::read_state(&paths, id)
        .map_err(|error| failed(format!("state unreadable: {error}")))?;
    if json_mode {
        println!(
            "{}",
            json!({"ok":true,"disposition":disposition,"session":session})
        );
    } else {
        println!("{disposition}");
    }
    Ok(EXIT_OK)
}

fn stop(args: &[String], json_mode: bool) -> Result<i32> {
    let (values, positional) = parse_flags(args, &[], &["--interrupt", "--json"]).map_err(usage)?;
    if positional.len() != 1 {
        return Err(usage("stop requires one session id"));
    }
    let id = &positional[0];
    if !state::valid_id(id) {
        return Err(usage("invalid session id"));
    }
    let paths = default_paths();
    let current = load_and_settle(&paths, id)?;
    let interrupt = has_flag(&values, "--interrupt");
    let json_mode = json_mode || has_flag(&values, "--json");
    if current.status == state::Status::Dead {
        if interrupt {
            return Err(failure("dead", "session is dead"));
        }
        print_stopped(&current, json_mode);
        return Ok(EXIT_OK);
    }
    let reply = match ipc::request(
        &paths,
        id,
        &json!({"op":"stop","interrupt":interrupt}),
        Duration::from_millis(CLIENT_TIMEOUT),
    ) {
        Ok(reply) => reply,
        Err(error) => {
            let error = request_error(&paths, id, error);
            if !interrupt && error.code == "dead" {
                let session = state::read_state(&paths, id)
                    .map_err(|read_error| failed(format!("state unreadable: {read_error}")))?;
                print_stopped(&session, json_mode);
                return Ok(EXIT_OK);
            }
            return Err(error);
        }
    };
    if reply.get("ok") != Some(&Value::Bool(true)) {
        return Err(reply_error(&reply));
    }
    let interrupted = reply
        .get("interrupted")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let session = state::read_state(&paths, id)
        .map_err(|error| failed(format!("state unreadable: {error}")))?;
    if json_mode {
        println!(
            "{}",
            json!({"ok":true,"interrupted":interrupted,"session":session})
        );
    } else if interrupt {
        println!("{}", if interrupted { "interrupted" } else { "idle" });
    } else {
        println!("stopped");
    }
    Ok(EXIT_OK)
}

fn print_stopped(session: &state::State, json_mode: bool) {
    if json_mode {
        println!(
            "{}",
            json!({"ok":true,"interrupted":false,"session":session})
        );
    } else {
        println!("stopped");
    }
}

fn watch(args: &[String], json_mode: bool) -> Result<i32> {
    let (values, positional) = parse_flags(args, &[], &["--json"]).map_err(usage)?;
    if positional.len() != 1 {
        return Err(usage("watch requires one session id"));
    }
    let id = &positional[0];
    if !state::valid_id(id) {
        return Err(usage("invalid session id"));
    }
    let json_mode = json_mode || has_flag(&values, "--json");
    let paths = default_paths();
    loop {
        let current = load_and_settle(&paths, id)?;
        if current.status != state::Status::Running {
            if json_mode {
                println!("{}", json!({"ok":true,"session":current}));
            } else {
                println!("{id} {}", status_name(&current.status));
            }
            return Ok(if current.status == state::Status::Dead {
                EXIT_DEAD
            } else {
                EXIT_OK
            });
        }
        signal_test_readiness("DELEGATE_SESSION_TEST_WATCH_READY");
        thread::sleep(Duration::from_millis(WATCH_POLL));
    }
}

fn logs(args: &[String], json_mode: bool) -> Result<i32> {
    let (values, positional) = parse_flags(args, &[], &["--follow", "--json"]).map_err(usage)?;
    if positional.len() != 1 {
        return Err(usage("logs requires one session id"));
    }
    let id = &positional[0];
    if !state::valid_id(id) {
        return Err(usage("invalid session id"));
    }
    let follow = has_flag(&values, "--follow");
    let json_mode = json_mode || has_flag(&values, "--json");
    let paths = default_paths();
    let mut offset = 0usize;
    loop {
        let current = load_and_settle(&paths, id)?;
        let bytes = fs::read(paths.events_file(id))
            .map_err(|error| failed(format!("could not read session logs: {error}")))?;
        let end = bytes
            .iter()
            .rposition(|byte| *byte == b'\n')
            .map(|position| position + 1)
            .unwrap_or(0);
        let end = end.max(offset.min(bytes.len()));
        if !follow {
            let complete = &bytes[..end];
            if json_mode {
                let lines = if complete.is_empty() {
                    Vec::new()
                } else {
                    complete
                        .strip_suffix(b"\n")
                        .unwrap_or(complete)
                        .split(|byte| *byte == b'\n')
                        .map(|line| {
                            serde_json::from_slice::<Value>(line).unwrap_or_else(
                                |_| json!({"kind":"unparsed","text":String::from_utf8_lossy(line)}),
                            )
                        })
                        .collect::<Vec<_>>()
                };
                println!("{}", json!({"ok":true,"lines":lines}));
            } else {
                io::stdout()
                    .write_all(complete)
                    .map_err(|error| failed(format!("could not write logs: {error}")))?;
            }
            return Ok(EXIT_OK);
        }
        if end > offset {
            emit_log_bytes(&bytes[offset..end], json_mode)?;
            offset = end;
        }
        if current.status == state::Status::Dead {
            return Ok(EXIT_OK);
        }
        signal_test_readiness("DELEGATE_SESSION_TEST_LOGS_READY");
        thread::sleep(Duration::from_millis(LOGS_POLL));
    }
}

fn signal_test_readiness(key: &str) {
    let Some(path) = std::env::var_os(key) else {
        return;
    };
    // The black-box tests use this marker after the verb has observed its blocking state.
    let _ = OpenOptions::new().write(true).create_new(true).open(path);
}

fn emit_log_bytes(bytes: &[u8], json_mode: bool) -> Result<()> {
    if !json_mode {
        io::stdout()
            .write_all(bytes)
            .map_err(|error| failed(format!("could not write logs: {error}")))?;
        io::stdout()
            .flush()
            .map_err(|error| failed(format!("could not flush logs: {error}")))?;
        return Ok(());
    }
    let complete = bytes.strip_suffix(b"\n").unwrap_or(bytes);
    for line in complete.split(|byte| *byte == b'\n') {
        let value = serde_json::from_slice::<Value>(line)
            .unwrap_or_else(|_| json!({"kind":"unparsed","text":String::from_utf8_lossy(line)}));
        println!("{}", value);
    }
    Ok(())
}

fn list_sessions(args: &[String], json_mode: bool) -> Result<i32> {
    let (values, positional) = parse_flags(args, &[], &["--json"]).map_err(usage)?;
    if !positional.is_empty() {
        return Err(usage("list does not take positional arguments"));
    }
    let json_mode = json_mode || has_flag(&values, "--json");
    let paths = default_paths();
    let root = state::Paths::default_root();
    let mut entries = Vec::new();
    match fs::read_dir(&root) {
        Ok(dirs) => {
            for entry in dirs.flatten() {
                let id = entry.file_name().to_string_lossy().into_owned();
                if !entry.file_type().is_ok_and(|kind| kind.is_dir()) || !state::valid_id(&id) {
                    continue;
                }
                match state::read_state(&paths, &id) {
                    Ok(_) => {
                        if let Ok(Some(dead)) = state::settle_dead_supervisor(&paths, &id, now_ms())
                        {
                            note_dead_once(&paths, &dead);
                        }
                        match state::read_state(&paths, &id) {
                            Ok(session) => entries.push(state::ListEntry::Session(session)),
                            Err(_) => entries.push(state::ListEntry::Unreadable { id }),
                        }
                    }
                    Err(_) => entries.push(state::ListEntry::Unreadable { id }),
                }
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(failed(format!("could not list sessions: {error}"))),
    }
    entries.sort_by(|left, right| {
        let key = |entry: &state::ListEntry| match entry {
            state::ListEntry::Session(session) => (session.started_at, session.id.clone()),
            state::ListEntry::Unreadable { id } => (u64::MAX, id.clone()),
        };
        key(left).cmp(&key(right))
    });
    if json_mode {
        let sessions: Vec<Value> = entries
            .iter()
            .map(|entry| match entry {
                state::ListEntry::Session(session) => {
                    serde_json::to_value(session).unwrap_or(Value::Null)
                }
                state::ListEntry::Unreadable { id } => json!({"id":id,"status":"unreadable"}),
            })
            .collect();
        println!("{}", json!({"ok":true,"sessions":sessions}));
    } else {
        for entry in entries {
            match entry {
                state::ListEntry::Session(session) => println!(
                    "{} {} {} turns={} {}",
                    session.id,
                    status_name(&session.status),
                    session.model,
                    session.turn_count,
                    session.cwd
                ),
                state::ListEntry::Unreadable { id } => println!("{id} unreadable"),
            }
        }
    }
    Ok(EXIT_OK)
}

fn default_paths() -> state::Paths {
    state::Paths::new(state::Paths::default_root())
}

fn load_and_settle(paths: &state::Paths, id: &str) -> Result<state::State> {
    let current = state::read_state(paths, id).map_err(|error| match error {
        state::StateError::Missing => failure("noSession", format!("no such session {id}")),
        other => failed(format!("state unreadable: {other}")),
    })?;
    match state::settle_dead_supervisor(paths, id, now_ms()) {
        Ok(Some(dead)) => note_dead_once(paths, &dead),
        Ok(None) => {}
        Err(error) => return Err(failed(format!("state unreadable: {error}"))),
    }
    state::read_state(paths, id)
        .map_err(|error| failed(format!("state unreadable: {error}")))
        .or_else(|error| {
            if current.status == state::Status::Dead {
                Ok(current)
            } else {
                Err(error)
            }
        })
}

fn note_dead_once(paths: &state::Paths, session: &state::State) {
    let marker = paths.dir(&session.id).join("dead.noted");
    if OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(marker)
        .is_ok()
    {
        let _ = inbox::notify(
            Path::new(&session.inbox),
            &session.id,
            inbox::Note::Dead,
            now_ms(),
        );
    }
}

fn request_error(paths: &state::Paths, id: &str, error: ipc::IpcError) -> SessionError {
    if let Ok(Some(session)) = state::settle_dead_supervisor(paths, id, now_ms()) {
        note_dead_once(paths, &session);
        return failure("dead", "session is dead");
    }
    if let Ok(session) = state::read_state(paths, id)
        && session.status == state::Status::Dead
    {
        return failure("dead", "session is dead");
    }
    failed(error.to_string())
}

fn reply_error(reply: &Value) -> SessionError {
    let code = reply
        .get("code")
        .and_then(Value::as_str)
        .unwrap_or("failed");
    let message = reply
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("session supervisor rejected request");
    failure(code, message)
}

fn status_name(status: &state::Status) -> &'static str {
    match status {
        state::Status::Running => "running",
        state::Status::Idle => "idle",
        state::Status::Dead => "dead",
    }
}

fn env_millis(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(default)
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct CountingReader {
        count: Arc<AtomicUsize>,
    }

    impl Read for CountingReader {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let count = buffer.len();
            self.count.fetch_add(count, Ordering::Relaxed);
            buffer.fill(b'a');
            Ok(count)
        }
    }

    fn words(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn read_text_checks_stdin_terminal_size_and_content() {
        assert!(read_text("-", &mut Cursor::new(b"x"), true).is_err());
        assert!(read_text("", &mut Cursor::new(b""), false).is_err());
        assert!(read_text("  \n\t", &mut Cursor::new(b""), false).is_err());
        assert!(read_text("-", &mut Cursor::new([0xff]), false).is_err());
        assert!(read_text("a\0b", &mut Cursor::new(b""), false).is_err());
        assert!(
            read_text(
                &"a".repeat(supervisor::MAX_TEXT + 1),
                &mut Cursor::new(b""),
                false
            )
            .is_err()
        );
        let exact = "a".repeat(supervisor::MAX_TEXT);
        assert_eq!(
            read_text(&exact, &mut Cursor::new(b""), false)
                .unwrap()
                .len(),
            supervisor::MAX_TEXT
        );
        assert_eq!(
            read_text("a\u{1b}\r\t b", &mut Cursor::new(b""), false).unwrap(),
            "a\u{1b}\r\t b"
        );
    }

    #[test]
    fn read_text_bounds_an_unending_stdin_reader() {
        let count = Arc::new(AtomicUsize::new(0));
        let mut reader = CountingReader {
            count: count.clone(),
        };
        assert!(read_text("-", &mut reader, false).is_err());
        assert!(count.load(Ordering::Relaxed) <= supervisor::MAX_TEXT + 1);
    }

    #[test]
    fn send_parser_stops_at_separator_and_recognizes_help_before_it() {
        assert_eq!(parse_send_args(&words(&["-"])).unwrap().0, "-");
        assert_eq!(
            parse_send_args(&words(&["--", "-starts-with-dash"]))
                .unwrap()
                .0,
            "-starts-with-dash"
        );
        assert!(parse_send_args(&words(&["--bogus"])).is_err());
        assert!(parse_send_args(&words(&["one", "two"])).is_err());
        assert!(help_requested(&words(&["--help"])));
        assert!(help_requested(&words(&["-h", "ignored"])));
        assert!(!help_requested(&words(&["--", "--help"])));
    }

    #[test]
    fn session_error_codes_are_stable() {
        assert_eq!(
            [
                EXIT_OK,
                EXIT_FAILED,
                EXIT_USAGE,
                EXIT_NO_SESSION,
                EXIT_DEAD,
                EXIT_BUSY
            ],
            [0, 1, 2, 3, 4, 5]
        );
        assert_eq!(error_exit_code("usage"), ("usage", EXIT_USAGE));
        assert_eq!(error_exit_code("noSession"), ("noSession", EXIT_NO_SESSION));
        assert_eq!(error_exit_code("dead"), ("dead", EXIT_DEAD));
        assert_eq!(error_exit_code("busy"), ("busy", EXIT_BUSY));
        assert_eq!(error_exit_code("failed"), ("failed", EXIT_FAILED));
        assert_eq!(error_exit_code("unexpected"), ("failed", EXIT_FAILED));
        assert_eq!(
            json_error_json("noSession", "no such session id"),
            json!({"ok":false,"error":{"code":"noSession","message":"no such session id"}})
        );
    }

    struct FailedSetup {
        paths: state::Paths,
        id: String,
        root: std::path::PathBuf,
    }

    impl Drop for FailedSetup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn failed_setup(mut session: state::State) -> FailedSetup {
        let root = std::env::temp_dir().join(format!(
            "delegate-start-failed-{}",
            crate::util::random_uuid()
        ));
        let paths = state::Paths::new(root.clone());
        let id = crate::util::random_uuid();
        session.id = id.clone();
        state::create_session_dir(&paths, &id).unwrap();
        state::write_state(&paths, &session).unwrap();
        FailedSetup { paths, id, root }
    }

    fn live_state(supervisor_pid: Option<i32>) -> state::State {
        let mut session = state::new_state(
            "placeholder",
            "muse/muse-spark-1.3-contributor",
            "/work",
            "/inbox",
            1000,
        );
        session.supervisor_pid = supervisor_pid;
        session
    }

    #[test]
    fn mark_start_failed_fills_missing_supervisor_pid() {
        let setup = failed_setup(live_state(None));
        mark_start_failed(&setup.paths, &setup.id, 4242, "boom".into());
        let after = state::read_state(&setup.paths, &setup.id).unwrap();
        assert_eq!(after.status, state::Status::Dead);
        let dead = after.dead.expect("dead record written");
        assert_eq!(dead.reason, state::DeadReason::StartFailed);
        assert_eq!(dead.message, "boom");
        assert_eq!(after.supervisor_pid, Some(4242));
    }

    #[test]
    fn mark_start_failed_keeps_published_supervisor_pid() {
        let setup = failed_setup(live_state(Some(4242)));
        mark_start_failed(&setup.paths, &setup.id, 7, "boom".into());
        let after = state::read_state(&setup.paths, &setup.id).unwrap();
        assert_eq!(after.status, state::Status::Dead);
        assert_eq!(after.supervisor_pid, Some(4242));
    }

    #[test]
    fn mark_start_failed_leaves_dead_record_untouched() {
        let mut session = live_state(None);
        state::mark_dead(
            &mut session,
            state::DeadReason::SupervisorDied,
            None,
            "gone",
            1001,
        );
        let before = session.clone();
        let setup = failed_setup(session);
        mark_start_failed(&setup.paths, &setup.id, 4242, "boom".into());
        let after = state::read_state(&setup.paths, &setup.id).unwrap();
        assert_eq!(after.status, before.status);
        assert_eq!(after.dead, before.dead);
        assert_eq!(after.supervisor_pid, before.supervisor_pid);
    }

    #[test]
    fn mark_start_failed_leaves_idle_with_dead_untouched() {
        let mut session = live_state(None);
        session.dead = Some(state::DeadInfo {
            reason: state::DeadReason::SupervisorDied,
            exit_code: None,
            message: "hand-edited".into(),
        });
        let before = session.clone();
        let setup = failed_setup(session);
        mark_start_failed(&setup.paths, &setup.id, 4242, "boom".into());
        let after = state::read_state(&setup.paths, &setup.id).unwrap();
        assert_eq!(after.status, before.status);
        assert_eq!(after.dead, before.dead);
        assert_eq!(after.supervisor_pid, before.supervisor_pid);
    }
}
