// #663: a fake script written and exec'd while other threads fork must not
// fail with ETXTBSY. Red on main: a child forked between the writer's open and
// close inherits the write fd until its exec, and the exec of the fake fails.
use std::os::unix::fs::PermissionsExt;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Barrier};

mod support;

const ITERATIONS: usize = 400;
const FORKERS: usize = 16;

#[test]
fn fake_script_exec_survives_concurrent_spawns() {
    let dir = std::env::temp_dir().join(format!("fake-exec-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let start = Arc::new(Barrier::new(FORKERS + 1));
    let writer_done = Arc::new(AtomicBool::new(false));
    let forkers: Vec<_> = (0..FORKERS)
        .map(|_| {
            let start = start.clone();
            let writer_done = writer_done.clone();
            std::thread::spawn(move || {
                start.wait();
                while !writer_done.load(Ordering::Acquire) {
                    let guard = support::exec_lock();
                    let status = Command::new("true").status().unwrap();
                    drop(guard);
                    assert!(status.success(), "concurrent true spawn failed: {status}");
                    std::thread::yield_now();
                }
            })
        })
        .collect();
    let fake = dir.join("fake");
    start.wait();
    let mut failure = None;
    for i in 0..ITERATIONS {
        let _guard = support::exec_lock();
        // Reuse the executable so macOS does not rescan 400 distinct scripts.
        std::fs::write(&fake, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        match Command::new(&fake).status() {
            Ok(status) if status.success() => {}
            other => {
                failure = Some(format!("iteration {i}: {other:?}"));
                break;
            }
        }
    }
    writer_done.store(true, Ordering::Release);
    for forker in forkers {
        forker.join().unwrap();
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert!(failure.is_none(), "{}", failure.unwrap_or_default());
}
