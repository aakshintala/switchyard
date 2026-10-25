#![allow(dead_code)]
// #663: one process-wide lock for fake-script writes and every spawn in a test
// process. A fork between a writer's open and close leaves the write fd open in
// the child until its exec; exec of the fake then fails with ETXTBSY. The writer
// holds the lock across write, chmod and exec; each spawn holds it around fork.
use std::sync::{Mutex, MutexGuard};

static EXEC_LOCK: Mutex<()> = Mutex::new(());

/// Poison-tolerant: a panic in one test must not fail the rest of the run.
pub fn exec_lock() -> MutexGuard<'static, ()> {
    EXEC_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}
