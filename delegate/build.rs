use std::path::PathBuf;
use std::process::Command;

fn git_output(manifest_dir: &str, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .current_dir(manifest_dir)
        .args(args)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?;
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn watch_git_path(manifest_dir: &str, git_path: &str) {
    let path = PathBuf::from(git_path);
    let path = if path.is_absolute() {
        path
    } else {
        PathBuf::from(manifest_dir).join(path)
    };
    println!("cargo:rerun-if-changed={}", path.display());
}

fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default();
    // The paths that make up the binary. Watch them so the dirty marker below
    // tracks edits made after the last build-script run.
    let sources = ["src", "build.rs", "Cargo.toml", "Cargo.lock"];
    for source in sources {
        println!("cargo:rerun-if-changed={source}");
    }
    let commit = match git_output(&manifest_dir, &["rev-parse", "HEAD"]) {
        Some(head) => {
            let mut args = vec!["status", "--porcelain", "--"];
            args.extend(sources);
            // Uncommitted source edits: HEAD alone would claim a clean build.
            if git_output(&manifest_dir, &args).is_some() {
                format!("{head}-dirty")
            } else {
                head
            }
        }
        None => "unknown".to_string(),
    };
    println!("cargo:rustc-env=DELEGATE_BUILD_COMMIT={commit}");

    // Re-run when the checked-out commit changes, for both attached and
    // detached worktrees (the branch ref can live in the common git directory).
    if let Some(head) = git_output(&manifest_dir, &["rev-parse", "--git-path", "HEAD"]) {
        watch_git_path(&manifest_dir, &head);
    }
    if let Some(reference) = git_output(&manifest_dir, &["symbolic-ref", "-q", "HEAD"])
        && let Some(ref_path) = git_output(&manifest_dir, &["rev-parse", "--git-path", &reference])
    {
        // A packed ref has no loose file, and cargo treats a missing watched
        // path as always changed; packed-refs is watched below instead.
        let loose = PathBuf::from(&manifest_dir).join(&ref_path);
        if loose.exists() {
            watch_git_path(&manifest_dir, &ref_path);
        }
    }
    if let Some(packed_refs) =
        git_output(&manifest_dir, &["rev-parse", "--git-path", "packed-refs"])
    {
        watch_git_path(&manifest_dir, &packed_refs);
    }
}
