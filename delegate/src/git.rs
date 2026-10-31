use crate::types::ChangeSet;
use std::process::Command;

const MAX_BUFFER: usize = 16 * 1024 * 1024;

fn git(cwd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .output()
        .ok()?;
    // Oversized output is a failure, not a truncated (and so wrong) change-set.
    // ponytail: the whole output is buffered before this check; stream it if huge repos spike RSS.
    if !out.status.success() || out.stdout.len() > MAX_BUFFER {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

pub fn capture_head(cwd: &str, r#ref: Option<&str>) -> Option<String> {
    let r = r#ref.unwrap_or("HEAD");
    git(cwd, &["rev-parse", r]).and_then(|s| {
        let t = s.trim();
        if t.is_empty() {
            None
        } else {
            Some(t.to_string())
        }
    })
}

fn unquote(p: &str) -> String {
    if p.starts_with('"') && p.ends_with('"') && p.len() >= 2 {
        if let Ok(v) = serde_json::from_str::<String>(p) {
            return v;
        }
        return p[1..p.len() - 1].to_string();
    }
    p.to_string()
}

pub fn parse_porcelain(out: &str) -> Vec<String> {
    out.split('\n')
        .filter(|line| !line.is_empty())
        .map(|line| {
            let mut p = if line.len() >= 3 {
                line[3..].to_string()
            } else {
                String::new()
            };
            if let Some(arrow) = p.find(" -> ") {
                p = p[arrow + 4..].to_string();
            }
            unquote(&p)
        })
        .collect()
}

pub fn resolve_worktree_path(repo_cwd: &str, name: Option<&str>) -> Option<String> {
    let out = git(repo_cwd, &["worktree", "list", "--porcelain"])?;
    let mut worktrees: Vec<String> = Vec::new();
    for line in out.split('\n') {
        if let Some(rest) = line.strip_prefix("worktree ") {
            worktrees.push(rest.to_string());
        }
    }
    if worktrees.is_empty() {
        return None;
    }
    let primary = worktrees[0].clone();
    let secondary: Vec<_> = worktrees
        .iter()
        .filter(|wt| *wt != &primary)
        .cloned()
        .collect();
    if let Some(name) = name {
        return worktrees
            .into_iter()
            .find(|wt| wt == name || wt.ends_with(&format!("/{name}")));
    }
    if secondary.len() == 1 {
        return Some(secondary[0].clone());
    }
    None
}

pub fn git_delta(cwd: &str, head_before: Option<&str>) -> Option<ChangeSet> {
    let head_after = capture_head(cwd, None)?;
    let mut new_commits = Vec::new();
    let mut files_changed = Vec::new();
    let mut diffstat = String::new();
    if let Some(before) = head_before {
        let range = format!("{before}..HEAD");
        let rl = git(cwd, &["rev-list", &range]);
        let fc = git(cwd, &["diff", "--name-only", before]);
        let ds = git(cwd, &["diff", "--stat", before]);
        new_commits = rl
            .map(|s| {
                s.split('\n')
                    .map(|x| x.trim().to_string())
                    .filter(|x| !x.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        files_changed = fc
            .map(|s| {
                s.split('\n')
                    .map(|x| x.trim().to_string())
                    .filter(|x| !x.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        diffstat = ds.map(|s| s.trim_end().to_string()).unwrap_or_default();
    }
    let porcelain = git(cwd, &["status", "--porcelain"]);
    let uncommitted_files = porcelain
        .as_deref()
        .map(parse_porcelain)
        .unwrap_or_default();
    let dirty_after = !uncommitted_files.is_empty();
    Some(ChangeSet {
        head_before: head_before.map(|s| s.to_string()),
        head_after: Some(head_after),
        new_commits,
        files_changed,
        diffstat,
        uncommitted_files,
        dirty_after,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::process::Command;

    fn make_repo() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("cd-git-{}", crate::util::random_uuid()));
        fs::create_dir_all(&dir).unwrap();
        let g = |args: &[&str]| {
            Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .unwrap()
        };
        g(&["init", "-q"]);
        g(&["config", "user.email", "t@t.com"]);
        g(&["config", "user.name", "t"]);
        fs::write(dir.join("a.txt"), "one\n").unwrap();
        g(&["add", "."]);
        g(&["commit", "-q", "-m", "init"]);
        dir
    }

    #[test]
    fn parse_porcelain_strips_and_renames() {
        assert_eq!(parse_porcelain(" M src/a.ts"), ["src/a.ts"]);
        assert_eq!(parse_porcelain("?? new.txt"), ["new.txt"]);
        assert_eq!(parse_porcelain("R  old.txt -> new.txt"), ["new.txt"]);
    }

    #[test]
    fn parse_porcelain_matrix() {
        assert_eq!(parse_porcelain("A  added.ts"), ["added.ts"]);
        assert_eq!(parse_porcelain(" D deleted.ts"), ["deleted.ts"]);
        assert_eq!(parse_porcelain("UU conflicted.ts"), ["conflicted.ts"]);
        assert_eq!(parse_porcelain("!! ignored.ts"), ["ignored.ts"]);
        assert_eq!(parse_porcelain("?? \"my file.txt\""), ["my file.txt"]);
        assert_eq!(parse_porcelain(" M \"dir/a b.ts\""), ["dir/a b.ts"]);
        assert_eq!(
            parse_porcelain("R  \"old name\" -> \"new name\""),
            ["new name"]
        );
        assert_eq!(parse_porcelain(" M a.ts\n?? b.txt\n"), ["a.ts", "b.txt"]);
    }

    #[test]
    fn git_delta_null_outside_repo() {
        let _lock = crate::test_env::lock();
        let dir = std::env::temp_dir().join(format!("cd-nogit-{}", crate::util::random_uuid()));
        fs::create_dir_all(&dir).unwrap();
        let s = dir.to_string_lossy().into_owned();
        assert!(capture_head(&s, None).is_none());
        assert!(git_delta(&s, None).is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn git_delta_computes() {
        let _lock = crate::test_env::lock();
        let dir = make_repo();
        let s = dir.to_string_lossy().into_owned();
        let head0 = capture_head(&s, None).unwrap();
        let g = |args: &[&str]| {
            Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .unwrap()
        };
        fs::write(dir.join("a.txt"), "one\ntwo\n").unwrap();
        g(&["commit", "-q", "-am", "change"]);
        fs::write(dir.join("b.txt"), "untracked\n").unwrap();
        let cs = git_delta(&s, Some(&head0)).unwrap();
        assert_eq!(cs.head_before.as_deref(), Some(head0.as_str()));
        assert_ne!(cs.head_after.as_deref(), Some(head0.as_str()));
        assert_eq!(cs.new_commits.len(), 1);
        assert_eq!(cs.files_changed, ["a.txt"]);
        assert!(cs.dirty_after);
        assert_eq!(cs.uncommitted_files, ["b.txt"]);
        assert!(cs.diffstat.contains("a.txt"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn resolve_named_worktree() {
        let _lock = crate::test_env::lock();
        let dir = make_repo();
        let wt_dir = dir.join("wt-side");
        Command::new("git")
            .arg("-C")
            .arg(&dir)
            .args(["worktree", "add", "-q"])
            .arg(&wt_dir)
            .args(["-b", "wt1"])
            .output()
            .unwrap();
        let s = dir.to_string_lossy().into_owned();
        assert!(resolve_worktree_path(&s, None).is_some());
        let resolved = resolve_worktree_path(&s, Some("wt-side")).unwrap();
        assert!(resolved.ends_with("/wt-side"));
        assert!(resolve_worktree_path(&s, Some("missing")).is_none());
        let extra = dir.join("my-wt-side");
        Command::new("git")
            .arg("-C")
            .arg(&dir)
            .args(["worktree", "add", "-q"])
            .arg(&extra)
            .args(["-b", "wt2"])
            .output()
            .unwrap();
        assert!(resolve_worktree_path(&s, Some("y-wt-side")).is_none());
        Command::new("git")
            .arg("-C")
            .arg(&dir)
            .args(["worktree", "remove", "-f"])
            .arg(&extra)
            .output()
            .ok();
        Command::new("git")
            .arg("-C")
            .arg(&dir)
            .args(["worktree", "remove", "-f"])
            .arg(&wt_dir)
            .output()
            .ok();
        let _ = fs::remove_dir_all(&dir);
    }
}
