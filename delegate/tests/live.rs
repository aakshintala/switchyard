//! Opt-in: real backends. Run with: cargo test --test live -- --ignored

use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};

#[test]
#[ignore = "needs a logged-in cursor-agent; spends a Cursor request"]
fn ask_multiplies_on_real_agent() {
    let dir = std::env::temp_dir().join(format!("delegate-live-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let bin = env!("CARGO_BIN_EXE_delegate");
    let mut run = Command::new(bin)
        .args(["run", "--model", "composer-2.5"])
        .current_dir(&dir)
        .env("TMPDIR", &dir)
        .env("XDG_CACHE_HOME", dir.join("xdg-cache"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    run.stdin
        .take()
        .unwrap()
        .write_all(b"What is 17 * 23? Answer with just the number.")
        .unwrap();
    let id = String::from_utf8_lossy(&run.wait_with_output().unwrap().stdout)
        .trim()
        .to_string();
    let watch = Command::new(bin)
        .args(["watch", &id, "--timeout", "300"])
        .current_dir(&dir)
        .env("TMPDIR", &dir)
        .env("XDG_CACHE_HOME", dir.join("xdg-cache"))
        .env_remove("CLAUDECODE")
        .output()
        .unwrap();
    let out = String::from_utf8_lossy(&watch.stdout);
    let rec: serde_json::Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!(rec["status"], "DONE");
    assert!(rec["result"]["text"].as_str().unwrap().contains("391"));
    assert!(
        rec["result"]["sessionId"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
    );
}

#[test]
#[ignore = "needs a logged-in pi; spends one muse-spark request"]
fn pi_live_plain_answer_records_a_fixture() {
    let dir = std::env::temp_dir().join(format!("delegate-live-pi-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // record.sh (and pi itself) run in this cwd; a repo keeps them happy.
    let init = Command::new("git")
        .args(["init", "-q"])
        .current_dir(&dir)
        .output()
        .unwrap();
    assert!(init.status.success());
    let script = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("scripts/record.sh");
    let mut record = Command::new(&script)
        .args([
            "pi",
            "opencode-go/muse-spark-1.3-contributor",
            "live-plain-answer",
            &dir.to_string_lossy(),
        ])
        .env("XDG_CACHE_HOME", dir.join("xdg-cache"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    record
        .stdin
        .take()
        .unwrap()
        .write_all(b"What is 17 * 23? Answer with just the number.")
        .unwrap();
    let out = record.wait_with_output().unwrap();
    assert!(
        out.status.success(),
        "record.sh failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let fixture = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/recorded/pi/live-plain-answer.stdout");
    let stdout = std::fs::read_to_string(&fixture).unwrap();
    let res = delegate::backends::pi::parse_stdout(&stdout, true, "");
    assert!(res.text.contains("391"), "{}", res.text);
    assert!(
        res.session_id.as_deref().is_some_and(|s| !s.is_empty()),
        "{res:?}"
    );
    assert!(res.cost_usd.is_some_and(|c| c > 0.0), "{res:?}");
}

/// Opt-in: real `claude`. Run with: cargo test --test live -- --ignored
/// Writes the redacted stream to tests/fixtures/recorded/claude/live-plain-answer.stdout.
#[test]
#[ignore = "needs a logged-in claude; spends a Claude request"]
fn ask_multiplies_on_real_claude() {
    let repo = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dir = std::env::temp_dir().join(format!("delegate-live-claude-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let raw = dir.join("raw.stdout");
    let real = real_claude();
    let wrapper = dir.join("claude-tee.sh");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\n'{}' \"$@\" > '{}'\nstatus=$?\ncat '{}'\nexit $status\n",
            real.display(),
            raw.display(),
            raw.display(),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();

    let bin = env!("CARGO_BIN_EXE_delegate");
    let mut run = Command::new(bin)
        .args(["run", "--model", "claude-sonnet-5-5"])
        .current_dir(&dir)
        .env("TMPDIR", &dir)
        .env("XDG_CACHE_HOME", dir.join("xdg-cache"))
        .env("CLAUDE_BIN", &wrapper)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    run.stdin
        .take()
        .unwrap()
        .write_all(b"What is 17 * 23?")
        .unwrap();
    let id = String::from_utf8_lossy(&run.wait_with_output().unwrap().stdout)
        .trim()
        .to_string();
    let watch = Command::new(bin)
        .args(["watch", &id, "--timeout", "300"])
        .current_dir(&dir)
        .env("TMPDIR", &dir)
        .env("XDG_CACHE_HOME", dir.join("xdg-cache"))
        .env_remove("CLAUDECODE")
        .env("CLAUDE_BIN", &wrapper)
        .output()
        .unwrap();
    let out = String::from_utf8_lossy(&watch.stdout);
    let rec: serde_json::Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!(rec["status"], "DONE");
    assert!(rec["result"]["text"].as_str().unwrap().contains("391"));

    let fixture = repo.join("tests/fixtures/recorded/claude/live-plain-answer.stdout");
    let jq = Command::new("jq")
        .current_dir(&repo)
        .args([
            "-rR",
            "-L",
            "scripts",
            r#"include "redact"; (fromjson? | redact | tojson) // ."#,
        ])
        .stdin(Stdio::from(std::fs::File::open(&raw).unwrap()))
        .stdout(Stdio::from(std::fs::File::create(&fixture).unwrap()))
        .status()
        .unwrap();
    assert!(jq.success(), "jq redact failed");
    assert!(fixture.metadata().unwrap().len() > 0);
}

fn real_claude() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("CLAUDE_BIN")
        && !p.is_empty()
    {
        return std::path::PathBuf::from(p);
    }
    if let Ok(out) = Command::new("which").arg("claude").output()
        && out.status.success()
    {
        let found = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !found.is_empty() {
            return std::path::PathBuf::from(found);
        }
    }
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp"))
        .join(".local/bin/claude")
}
