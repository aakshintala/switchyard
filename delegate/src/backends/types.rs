use crate::types::{JobSpec, Usage};

/// What the backend returns when the child exits.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct BackendResult {
    pub text: String,
    pub session_id: Option<String>,
    pub usage: Option<Usage>,
    /// Cost the backend reported itself; None means price from the model table.
    pub cost_usd: Option<f64>,
    /// True when the backend's own amount is the backend's estimate rather
    /// than a metered charge; meaningful only when `cost_usd` is `Some`.
    pub cost_estimated: bool,
    pub is_error: Option<bool>,
    pub duration_ms: Option<f64>,
    pub clean_exit: bool,
    pub stderr: String,
    /// Claude result `permission_denials`, kept whole. Empty for cursor.
    pub permission_denials: Vec<serde_json::Value>,
    /// HTTP status the provider reported with an error, when the backend exposes one.
    pub provider_status: Option<u16>,
}

/// Snapshot of live progress fields carried by each `Event::Progress`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProgressSnapshotRaw {
    pub last_tool: Option<String>,
    pub tokens_so_far: f64,
    pub last_assistant: Option<String>,
    pub files_touched: Vec<String>,
    pub phase: Option<String>,
    pub session_id: Option<String>,
}

/// Liveness and progress signals from a running child. `Activity` fires on any raw stdout
/// chunk, even one that doesn't complete a parseable line, so the idle watchdog can treat
/// it as liveness without waiting for a full semantic event.
#[derive(Debug, Clone)]
pub enum Event {
    Progress(ProgressSnapshotRaw),
    Stderr,
    Activity,
}

pub type EventFn<'a> = &'a (dyn Fn(Event) + Sync);

/// A spawned run. `kill` sends SIGTERM and may be called from any thread, any number of
/// times. `drive` blocks the calling thread until the child exits, reporting events.
pub struct Spawned {
    pub kill: Box<dyn Fn() + Send + Sync>,
    pub session_id: Option<String>,
    pub drive: Box<dyn FnOnce(EventFn<'_>) -> BackendResult + Send>,
}

/// Job runner's test seam. `Backend` delegates to `spawn`; job tests use a fake.
pub trait Runner: Send + Sync {
    fn run(&self, spec: &JobSpec) -> Spawned;
    /// Argv that resumes `session` with `prompt`, for a retry. Never the original prompt.
    fn resume_argv(&self, model: &str, session: &str, prompt: &str) -> Vec<String>;
}
