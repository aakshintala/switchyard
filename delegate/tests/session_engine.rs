use delegate::session::{ipc, state::Paths};
use serde_json::json;
use std::os::unix::net::UnixListener;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

static NEXT: AtomicU64 = AtomicU64::new(0);

fn paths() -> (Paths, String, std::path::PathBuf) {
    let root = std::path::PathBuf::from("/tmp").join(format!(
        "ds-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let id = "00000000-0000-7000-8000-000000000001".to_string();
    std::fs::create_dir_all(root.join(&id)).unwrap();
    (Paths::new(root.clone()), id, root)
}

#[test]
fn ipc_request_reports_a_stale_socket_as_unreachable() {
    let (paths, id, root) = paths();
    let socket = paths.socket_path(&id).unwrap();
    drop(UnixListener::bind(&socket).unwrap());

    let result = ipc::request(
        &paths,
        &id,
        &json!({"op":"send","text":"hello"}),
        Duration::from_millis(100),
    );

    assert!(matches!(result, Err(ipc::IpcError::Unreachable(_))));
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn ipc_request_times_out_when_the_server_does_not_reply() {
    let (paths, id, root) = paths();
    let socket = paths.socket_path(&id).unwrap();
    let listener = UnixListener::bind(&socket).unwrap();
    let (release_tx, release_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let server = std::thread::spawn(move || {
        let (_stream, _) = listener.accept().unwrap();
        let _ = release_rx.recv_timeout(Duration::from_secs(2));
        let _ = done_tx.send(());
    });

    let timeout = Duration::from_millis(100);
    let started = Instant::now();
    let result = ipc::request(&paths, &id, &json!({"op":"send","text":"hello"}), timeout);
    let elapsed = started.elapsed();

    assert!(matches!(result, Err(ipc::IpcError::Timeout)));
    assert!(elapsed >= timeout.saturating_sub(Duration::from_millis(10)));
    let _ = release_tx.send(());
    done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    server.join().unwrap();
    std::fs::remove_dir_all(root).unwrap();
}
