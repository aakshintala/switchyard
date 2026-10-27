//! #681: one poison-tolerant lock serialising every test that mutates
//! process-global env (`CODEX_BIN`, `PATH`, `HOME`, `TMPDIR`, the job-dir
//! override the gate tests read). Hold [`lock`] for the whole window a test
//! mutates env — or depends on env another test could mutate — and pair every
//! mutation with an [`EnvGuard`] so the previous value is restored on drop.
//!
//! Poison-tolerant: a panic in one test releases the lock unpoisoned, so one
//! failure cannot cascade into `PoisonError` failures across the suite.
use std::sync::{Mutex, MutexGuard};

static ENV_LOCK: Mutex<()> = Mutex::new(());

/// Serialise against every other env-mutating test. Never `.lock().unwrap()`:
/// `into_inner` keeps the suite green when a holder panics.
pub(crate) fn lock() -> MutexGuard<'static, ()> {
    ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// A process-global env var that restores its previous value (or absence) on
/// drop. The guard alone does not serialise: hold [`lock`] alongside it.
pub(crate) struct EnvGuard {
    key: &'static str,
    prev: Option<String>,
}

impl EnvGuard {
    pub(crate) fn set(key: &'static str, value: &str) -> Self {
        let prev = std::env::var(key).ok();
        unsafe { std::env::set_var(key, value) };
        Self { key, prev }
    }

    pub(crate) fn set_os(key: &'static str, value: std::ffi::OsString) -> Self {
        let prev = std::env::var(key).ok();
        unsafe { std::env::set_var(key, value) };
        Self { key, prev }
    }

    pub(crate) fn remove(key: &'static str) -> Self {
        let prev = std::env::var(key).ok();
        unsafe { std::env::remove_var(key) };
        Self { key, prev }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        match &self.prev {
            Some(value) => unsafe { std::env::set_var(self.key, value) },
            None => unsafe { std::env::remove_var(self.key) },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// Set while a holder owns the lock: any overlap means the lock did not
    /// serialise, and the second holder fails instead of hanging.
    static IN_CRITICAL: AtomicBool = AtomicBool::new(false);
    const VAR: &str = "DELEGATE_TEST_ENV_SERIAL_681";

    fn serial_round(expected: &str) {
        let _held = lock();
        assert!(
            !IN_CRITICAL.swap(true, Ordering::SeqCst),
            "shared env lock did not serialise holders"
        );
        let _var = EnvGuard::set(VAR, expected);
        std::thread::yield_now();
        assert_eq!(std::env::var(VAR).unwrap_or_default(), expected);
        IN_CRITICAL.store(false, Ordering::SeqCst);
    }

    #[test]
    fn env_serial_first_holder_is_alone() {
        serial_round("first");
    }

    #[test]
    fn env_serial_second_holder_is_alone() {
        serial_round("second");
    }

    #[test]
    fn job_dir_var_is_held_across_a_second_taker() {
        use std::sync::{TryLockError, mpsc};
        use std::time::Duration;
        const JOB_DIR: &str = "DELEGATE_JOBS_DIR";
        const WAIT: Duration = Duration::from_secs(2);
        let (held_tx, held_rx) = mpsc::channel::<()>();
        let (contended_tx, contended_rx) = mpsc::channel::<()>();
        let (done_tx, done_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();

        let a = std::thread::spawn(move || {
            let _held = lock();
            let _var = EnvGuard::set(JOB_DIR, "a");
            held_tx.send(()).unwrap();
            contended_rx
                .recv_timeout(WAIT)
                .expect("B never reported contention");
            // B has already failed to take the lock; "a" must still be ours.
            assert_eq!(std::env::var(JOB_DIR).unwrap_or_default(), "a");
        });
        let b = std::thread::spawn(move || {
            held_rx.recv_timeout(WAIT).expect("A never took the lock");
            // A holds the lock until it hears from us, so this must see contention.
            match ENV_LOCK.try_lock() {
                Err(TryLockError::WouldBlock) => {}
                Err(TryLockError::Poisoned(_)) => panic!("env lock poisoned"),
                Ok(_) => panic!("B acquired the env lock while A held it"),
            }
            contended_tx.send(()).unwrap();
            let _held = lock();
            let _var = EnvGuard::set(JOB_DIR, "b");
            done_tx.send(()).unwrap();
            // Keep "b" set until the test has released B, so B's own restore
            // on drop cannot hide anything.
            release_rx
                .recv_timeout(WAIT)
                .expect("test never released B");
        });

        done_rx.recv_timeout(WAIT * 2).expect("B never finished");
        let a_result = a.join();
        let _ = release_tx.send(());
        b.join().unwrap();
        a_result.unwrap();
    }

    #[test]
    fn path_var_is_held_under_the_helper() {
        let _held = lock();
        let orig = std::env::var("PATH").unwrap_or_default();
        // Prefix, never replace: concurrent unlocked tests still need PATH to spawn.
        let probe = format!("/delegate-681-probe:{orig}");
        let _path = EnvGuard::set("PATH", &probe);
        // Hold the value across a window so a concurrent mutator is caught.
        let until = std::time::Instant::now() + std::time::Duration::from_millis(300);
        while std::time::Instant::now() < until {
            std::thread::yield_now();
            assert_eq!(std::env::var("PATH").unwrap_or_default(), probe);
        }
    }
}
