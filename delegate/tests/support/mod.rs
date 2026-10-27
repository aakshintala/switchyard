// #663: one process-wide lock for fake-script writes and every spawn in a test
// process. A fork between a writer's open and close leaves the write fd open in
// the child until its exec; exec of the fake then fails with ETXTBSY. The writer
// holds the lock across write, chmod and exec; each spawn holds it around fork.
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, OnceLock};

static EXEC_LOCK: Mutex<()> = Mutex::new(());

/// Poison-tolerant: a panic in one test must not fail the rest of the run.
pub fn exec_lock() -> MutexGuard<'static, ()> {
    EXEC_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

#[allow(dead_code)] // not every test binary that includes this module spawns the fake
static FAKE: OnceLock<PathBuf> = OnceLock::new();

#[allow(dead_code)] // not every test binary that includes this module spawns the fake
static PI_FAKE: OnceLock<PathBuf> = OnceLock::new();

/// The muse host fake, written once per process before any session exists, so
/// no later write can leave a write fd open across a fork. Per-session settings
/// go in `fake-config.json` in the host's cwd. Callers must not hold `exec_lock`.
#[allow(dead_code)] // not every test binary that includes this module spawns the fake
pub fn muse_host_fake() -> PathBuf {
    FAKE.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("delegate-test-fake-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let fake = dir.join("muse_host_fake.py");
        let guard = exec_lock();
        std::fs::write(&fake, include_str!("muse_host_fake.py")).unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        // macOS scans a newly executable script on first launch; keep that outside the RPC budgets.
        let warm_dir = dir.join("warmup");
        let status = std::process::Command::new(&fake)
            .args([
                "serve",
                "--provider",
                "meta",
                "--model",
                "warmup",
                "--disable-sandbox",
            ])
            .env("FAKE_DIR", &warm_dir)
            .env("FAKE_SCENARIO", "FAST")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        drop(guard);
        assert!(status.success());
        let _ = std::fs::remove_dir_all(warm_dir);
        fake
    })
    .clone()
}

/// The pi RPC host fake, written once per process before any session exists,
/// so no later write can leave a write fd open across a fork. Callers must
/// not hold `exec_lock`.
#[allow(dead_code)] // not every test binary that includes this module spawns the fake
pub fn pi_host_fake() -> PathBuf {
    PI_FAKE
        .get_or_init(|| {
            let dir =
                std::env::temp_dir().join(format!("delegate-test-pi-fake-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let fake = dir.join("pi_host_fake.py");
            let guard = exec_lock();
            std::fs::write(&fake, include_str!("pi_host_fake.py")).unwrap();
            std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
            // macOS scans a newly executable script on first launch; keep that outside the RPC budgets.
            let warm_dir = dir.join("warmup");
            let status = std::process::Command::new(&fake)
                .args(["--mode", "rpc"])
                .env("FAKE_DIR", &warm_dir)
                .env("FAKE_SCENARIO", "")
                .env_remove("FAKE_CASSETTE")
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .unwrap();
            drop(guard);
            assert!(status.success());
            let _ = std::fs::remove_dir_all(warm_dir);
            fake
        })
        .clone()
}
