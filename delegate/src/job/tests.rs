// Ports of the job-registry tests that still apply to the single-job supervisor.

use super::*;
use crate::backends::types::{BackendResult, Event, ProgressSnapshotRaw, Runner, Spawned};
use crate::output::derive_status;
use crate::status_record::{FileStatusRecordWriter, job_record_path};
use crate::types::{Allowance, PollResult, ResumeContext};
use std::collections::HashMap;
use std::sync::mpsc;
use std::thread::sleep;
use std::time::{Duration, Instant};

pub(crate) fn spec_of(over: impl FnOnce(&mut JobSpec)) -> JobSpec {
    let mut s = JobSpec {
        bin: "agent".into(),
        argv: vec!["run".into()],
        cwd: "/tmp".into(),
        model: "composer-2.5".into(),
        backend: "cursor".into(),
        path: None,
        head_before: None,
        gate: String::new(),
        idle_ms: None,
        tool_idle_ms: None,
        wall_ms: None,
        price_map: HashMap::new(),
        resume_context: ResumeContext {
            model: "composer-2.5".into(),
            gate: String::new(),
        },
    };
    over(&mut s);
    s
}

enum Msg {
    Ev(Event),
    Finish(BackendResult),
}

pub(crate) struct FakeHandle {
    tx: Mutex<mpsc::Sender<Msg>>,
    pub killed: Arc<Mutex<Vec<&'static str>>>,
}

impl FakeHandle {
    pub fn finish(&self, r: BackendResult) {
        let _ = self.tx.lock().unwrap().send(Msg::Finish(r));
    }
    pub fn progress(
        &self,
        tool: &str,
        tokens: f64,
        assistant: Option<&str>,
        files: &[&str],
        phase: Option<&str>,
    ) {
        let snap = ProgressSnapshotRaw {
            last_tool: Some(tool.into()),
            tokens_so_far: tokens,
            last_assistant: assistant.map(Into::into),
            files_touched: files.iter().map(|f| f.to_string()).collect(),
            phase: phase.map(Into::into),
            session_id: None,
        };
        let _ = self.tx.lock().unwrap().send(Msg::Ev(Event::Progress(snap)));
    }
    pub fn session_id(&self, id: &str) {
        let snap = ProgressSnapshotRaw {
            session_id: Some(id.into()),
            ..Default::default()
        };
        let _ = self.tx.lock().unwrap().send(Msg::Ev(Event::Progress(snap)));
    }
    pub fn activity(&self) {
        let _ = self.tx.lock().unwrap().send(Msg::Ev(Event::Activity));
    }
    pub fn killed(&self) -> Vec<&'static str> {
        self.killed.lock().unwrap().clone()
    }
}

#[derive(Default)]
pub(crate) struct FakeBackend {
    handles: Mutex<Vec<Arc<FakeHandle>>>,
    /// The argv of each spawn, in order.
    pub argvs: Mutex<Vec<Vec<String>>>,
    pub auto: Mutex<Option<BackendResult>>,
    /// One result per spawn, in order; each finishes its attempt at once. A spawn past
    /// the end of the script falls back to `auto`, then to a manual handle.
    pub script: Mutex<std::collections::VecDeque<BackendResult>>,
    /// When set, the next kill records SIGTERM but finishes nothing: the child
    /// ignores SIGTERM. One-shot; the kill after it records SIGKILL and finishes.
    pub ignore_first_kill: Arc<Mutex<bool>>,
}

impl FakeBackend {
    pub fn handle(&self, i: usize) -> Arc<FakeHandle> {
        for _ in 0..500 {
            if let Some(h) = self.handles.lock().unwrap().get(i) {
                return Arc::clone(h);
            }
            sleep(Duration::from_millis(2));
        }
        panic!("no handle {i}");
    }
}

impl Runner for FakeBackend {
    fn resume_argv(&self, _model: &str, session: &str, prompt: &str) -> Vec<String> {
        vec!["resume".into(), session.into(), prompt.into()]
    }

    fn run(&self, spec: &JobSpec) -> Spawned {
        self.argvs.lock().unwrap().push(spec.argv.clone());
        let session_id = spec
            .argv
            .windows(2)
            .find(|w| w[0] == "--session-id")
            .map(|w| w[1].clone());
        let (tx, rx) = mpsc::channel();
        if let Some(r) = self.script.lock().unwrap().pop_front() {
            tx.send(Msg::Finish(r)).unwrap();
        } else if let Some(r) = &*self.auto.lock().unwrap() {
            tx.send(Msg::Finish(r.clone())).unwrap();
        }
        let killed = Arc::new(Mutex::new(Vec::new()));
        let h = Arc::new(FakeHandle {
            tx: Mutex::new(tx.clone()),
            killed: Arc::clone(&killed),
        });
        self.handles.lock().unwrap().push(h);
        let tx = Mutex::new(tx);
        let ignore_first = Arc::clone(&self.ignore_first_kill);
        Spawned {
            session_id,
            kill: Box::new(move || {
                let first = killed.lock().unwrap().is_empty();
                killed
                    .lock()
                    .unwrap()
                    .push(if first { "SIGTERM" } else { "SIGKILL" });
                if first && *ignore_first.lock().unwrap() {
                    *ignore_first.lock().unwrap() = false;
                    return;
                }
                let _ = tx
                    .lock()
                    .unwrap()
                    .send(Msg::Finish(BackendResult::default()));
            }),
            drive: Box::new(move |on| {
                loop {
                    match rx.recv() {
                        Ok(Msg::Ev(e)) => on(e),
                        Ok(Msg::Finish(r)) => return r,
                        Err(_) => return BackendResult::default(),
                    }
                }
            }),
        }
    }
}

pub(crate) fn fake_finalize(res: &BackendResult, ctx: &FinalizeCtx) -> RunOutput {
    RunOutput {
        status: derive_status(&res.text, res.is_error, res.clean_exit),
        text: res.text.clone(),
        session_id: res.session_id.clone(),
        backend: ctx.backend.clone(),
        model: ctx.model.clone(),
        usage: res.usage.clone(),
        cost_usd: res.cost_usd,
        cost_estimated: res.cost_usd.is_none(),
        duration_ms: res.duration_ms,
        job_id: ctx.job_id.clone(),
        stderr_tail: None,
        gate_result: None,
        change_set: None,
        concerns: None,
        permission_denials: res.permission_denials.clone(),
        retries: Vec::new(),
    }
}

pub(crate) fn done_ok() -> BackendResult {
    BackendResult {
        text: "ok\nSTATUS: DONE".into(),
        is_error: Some(false),
        clean_exit: true,
        stderr: String::new(),
        ..Default::default()
    }
}

#[derive(Default)]
struct Spy(Mutex<Vec<(String, serde_json::Value)>>);

impl StatusRecordWriter for Spy {
    fn write(&self, job_id: &str, record: &PollResult) {
        self.0
            .lock()
            .unwrap()
            .push((job_id.into(), serde_json::to_value(record).unwrap()));
    }
}

impl Spy {
    fn len(&self) -> usize {
        self.0.lock().unwrap().len()
    }
    fn nth(&self, i: usize) -> (String, serde_json::Value) {
        self.0.lock().unwrap()[i].clone()
    }
    fn last(&self) -> (String, serde_json::Value) {
        self.0.lock().unwrap().last().unwrap().clone()
    }
}

struct Setup {
    reg: Arc<JobHandle>,
    fake: Arc<FakeBackend>,
    spy: Arc<Spy>,
}

fn setup_with(f: impl FnOnce(&mut JobDeps)) -> Setup {
    let fake = Arc::new(FakeBackend::default());
    let spy = Arc::new(Spy::default());
    let mut deps = JobDeps::new(fake.clone(), None, None);
    deps.finalize = Arc::new(fake_finalize);
    deps.finalize_stall = Arc::new(fake_finalize);
    deps.status_writer = spy.clone();
    f(&mut deps);
    Setup {
        reg: JobHandle::new(deps),
        fake,
        spy,
    }
}

fn setup() -> Setup {
    setup_with(|_| {})
}

fn settle(reg: &JobHandle, id: &str) -> String {
    for _ in 0..500 {
        let p = reg.poll(id);
        if p.status_label() != "RUNNING" {
            return p.status_label().to_string();
        }
        sleep(Duration::from_millis(2));
    }
    "RUNNING".into()
}

/// Wait until the fake backend has recorded `want`: the recording itself
/// acknowledges the watchdog kill, so no fixed delay assumes it fired.
fn wait_killed(s: &Setup, want: &[&'static str]) {
    for _ in 0..500 {
        if s.fake.handle(0).killed() == want {
            return;
        }
        sleep(Duration::from_millis(2));
    }
    assert_eq!(s.fake.handle(0).killed(), want);
}

fn terminal_text(reg: &JobHandle, id: &str) -> String {
    match reg.poll(id) {
        PollResult::Terminal { result, .. } => result.text,
        other => panic!("expected terminal poll, got {other:?}"),
    }
}

fn status_of(v: &serde_json::Value) -> &str {
    v["status"].as_str().unwrap()
}

#[test]
fn heartbeat_refreshes_running_record_and_stops_at_retirement() {
    let s = setup_with(|d| d.heartbeat_ms = 100);
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(s.spy.len(), 1);

    sleep(Duration::from_millis(150));
    assert_eq!(s.spy.len(), 2);
    let (jid, rec) = s.spy.nth(1);
    assert_eq!(jid, id);
    assert_eq!(status_of(&rec), "RUNNING");
    assert!(rec["lastHeartbeatAt"].is_u64());

    sleep(Duration::from_millis(100));
    assert_eq!(s.spy.len(), 3);

    s.fake.handle(0).finish(done_ok());
    assert_eq!(settle(&s.reg, &id), "DONE");
    let after = s.spy.len();
    assert_eq!(status_of(&s.spy.last().1), "DONE");
    sleep(Duration::from_millis(300));
    assert_eq!(s.spy.len(), after);
}

#[test]
fn dispatch_persists_start_and_terminal_records() {
    let s = setup();
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(s.spy.len(), 1);
    s.fake.handle(0).finish(done_ok());
    assert_eq!(settle(&s.reg, &id), "DONE");
    assert_eq!(s.spy.len(), 2);
    assert_eq!(status_of(&s.spy.nth(1).1), "DONE");
}

#[test]
fn dispatch_seeds_running_progress_with_the_launched_session_id() {
    let s = setup();
    let id = s.reg.dispatch(spec_of(|spec| {
        spec.argv = vec!["--session-id".into(), "launch-sid".into()];
    }));
    let (recorded_id, record) = s.spy.nth(0);
    assert_eq!(recorded_id, id);
    assert_eq!(record["status"], "RUNNING");
    assert_eq!(record["progress"]["sessionId"], "launch-sid");
}

#[test]
fn session_id_progress_is_written_without_waiting_for_the_heartbeat() {
    let s = setup();
    let id = s.reg.dispatch(spec_of(|_| {}));
    s.fake.handle(0).session_id("s-init");
    for _ in 0..500 {
        if s.spy.len() > 1 {
            break;
        }
        sleep(Duration::from_millis(2));
    }
    assert_eq!(s.spy.len(), 2);
    let record = s.spy.last().1;
    assert_eq!(record["status"], "RUNNING");
    assert_eq!(record["progress"]["sessionId"], "s-init");
    assert_eq!(serde_json::to_value(s.reg.poll(&id)).unwrap()["progress"]["sessionId"], "s-init");
    s.fake.handle(0).session_id("s-init");
    sleep(Duration::from_millis(30));
    assert_eq!(s.spy.len(), 2);
}

#[test]
fn idle_watchdog_writes_a_stalled_terminal_record() {
    let s = setup_with(|d| d.idle_ms = Some(50.0));
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(s.spy.len(), 1);
    assert_eq!(settle(&s.reg, &id), "STALLED");
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
    assert_eq!(s.spy.len(), 2);
    assert_eq!(status_of(&s.spy.nth(1).1), "STALLED");
}

#[test]
fn cancel_persists_a_cancelled_terminal_record() {
    let s = setup();
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(s.spy.len(), 1);
    s.reg.cancel(&id);
    assert_eq!(s.spy.len(), 2);
    assert_eq!(status_of(&s.spy.nth(1).1), "CANCELLED");
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
}

#[test]
fn a_panicking_status_writer_does_not_affect_completion() {
    struct Bad(Mutex<u32>);
    impl StatusRecordWriter for Bad {
        fn write(&self, _: &str, _: &PollResult) {
            let mut n = self.0.lock().unwrap();
            *n += 1;
            if *n == 2 {
                drop(n);
                panic!("boom");
            }
        }
    }
    let bad = Arc::new(Bad(Mutex::new(0)));
    let s = setup_with(|d| d.status_writer = bad.clone());
    let id = s.reg.dispatch(spec_of(|_| {}));
    s.fake.handle(0).finish(done_ok());
    assert_eq!(settle(&s.reg, &id), "DONE");
    assert_eq!(*bad.0.lock().unwrap(), 2);
}

#[test]
fn progress_events_do_not_trigger_status_writes() {
    let s = setup();
    let id = s.reg.dispatch(spec_of(|_| {}));
    s.fake.handle(0).progress(
        "shell",
        42.0,
        Some("running the test suite now"),
        &["src/foo.rs"],
        Some("running_tool"),
    );
    sleep(Duration::from_millis(30));
    assert_eq!(s.spy.len(), 1);
    s.fake.handle(0).finish(done_ok());
    assert_eq!(settle(&s.reg, &id), "DONE");
    assert_eq!(s.spy.len(), 2);
}

#[test]
fn file_status_record_is_overwritten_from_running_to_terminal() {
    let s = setup_with(|d| d.status_writer = Arc::new(FileStatusRecordWriter));
    let id = s.reg.dispatch(spec_of(|_| {}));
    let path = job_record_path(&id);
    let read = || -> serde_json::Value {
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
    };
    assert_eq!(read()["status"], "RUNNING");
    s.fake.handle(0).finish(done_ok());
    assert_eq!(settle(&s.reg, &id), "DONE");
    let terminal = read();
    assert_eq!(terminal["status"], "DONE");
    let polled = serde_json::to_value(s.reg.poll(&id)).unwrap();
    assert_eq!(terminal["result"], polled["result"]);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn dispatch_returns_immediately() {
    let s = setup();
    let t = Instant::now();
    s.reg.dispatch(spec_of(|_| {}));
    assert!(t.elapsed() < Duration::from_millis(1000));
}

#[test]
fn cancel_sigterms_the_child_and_marks_cancelled() {
    let s = setup();
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(s.reg.cancel(&id), "CANCELLED");
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
}

#[test]
fn idle_watchdog_sigterms_a_silent_job() {
    let s = setup_with(|d| d.idle_ms = Some(50.0));
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(settle(&s.reg, &id), "STALLED");
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
}

#[test]
fn a_stalled_jobs_text_summarizes_last_known_progress() {
    let s = setup_with(|d| d.idle_ms = Some(100.0));
    let id = s.reg.dispatch(spec_of(|_| {}));
    s.fake.handle(0).progress(
        "shell",
        42.0,
        Some("running the test suite now"),
        &["src/foo.rs"],
        Some("thinking"),
    );
    assert_eq!(settle(&s.reg, &id), "STALLED");
    let text = terminal_text(&s.reg, &id);
    for needle in [
        "shell",
        "42 tokens",
        "src/foo.rs",
        "running the test suite now",
    ] {
        assert!(text.contains(needle), "{needle:?} missing from {:?}", text);
    }
}

#[test]
fn a_progress_event_rearms_the_idle_watchdog() {
    let s = setup_with(|d| d.idle_ms = Some(300.0));
    let id = s.reg.dispatch(spec_of(|_| {}));
    sleep(Duration::from_millis(200));
    s.fake.handle(0).progress("shell", 1.0, None, &[], None);
    sleep(Duration::from_millis(200));
    assert!(s.fake.handle(0).killed().is_empty());
    assert_eq!(s.reg.poll(&id), "RUNNING");
}

#[test]
fn a_per_call_idle_override_beats_the_server_default() {
    let s = setup_with(|d| d.idle_ms = Some(50.0));
    let id = s.reg.dispatch(spec_of(|s| s.idle_ms = Some(Some(400.0))));
    sleep(Duration::from_millis(150));
    assert!(s.fake.handle(0).killed().is_empty());
    assert_eq!(settle(&s.reg, &id), "STALLED");
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
}

#[test]
fn a_per_call_idle_null_disables_the_watchdog() {
    let s = setup_with(|d| d.idle_ms = Some(30.0));
    let id = s.reg.dispatch(spec_of(|s| s.idle_ms = Some(None)));
    sleep(Duration::from_millis(200));
    assert!(s.fake.handle(0).killed().is_empty());
    assert_eq!(s.reg.poll(&id), "RUNNING");
}

#[test]
fn a_tool_in_flight_uses_the_tool_idle_window() {
    let s = setup_with(|d| {
        d.idle_ms = Some(50.0);
        d.tool_idle_ms = Some(400.0);
    });
    let id = s.reg.dispatch(spec_of(|_| {}));
    s.fake
        .handle(0)
        .progress("shell", 1.0, None, &[], Some("running_tool"));
    sleep(Duration::from_millis(150));
    assert!(s.fake.handle(0).killed().is_empty());
    assert_eq!(s.reg.poll(&id), "RUNNING");
    assert_eq!(settle(&s.reg, &id), "STALLED");
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
}

#[test]
fn leaving_the_tool_phase_reverts_to_the_short_window() {
    let s = setup_with(|d| {
        d.idle_ms = Some(80.0);
        d.tool_idle_ms = Some(10_000.0);
    });
    let id = s.reg.dispatch(spec_of(|_| {}));
    s.fake
        .handle(0)
        .progress("shell", 1.0, None, &[], Some("running_tool"));
    sleep(Duration::from_millis(150));
    assert_eq!(s.reg.poll(&id), "RUNNING");
    s.fake.handle(0).progress(
        "shell",
        2.0,
        Some("done with that"),
        &[],
        Some("responding"),
    );
    assert_eq!(settle(&s.reg, &id), "STALLED");
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
}

#[test]
fn a_per_call_tool_idle_override_applies_while_a_tool_is_in_flight() {
    let s = setup_with(|d| {
        d.idle_ms = Some(50.0);
        d.tool_idle_ms = Some(80.0);
    });
    let id = s.reg.dispatch(spec_of(|s| s.tool_idle_ms = Some(Some(10_000.0))));
    s.fake
        .handle(0)
        .progress("shell", 1.0, None, &[], Some("running_tool"));
    sleep(Duration::from_millis(200));
    assert!(s.fake.handle(0).killed().is_empty());
    assert_eq!(s.reg.poll(&id), "RUNNING");
}

#[test]
fn raw_activity_rearms_the_watchdog() {
    let s = setup_with(|d| d.idle_ms = Some(300.0));
    let id = s.reg.dispatch(spec_of(|_| {}));
    sleep(Duration::from_millis(200));
    s.fake.handle(0).activity();
    sleep(Duration::from_millis(200));
    assert!(s.fake.handle(0).killed().is_empty());
    assert_eq!(s.reg.poll(&id), "RUNNING");
}

#[test]
fn wait_returns_when_the_job_completes() {
    let s = setup();
    let id = s.reg.dispatch(spec_of(|_| {}));
    let h = s.fake.handle(0);
    std::thread::spawn(move || {
        sleep(Duration::from_millis(30));
        h.finish(done_ok());
    });
    assert_eq!(s.reg.wait(&id, Some(10_000.0)), "DONE");
}

fn retry_setup(delays: &[u64], script: Vec<BackendResult>) -> Setup {
    let delays = delays.to_vec();
    let s = setup_with(move |d| d.retry_delays_ms = delays);
    s.fake.script.lock().unwrap().extend(script);
    s
}

fn failed(status: Option<u16>) -> BackendResult {
    BackendResult {
        text: match status {
            Some(s) => format!("opencode-go API error ({s}): upstream"),
            None => "some other error".into(),
        },
        session_id: Some("sid-1".into()),
        is_error: Some(true),
        provider_status: status,
        ..Default::default()
    }
}

fn with_usage(mut r: BackendResult, input: f64) -> BackendResult {
    r.usage = Some(Usage {
        input_tokens: input,
        ..Default::default()
    });
    r.cost_usd = Some(input / 4.0);
    r
}

fn terminal(reg: &JobHandle, id: &str) -> RunOutput {
    match reg.poll(id) {
        PollResult::Terminal { result, .. } => result,
        other => panic!("expected terminal poll, got {other:?}"),
    }
}

fn wait_stage(reg: &JobHandle, want: Stage) {
    for _ in 0..500 {
        if reg.lock().job.as_ref().is_some_and(|(_, j)| j.stage == want) {
            return;
        }
        sleep(Duration::from_millis(2));
    }
    panic!("job never reached {want:?}");
}

fn argvs(s: &Setup) -> Vec<Vec<String>> {
    s.fake.argvs.lock().unwrap().clone()
}

#[test]
fn a_503_resumes_the_session_and_the_record_lists_the_retry() {
    let s = retry_setup(
        &[0, 0],
        vec![with_usage(failed(Some(503)), 10.0), with_usage(done_ok(), 5.0)],
    );
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(settle(&s.reg, &id), "DONE");
    let argvs = argvs(&s);
    assert_eq!(argvs.len(), 2);
    assert_eq!(
        argvs[1],
        ["resume", "sid-1", continue_prompt(503).as_str()]
    );
    let out = terminal(&s.reg, &id);
    assert_eq!(
        out.retries,
        [Retry {
            attempt: 1,
            provider_status: 503,
            error: "opencode-go API error (503): upstream".into(),
            delay_ms: 0,
            session_id: "sid-1".into(),
        }]
    );
    assert_eq!(out.usage.unwrap().input_tokens, 15.0);
    assert_eq!(out.cost_usd, Some(3.75));
}

#[test]
fn retries_stop_at_the_length_of_the_delay_list() {
    let s = retry_setup(&[0, 0], vec![failed(Some(503)); 3]);
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(settle(&s.reg, &id), "ERROR");
    assert_eq!(argvs(&s).len(), 3);
    assert_eq!(terminal(&s.reg, &id).retries.len(), 2);
}

#[test]
fn a_401_is_retried_once() {
    let s = retry_setup(&[0, 0], vec![failed(Some(401)); 2]);
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(settle(&s.reg, &id), "ERROR");
    assert_eq!(argvs(&s).len(), 2);
    assert_eq!(terminal(&s.reg, &id).retries.len(), 1);
}

#[test]
fn a_401_then_a_503_then_done_records_two_retries() {
    let s = retry_setup(
        &[0, 0],
        vec![failed(Some(401)), failed(Some(503)), done_ok()],
    );
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(settle(&s.reg, &id), "DONE");
    assert_eq!(argvs(&s).len(), 3);
    let statuses: Vec<_> = terminal(&s.reg, &id)
        .retries
        .iter()
        .map(|r| (r.attempt, r.provider_status))
        .collect();
    assert_eq!(statuses, [(1, 401), (2, 503)]);
}

#[test]
fn errors_that_are_not_transient_are_not_retried() {
    let mut ok_with_status = done_ok();
    ok_with_status.provider_status = Some(503);
    let mut no_session = failed(Some(503));
    no_session.session_id = None;
    let mut empty_session = failed(Some(503));
    empty_session.session_id = Some(String::new());
    for (name, res) in [
        ("429", failed(Some(429))),
        ("no status", failed(None)),
        ("done with a status", ok_with_status),
        ("no session id", no_session),
        ("empty session id", empty_session),
    ] {
        let s = retry_setup(&[0, 0], vec![res]);
        let id = s.reg.dispatch(spec_of(|_| {}));
        settle(&s.reg, &id);
        assert_eq!(argvs(&s).len(), 1, "{name}");
        assert!(terminal(&s.reg, &id).retries.is_empty(), "{name}");
    }
}

#[test]
fn a_session_id_from_progress_serves_when_the_result_has_none() {
    let mut no_session = failed(Some(503));
    no_session.session_id = None;
    let s = retry_setup(&[0], vec![no_session, done_ok()]);
    let id = s.reg.dispatch(spec_of(|spec| {
        spec.argv = vec!["--session-id".into(), "launch-sid".into()];
    }));
    assert_eq!(settle(&s.reg, &id), "DONE");
    assert_eq!(argvs(&s)[1][1], "launch-sid");
}

#[test]
fn cancel_during_the_backoff_returns_at_once_and_spawns_nothing() {
    let s = retry_setup(&[60_000], vec![failed(Some(503))]);
    let id = s.reg.dispatch(spec_of(|_| {}));
    wait_stage(&s.reg, Stage::Retrying);
    let t = Instant::now();
    assert_eq!(s.reg.cancel(&id), "CANCELLED");
    assert!(t.elapsed() < Duration::from_secs(1));
    assert_eq!(argvs(&s).len(), 1);
}

#[test]
fn cancel_after_the_respawn_kills_the_new_child() {
    let s = retry_setup(&[0], vec![failed(Some(503))]);
    let id = s.reg.dispatch(spec_of(|_| {}));
    let second = s.fake.handle(1);
    wait_stage(&s.reg, Stage::Running);
    assert_eq!(s.reg.cancel(&id), "CANCELLED");
    assert_eq!(second.killed(), ["SIGTERM"]);
    assert_eq!(terminal(&s.reg, &id).retries.len(), 1);
}

#[test]
fn a_stalled_attempt_is_not_retried() {
    let s = setup_with(|d| {
        d.idle_ms = Some(50.0);
        d.retry_delays_ms = vec![0, 0];
    });
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(settle(&s.reg, &id), "STALLED");
    assert_eq!(argvs(&s).len(), 1);
    assert!(terminal(&s.reg, &id).retries.is_empty());
}

#[test]
fn the_backoff_is_not_idle_time() {
    let s = setup_with(|d| {
        d.idle_ms = Some(50.0);
        d.retry_delays_ms = vec![300];
    });
    s.fake
        .script
        .lock()
        .unwrap()
        .extend([failed(Some(503)), done_ok()]);
    let id = s.reg.dispatch(spec_of(|_| {}));
    for _ in 0..500 {
        if s.reg.poll(&id).status_label() != "RUNNING" {
            break;
        }
        sleep(Duration::from_millis(2));
    }
    assert_eq!(s.reg.poll(&id), "DONE");
    assert_eq!(argvs(&s).len(), 2);
}

#[test]
fn a_resumed_attempt_does_not_inherit_the_failed_attempts_tool_window() {
    let s = setup_with(|d| {
        d.idle_ms = Some(50.0);
        d.tool_idle_ms = Some(10_000.0);
        d.retry_delays_ms = vec![0];
    });
    let id = s.reg.dispatch(spec_of(|_| {}));
    let first = s.fake.handle(0);
    first.progress("shell", 1.0, None, &[], Some("running_tool"));
    first.finish(failed(Some(503)));
    assert_eq!(settle(&s.reg, &id), "STALLED");
    assert_eq!(s.fake.handle(1).killed(), ["SIGTERM"]);
}

#[test]
fn a_denial_in_a_failed_attempt_reaches_finalize() {
    let seen: Arc<Mutex<Option<BackendResult>>> = Arc::default();
    let sink = Arc::clone(&seen);
    let s = setup_with(move |d| {
        d.retry_delays_ms = vec![0];
        d.finalize = Arc::new(move |res, ctx| {
            *sink.lock().unwrap() = Some(res.clone());
            fake_finalize(res, ctx)
        });
    });
    let mut denied = failed(Some(503));
    denied.permission_denials = vec![serde_json::json!({"tool_name": "Bash"})];
    s.fake.script.lock().unwrap().extend([denied, done_ok()]);
    let id = s.reg.dispatch(spec_of(|_| {}));
    assert_eq!(settle(&s.reg, &id), "DONE");
    let merged = seen.lock().unwrap().clone().unwrap();
    assert_eq!(merged.permission_denials.len(), 1);
    assert_eq!(terminal(&s.reg, &id).permission_denials.len(), 1);
}

#[test]
fn transient_status_is_a_5xx_or_a_first_401_on_an_error() {
    let st = |status, had_401| transient_status(&failed(status), had_401);
    assert_eq!(st(Some(503), false), Some(503));
    assert_eq!(st(Some(599), true), Some(599));
    assert_eq!(st(Some(401), false), Some(401));
    assert_eq!(st(Some(401), true), None);
    assert_eq!(st(Some(429), false), None);
    assert_eq!(st(Some(404), false), None);
    assert_eq!(st(Some(600), false), None);
    assert_eq!(st(None, false), None);
    let mut ok = failed(Some(503));
    ok.is_error = Some(false);
    assert_eq!(transient_status(&ok, false), None);
}

#[test]
fn muse_shaped_error_result_is_never_transient() {
    // The muse backend never reports a provider status, so its error
    // results must never take the retry path that rebuilds argv without
    // the host-profile sandbox flag.
    let mut res = BackendResult {
        provider_status: None,
        is_error: Some(true),
        ..Default::default()
    };
    assert_eq!(transient_status(&res, false), None);
    assert_eq!(transient_status(&res, true), None);
    res.provider_status = Some(503);
    assert_eq!(transient_status(&res, false), Some(503));
}

#[test]
fn merge_attempt_sums_what_was_reported_and_takes_the_rest_from_the_last() {
    let mut prev = with_usage(failed(Some(503)), 10.0);
    prev.duration_ms = Some(100.0);
    prev.permission_denials = vec![serde_json::json!(1)];
    let mut next = done_ok();
    next.permission_denials = vec![serde_json::json!(2)];
    let merged = merge_attempt(&prev, next);
    assert_eq!(merged.usage.unwrap().input_tokens, 10.0);
    assert_eq!(merged.cost_usd, Some(2.5));
    assert_eq!(merged.duration_ms, Some(100.0));
    assert_eq!(merged.permission_denials.len(), 2);
    assert_eq!(merged.text, "ok\nSTATUS: DONE");
    assert_eq!(merged.provider_status, None);
}

#[test]
fn merge_attempt_sums_call_counts_reported_by_both_attempts() {
    let mut prev = with_usage(failed(Some(503)), 10.0);
    prev.usage.as_mut().unwrap().calls = Some(3);
    let mut next = with_usage(done_ok(), 20.0);
    next.usage.as_mut().unwrap().calls = Some(4);

    assert_eq!(
        merge_attempt(&prev, next).usage.unwrap().calls,
        Some(7)
    );
}

#[test]
fn merge_attempt_keeps_the_call_count_when_only_one_attempt_reports_it() {
    for (earlier, later, expected) in [
        (Some(3), None, Some(3)),
        (None, Some(4), Some(4)),
        (None, None, None),
    ] {
        let mut prev = with_usage(failed(Some(503)), 10.0);
        prev.usage.as_mut().unwrap().calls = earlier;
        let mut next = with_usage(done_ok(), 20.0);
        next.usage.as_mut().unwrap().calls = later;

        assert_eq!(merge_attempt(&prev, next).usage.unwrap().calls, expected);
    }
}

fn wall_text(reg: &JobHandle, id: &str, ms: f64) -> String {
    let text = terminal_text(reg, id);
    assert!(
        text.starts_with(&format!(
            "Cancelled: wall budget of {ms} ms exceeded after"
        )),
        "{text:?}"
    );
    text
}

#[test]
fn a_job_past_its_wall_budget_is_cancelled() {
    let s = setup_with(|_| {});
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(300.0)));
    assert_eq!(s.reg.poll(&id), "RUNNING");
    assert_eq!(settle(&s.reg, &id), "CANCELLED");
    // Contract (docs/delegate-sessions.md:13-22): the first kill is SIGTERM; an idle stall or a clean wall kill sends just this one.
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
    wall_text(&s.reg, &id, 300.0);
}

#[test]
fn progress_does_not_extend_the_wall_budget() {
    let s = setup_with(|_| {});
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(300.0)));
    let h = s.fake.handle(0);
    let t = Instant::now();
    while s.reg.poll(&id) == "RUNNING" {
        h.activity();
        h.progress("shell", 1.0, None, &[], Some("running_tool"));
        sleep(Duration::from_millis(20));
    }
    assert!(t.elapsed() < Duration::from_secs(1));
    assert_eq!(s.reg.poll(&id), "CANCELLED");
    wall_text(&s.reg, &id, 300.0);
}

#[test]
fn a_job_that_finishes_inside_the_budget_is_untouched() {
    let s = setup_with(|_| {});
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(5_000.0)));
    s.fake.handle(0).finish(done_ok());
    assert_eq!(settle(&s.reg, &id), "DONE");
    assert!(s.fake.handle(0).killed().is_empty());
    let text = terminal_text(&s.reg, &id);
    assert!(!text.contains("wall budget"), "{text:?}");
}

#[test]
fn no_wall_budget_means_no_cap() {
    let s = setup_with(|_| {});
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = None));
    let t = Instant::now();
    while t.elapsed() < Duration::from_millis(400) {
        assert_eq!(s.reg.poll(&id), "RUNNING");
        assert!(s.fake.handle(0).killed().is_empty());
        sleep(Duration::from_millis(2));
    }
}

#[test]
fn the_wall_budget_includes_the_retry_backoff() {
    let s = retry_setup(&[60_000], vec![failed(Some(503))]);
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(100.0)));
    wait_stage(&s.reg, Stage::Retrying);
    let t = Instant::now();
    assert_eq!(settle(&s.reg, &id), "CANCELLED");
    assert!(t.elapsed() < Duration::from_secs(1));
    // Contract (docs/delegate-sessions.md:13-22): a wall expiry during retry backoff performs no respawn.
    assert_eq!(argvs(&s).len(), 1);
    wall_text(&s.reg, &id, 100.0);
}

#[test]
fn the_wall_budget_aborts_the_job_end_gate() {
    let saw_signal = Arc::new(AtomicBool::new(false));
    let sink = Arc::clone(&saw_signal);
    let gate: FinalizeFn = Arc::new(move |res: &BackendResult, ctx: &FinalizeCtx| {
        let t = Instant::now();
        while ctx.signal.as_ref().is_none_or(|s| !s.load(Ordering::SeqCst)) {
            if t.elapsed() > Duration::from_secs(5) {
                break;
            }
            sleep(Duration::from_millis(10));
        }
        sink.store(true, Ordering::SeqCst);
        fake_finalize(res, ctx)
    });
    let gate2 = Arc::clone(&gate);
    let s = setup_with(move |d| {
        d.finalize = gate;
        d.finalize_stall = gate2;
    });
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(100.0)));
    s.fake.handle(0).finish(done_ok());
    assert_eq!(settle(&s.reg, &id), "CANCELLED");
    let out = terminal(&s.reg, &id);
    assert_eq!(out.status, RunStatus::Cancelled);
    wall_text(&s.reg, &id, 100.0);
    match s.reg.poll(&id) {
        PollResult::Terminal {
            status, result, ..
        } => {
            assert_eq!(status, JobStatus::Cancelled);
            assert_eq!(result.status, RunStatus::Cancelled);
        }
        other => panic!("expected terminal poll, got {other:?}"),
    }
    assert!(saw_signal.load(Ordering::SeqCst));
}

#[test]
fn a_cancel_during_the_gate_reports_cancelled_in_the_result() {
    let entered = Arc::new(AtomicBool::new(false));
    let sink = Arc::clone(&entered);
    let s = setup_with(move |d| {
        d.finalize = Arc::new(move |res: &BackendResult, ctx: &FinalizeCtx| {
            sink.store(true, Ordering::SeqCst);
            let t = Instant::now();
            while ctx.signal.as_ref().is_none_or(|s| !s.load(Ordering::SeqCst)) {
                if t.elapsed() > Duration::from_secs(5) {
                    break;
                }
                sleep(Duration::from_millis(10));
            }
            fake_finalize(res, ctx)
        });
    });
    let id = s.reg.dispatch(spec_of(|_| {}));
    s.fake.handle(0).finish(done_ok());
    for _ in 0..500 {
        if entered.load(Ordering::SeqCst) {
            break;
        }
        sleep(Duration::from_millis(2));
    }
    assert!(entered.load(Ordering::SeqCst));
    assert_eq!(s.reg.cancel(&id), "CANCELLED");
    let out = terminal(&s.reg, &id);
    assert_eq!(out.status, RunStatus::Cancelled);
    let text = terminal_text(&s.reg, &id);
    assert!(text.starts_with("Cancelled after"), "{text:?}");
}

#[test]
fn the_first_termination_wins() {
    // (i) The idle stall fires first: STALLED, never the wall wording.
    let s = setup_with(|d| d.idle_ms = Some(50.0));
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(60_000.0)));
    assert_eq!(settle(&s.reg, &id), "STALLED");
    let text = terminal_text(&s.reg, &id);
    assert!(text.starts_with("Idle watchdog killed this job"), "{text:?}");

    // (ii) The wall fires first: CANCELLED with the wall wording.
    let s = setup_with(|d| d.idle_ms = Some(60_000.0));
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(100.0)));
    assert_eq!(settle(&s.reg, &id), "CANCELLED");
    wall_text(&s.reg, &id, 100.0);

    // (iii) A cancel beats a later wall deadline: the cancel wording stands.
    let s = setup_with(|_| {});
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(100.0)));
    assert_eq!(s.reg.cancel(&id), "CANCELLED");
    let text = terminal_text(&s.reg, &id);
    assert!(text.starts_with("Cancelled after"), "{text:?}");
    assert!(!text.contains("wall budget"), "{text:?}");

    // (iv) A cancel after a watchdog kill SIGKILLs at once: the caller wants
    // the process gone now, with no SIGTERM grace.
    let s = setup_with(|d| {
        d.idle_ms = Some(50.0);
        d.kill_grace_ms = 60_000;
    });
    *s.fake.ignore_first_kill.lock().unwrap() = true;
    let id = s.reg.dispatch(spec_of(|_| {}));
    wait_killed(&s, &["SIGTERM"]);
    // Contract (docs/delegate-sessions.md:13-22): the first kill is SIGTERM; an idle stall or a clean wall kill sends just this one.
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
    let t = Instant::now();
    assert_eq!(s.reg.cancel(&id), "CANCELLED");
    assert!(t.elapsed() < Duration::from_secs(1));
    // Contract (docs/delegate-sessions.md:13-22): a wall-expired child that ignores SIGTERM gets SIGKILL after the grace; a user cancel after a watchdog kill sends it at once.
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM", "SIGKILL"]);
    let text = terminal_text(&s.reg, &id);
    assert!(text.starts_with("Cancelled after"), "{text:?}");
}

#[test]
fn a_cancel_after_wall_sigterm_reads_the_cancel_wording() {
    // Plan ruling 6: a cancel after a wall kill reads the cancel wording, so
    // `tkt-job` reports plain CANCELLED, not WALL-CAP. Fails when `cancel`
    // leaves the wall mark behind: the text then keeps the wall wording.
    let s = setup_with(|d| {
        d.kill_grace_ms = 60_000;
    });
    *s.fake.ignore_first_kill.lock().unwrap() = true;
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(50.0)));
    wait_killed(&s, &["SIGTERM"]);
    assert_eq!(s.reg.cancel(&id), "CANCELLED");
    // Contract (docs/delegate-sessions.md:13-22): a wall-expired child that ignores SIGTERM gets SIGKILL after the grace; a user cancel after a watchdog kill sends it at once.
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM", "SIGKILL"]);
    let text = terminal_text(&s.reg, &id);
    assert!(text.starts_with("Cancelled after"), "{text:?}");
    assert!(!text.contains("wall budget"), "{text:?}");
}

#[test]
fn a_sigterm_resistant_child_is_killed_after_the_grace() {
    // The wall fires at 50 ms; the grace (400 ms) holds off the SIGKILL, so
    // the first recorded kill is still the only one right after it lands.
    let s = setup_with(|d| d.kill_grace_ms = 400);
    *s.fake.ignore_first_kill.lock().unwrap() = true;
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(50.0)));
    wait_killed(&s, &["SIGTERM"]);
    // Contract (docs/delegate-sessions.md:13-22): the first kill is SIGTERM; an idle stall or a clean wall kill sends just this one.
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
    assert_eq!(settle(&s.reg, &id), "CANCELLED");
    // Contract (docs/delegate-sessions.md:13-22): a wall-expired child that ignores SIGTERM gets SIGKILL after the grace; a user cancel after a watchdog kill sends it at once.
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM", "SIGKILL"]);
    wall_text(&s.reg, &id, 50.0);

    // A normal child ends on the first kill: no second signal.
    let s = setup_with(|d| d.kill_grace_ms = 60_000);
    let id = s.reg.dispatch(spec_of(|sp| sp.wall_ms = Some(50.0)));
    assert_eq!(settle(&s.reg, &id), "CANCELLED");
    // Contract (docs/delegate-sessions.md:13-22): the first kill is SIGTERM; an idle stall or a clean wall kill sends just this one.
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);

    // The escalation is wall-only: an idle stall keeps its single SIGTERM.
    let s = setup_with(|d| {
        d.idle_ms = Some(50.0);
        d.kill_grace_ms = 400;
    });
    *s.fake.ignore_first_kill.lock().unwrap() = true;
    let id = s.reg.dispatch(spec_of(|_| {}));
    wait_killed(&s, &["SIGTERM"]);
    // Contract (docs/delegate-sessions.md:13-22): the first kill is SIGTERM; an idle stall or a clean wall kill sends just this one.
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
    s.fake.handle(0).finish(done_ok());
    assert_eq!(settle(&s.reg, &id), "STALLED");
    // Contract (docs/delegate-sessions.md:13-22): the first kill is SIGTERM; an idle stall or a clean wall kill sends just this one.
    assert_eq!(s.fake.handle(0).killed(), ["SIGTERM"]);
}

#[test]
fn merge_attempt_uses_latest_allowance_and_falls_back_when_later_is_absent() {
    let earlier = Allowance {
        window: None,
        weekly: None,
        as_of_ms: Some(100.0),
    };
    let later = Allowance {
        window: None,
        weekly: None,
        as_of_ms: Some(200.0),
    };

    let mut prev = with_usage(failed(Some(503)), 10.0);
    prev.usage.as_mut().unwrap().allowance = Some(earlier.clone());
    let mut next = with_usage(done_ok(), 20.0);
    assert_eq!(
        merge_attempt(&prev, next.clone())
            .usage
            .unwrap()
            .allowance,
        Some(earlier)
    );

    next.usage.as_mut().unwrap().allowance = Some(later.clone());
    assert_eq!(
        merge_attempt(&prev, next).usage.unwrap().allowance,
        Some(later)
    );
}

#[test]
fn running_progress_carries_the_last_event_age() {
    let s = setup();
    let id = s.reg.dispatch(spec_of(|_| {}));
    sleep(Duration::from_millis(200));
    let polled = serde_json::to_value(s.reg.poll(&id)).unwrap();
    let age = polled["progress"]["lastEventAgeMs"]
        .as_f64()
        .expect("progress carries lastEventAgeMs");
    let elapsed = polled["progress"]["elapsedMs"]
        .as_f64()
        .expect("progress carries elapsedMs");
    assert!(age >= 200.0, "age {age} covers the 200 ms quiet window");
    assert!(age <= elapsed, "age {age} never exceeds elapsed {elapsed}");
    let dispatch_record = s.spy.nth(0).1;
    assert!(
        dispatch_record["progress"]["lastEventAgeMs"].is_number(),
        "the dispatch record carries the age too"
    );
    s.fake.handle(0).finish(done_ok());
    assert_eq!(settle(&s.reg, &id), "DONE");
}
