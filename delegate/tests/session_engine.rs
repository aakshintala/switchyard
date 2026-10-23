use delegate::session::{inbox, ipc, state::Paths};
use serde_json::json;
use std::os::unix::net::UnixListener;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

static NEXT: AtomicU64 = AtomicU64::new(0);

fn temp_root(prefix: &str) -> std::path::PathBuf {
    std::path::PathBuf::from("/tmp").join(format!(
        "{prefix}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ))
}

fn paths() -> (Paths, String, std::path::PathBuf) {
    let root = temp_root("ds");
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

#[test]
fn inbox_utc_stamp_handles_exact_time_day_boundary_and_leap_day() {
    assert_eq!(inbox::utc_stamp(1_792_714_029_748), "20261023T000709Z");
    assert_eq!(inbox::utc_stamp(1_792_713_599_999), "20261022T235959Z");
    assert_eq!(inbox::utc_stamp(1_792_713_600_000), "20261023T000000Z");
    assert_eq!(inbox::utc_stamp(1_582_934_400_000), "20200229T000000Z");
}

#[test]
fn inbox_notify_writes_an_atomic_idle_note_with_a_drain_compatible_name() {
    let root = temp_root("ds-inbox");
    let inbox_path = root.join("nested/inbox");
    let id = "00000000-0000-7000-8000-000000000001";

    let path = inbox::notify(&inbox_path, id, inbox::Note::Idle, 1_792_714_029_748).unwrap();

    assert!(inbox_path.is_dir());
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        format!("[session {id} idle]\n")
    );
    let name = path.file_name().unwrap().to_str().unwrap();
    assert!(name.ends_with(".md"));
    let fields = name.strip_suffix(".md").unwrap();
    let (without_random, random) = fields.rsplit_once('-').unwrap();
    let (without_pid, pid) = without_random.rsplit_once('-').unwrap();
    let (sender, stamp) = without_pid.rsplit_once('-').unwrap();
    assert_eq!(sender, format!("session-{id}"));
    assert_eq!(stamp, "20261023T000709Z");
    assert!(!pid.is_empty());
    assert!(!random.is_empty());
    let files: Vec<_> = std::fs::read_dir(&inbox_path)
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(files.len(), 1);
    assert!(!files[0].file_name().to_string_lossy().contains(".tmp."));

    let (sender, stamp) = {
        let mut rest = name.strip_suffix(".md").unwrap();
        rest = rest.rsplit_once('-').unwrap().0;
        rest = rest.rsplit_once('-').unwrap().0;
        rest.rsplit_once('-').unwrap()
    };
    assert_eq!(sender, format!("session-{id}"));
    assert_eq!(stamp, "20261023T000709Z");

    let dead = inbox::notify(&inbox_path, id, inbox::Note::Dead, 1_792_714_029_748).unwrap();
    assert_eq!(
        std::fs::read_to_string(dead).unwrap(),
        format!("[session {id} dead]\n")
    );
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn inbox_notify_returns_an_error_when_inbox_is_a_file() {
    let root = temp_root("ds-inbox-file");
    std::fs::create_dir_all(&root).unwrap();
    let inbox_path = root.join("not-a-directory");
    std::fs::write(&inbox_path, "keep me").unwrap();

    let result = inbox::notify(
        &inbox_path,
        "00000000-0000-7000-8000-000000000001",
        inbox::Note::Idle,
        1_792_714_029_748,
    );

    assert!(result.is_err());
    assert_eq!(std::fs::read_to_string(inbox_path).unwrap(), "keep me");
    std::fs::remove_dir_all(root).unwrap();
}
