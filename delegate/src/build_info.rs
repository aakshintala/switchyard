use std::path::{Path, PathBuf};
use std::process::Command;

pub const BUILD_COMMIT: &str = env!("DELEGATE_BUILD_COMMIT");

#[derive(Debug, Eq, PartialEq)]
enum BuildFreshness {
    Current {
        delegate_head: String,
    },
    Stale {
        build_commit: String,
        delegate_head: String,
    },
    UnknownBuildCommit,
    MissingCheckout(PathBuf),
    CannotCompare(PathBuf),
}

pub fn build_commit() -> &'static str {
    BUILD_COMMIT
}

/// A single status line shared by `delegate version`, `delegate doctor` and lanecheck.
pub fn status_line() -> String {
    freshness_status(check_freshness(BUILD_COMMIT, checkout_path().as_deref()))
}

fn checkout_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".agents"))
}

fn check_freshness(build_commit: &str, checkout: Option<&Path>) -> BuildFreshness {
    if build_commit.is_empty() || build_commit == "unknown" {
        return BuildFreshness::UnknownBuildCommit;
    }
    let Some(checkout) = checkout else {
        return BuildFreshness::MissingCheckout(PathBuf::from("~/.agents"));
    };
    if !checkout.is_dir() {
        return BuildFreshness::MissingCheckout(checkout.to_path_buf());
    }

    let Some(delegate_head) =
        git_output(checkout, &["log", "-1", "--format=%H", "--", "delegate/"])
    else {
        return BuildFreshness::CannotCompare(checkout.to_path_buf());
    };
    match Command::new("git")
        .arg("-C")
        .arg(checkout)
        .args(["merge-base", "--is-ancestor", &delegate_head, build_commit])
        .output()
    {
        Ok(output) if output.status.success() => BuildFreshness::Current { delegate_head },
        Ok(output) if output.status.code() == Some(1) => BuildFreshness::Stale {
            build_commit: build_commit.to_string(),
            delegate_head,
        },
        _ => BuildFreshness::CannotCompare(checkout.to_path_buf()),
    }
}

fn git_output(checkout: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(checkout)
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

fn freshness_status(freshness: BuildFreshness) -> String {
    match freshness {
        BuildFreshness::Current { delegate_head } => {
            format!("ok    delegate binary is current: delegate/ is at {delegate_head}\n")
        }
        BuildFreshness::Stale {
            build_commit,
            delegate_head,
        } => format!(
            "warn  delegate binary is stale: built from {build_commit}, but delegate/ is at {delegate_head}\n"
        ),
        BuildFreshness::UnknownBuildCommit => {
            "skip  delegate build freshness: build commit is unknown\n".into()
        }
        BuildFreshness::MissingCheckout(path) => format!(
            "skip  delegate build freshness: checkout is missing ({})\n",
            path.display()
        ),
        BuildFreshness::CannotCompare(path) => format!(
            "skip  delegate build freshness: cannot inspect delegate/ in {}\n",
            path.display()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TempRepo(PathBuf);

    impl TempRepo {
        fn new() -> Self {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "delegate-build-freshness-{}-{unique}",
                std::process::id()
            ));
            fs::create_dir_all(path.join("delegate")).unwrap();
            git(&path, &["init", "-q"]);
            git(&path, &["config", "user.email", "test@example.invalid"]);
            git(&path, &["config", "user.name", "Delegate build test"]);
            Self(path)
        }

        fn commit(&self, path: &str, contents: &str) -> String {
            fs::write(self.0.join(path), contents).unwrap();
            git(&self.0, &["add", path]);
            git(&self.0, &["commit", "-qm", "test commit"]);
            git(&self.0, &["rev-parse", "HEAD"])
        }
    }

    impl Drop for TempRepo {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn git(repo: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(repo)
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap().trim().to_string()
    }

    #[test]
    fn stale_build_warning_names_both_commits_and_ignores_later_unrelated_commits() {
        let _env = crate::test_env::lock();
        let repo = TempRepo::new();
        let build_commit = repo.commit("delegate/source", "old build\n");
        let delegate_head = repo.commit("delegate/source", "new delegate source\n");

        let warning = freshness_status(check_freshness(&build_commit, Some(&repo.0)));
        assert_eq!(
            warning,
            format!(
                "warn  delegate binary is stale: built from {build_commit}, but delegate/ is at {delegate_head}\n"
            )
        );

        let checkout_head = repo.commit("README", "unrelated later change\n");
        assert_eq!(
            check_freshness(&delegate_head, Some(&repo.0)),
            BuildFreshness::Current { delegate_head }
        );
        assert_ne!(checkout_head, build_commit);
    }

    #[test]
    fn unknown_build_and_missing_checkout_are_skips_not_stale_warnings() {
        assert_eq!(
            freshness_status(check_freshness("unknown", None)),
            "skip  delegate build freshness: build commit is unknown\n"
        );
        assert_eq!(
            freshness_status(check_freshness(
                "0123456789012345678901234567890123456789",
                None
            )),
            "skip  delegate build freshness: checkout is missing (~/.agents)\n"
        );
    }
}
