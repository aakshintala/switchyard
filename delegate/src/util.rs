use std::io::Read;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

/// Cancellation flag shared between a request and the work it started.
pub type Abort = Arc<AtomicBool>;

/// Serialize an f64 the way `JSON.stringify` does: integral values without a trailing `.0`.
pub fn js_num<S: serde::Serializer>(v: &f64, s: S) -> Result<S::Ok, S::Error> {
    if v.is_finite() && v.fract() == 0.0 && v.abs() < 9.007_199_254_740_992e15 {
        s.serialize_i64(*v as i64)
    } else if v.is_finite() {
        s.serialize_f64(*v)
    } else {
        s.serialize_none()
    }
}

pub fn js_num_opt<S: serde::Serializer>(v: &Option<f64>, s: S) -> Result<S::Ok, S::Error> {
    match v {
        Some(n) => js_num(n, s),
        None => s.serialize_none(),
    }
}

/// Deserialize a field as `None` when it has the wrong shape, rather than failing the whole struct.
pub fn lenient<'de, D, T>(d: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    let v = <serde_json::Value as serde::Deserialize>::deserialize(d)?;
    Ok(serde_json::from_value(v).ok())
}

pub fn tail(s: &str, max_bytes: usize) -> String {
    let buf = s.as_bytes();
    if buf.len() <= max_bytes {
        return s.to_string();
    }
    let slice = &buf[buf.len() - max_bytes..];
    String::from_utf8_lossy(slice).into_owned()
}

/// Removes ANSI escape sequences (CSI such as colours, OSC such as hyperlinks,
/// and two-byte escapes). Captured children now start without `FORCE_COLOR` or
/// `CLICOLOR_FORCE` (`util::captured_command`), so this is the backstop for tools
/// that force colour another way (#78, #83, #85).
pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\x1b' {
            out.push(c);
            continue;
        }
        match chars.next() {
            // CSI: parameter and intermediate bytes, then one final byte in @..~.
            Some('[') => {
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            // OSC: ends at BEL or ST (ESC \).
            Some(']') => {
                while let Some(c) = chars.next() {
                    if c == '\x07' {
                        break;
                    }
                    if c == '\x1b' && chars.peek() == Some(&'\\') {
                        chars.next();
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// The `cargo-mutants` shim every job's `PATH` starts with: mutants never run
/// locally, so the shim refuses and points at the CI log (#435).
pub(crate) const MUTANTS_SHIM_MESSAGE: &str =
    "cargo mutants is CI-only; read the CI mutants log instead";

/// Directory holding the `cargo-mutants` shim, under delegate's state dir (#435).
pub(crate) fn mutants_shim_dir() -> std::path::PathBuf {
    crate::status_record::jobs_dir().join("shim")
}

fn mutants_shim_script() -> String {
    format!("#!/bin/sh\nprintf '%s\\n' '{MUTANTS_SHIM_MESSAGE}' >&2\nexit 1\n")
}

/// Write the shim once, idempotently: temp file, chmod 755, rename into place.
/// `None` when the write failed; the caller starts the job without the shim.
fn ensure_mutants_shim() -> Option<std::path::PathBuf> {
    let dir = mutants_shim_dir();
    let path = dir.join("cargo-mutants");
    let script = mutants_shim_script();
    match std::fs::read_to_string(&path) {
        Ok(existing) if existing == script => return Some(dir),
        _ => {}
    }
    if write_shim(&dir, &path, &script).is_err() {
        return None;
    }
    Some(dir)
}

fn write_shim(dir: &std::path::Path, path: &std::path::Path, script: &str) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".cargo-mutants.{}.tmp", random_uuid()));
    let written: std::io::Result<()> = (|| {
        std::fs::write(&tmp, script)?;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
        std::fs::rename(&tmp, path)?;
        Ok(())
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

static SHIM_WARN_ONCE: std::sync::Once = std::sync::Once::new();

/// A `Command` for a child whose output `delegate` captures: the parent's environment
/// minus `FORCE_COLOR` and `CLICOLOR_FORCE`, so CLIs don't colour piped output (#85).
/// Never set them to "" or "0" (many tools treat any value as force) and never set
/// `NO_COLOR` (cursor-agent lets `FORCE_COLOR` override it). Args, cwd, stdio and the
/// process group are the caller's to set.
///
/// Every command also runs with delegate's `cargo-mutants` shim first on `PATH`:
/// the shim prints `cargo mutants is CI-only; read the CI mutants log instead`
/// on stderr and exits 1, so a job can never run mutants locally (#435). When the
/// shim cannot be written the command starts without it and one warning goes to stderr.
pub(crate) fn captured_command(program: impl AsRef<std::ffi::OsStr>) -> std::process::Command {
    let mut cmd = std::process::Command::new(program);
    cmd.env_remove("FORCE_COLOR").env_remove("CLICOLOR_FORCE");
    match ensure_mutants_shim() {
        Some(dir) => {
            let mut path = std::ffi::OsString::from(dir.as_os_str());
            path.push(":");
            match std::env::var_os("PATH") {
                Some(old) if !old.is_empty() => path.push(old),
                _ => path.push("/usr/bin:/bin"),
            }
            cmd.env("PATH", path);
        }
        None => {
            SHIM_WARN_ONCE.call_once(|| {
                eprintln!(
                    "delegate: cannot write cargo-mutants shim; starting job without it (#435)"
                );
            });
        }
    }
    cmd
}

pub fn clamp_wait(ms: f64) -> f64 {
    ms.clamp(1000.0, 600_000.0)
}

pub fn random_uuid() -> String {
    let mut bytes = [0u8; 16];
    let rc = unsafe { libc::getentropy(bytes.as_mut_ptr() as *mut libc::c_void, 16) };
    if rc != 0 {
        let mut f = std::fs::File::open("/dev/urandom").expect("urandom");
        f.read_exact(&mut bytes).expect("urandom read");
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
}

pub fn xdg_config_home() -> std::path::PathBuf {
    match std::env::var_os("XDG_CONFIG_HOME") {
        Some(p) if !p.is_empty() => std::path::PathBuf::from(p),
        _ => homedir().join(".config"),
    }
}

pub fn homedir() -> std::path::PathBuf {
    if let Ok(h) = std::env::var("HOME") {
        return std::path::PathBuf::from(h);
    }
    std::path::PathBuf::from("/")
}

pub fn json_pretty(value: &impl serde::Serialize) -> String {
    serde_json::to_string_pretty(value).unwrap_or_else(|_| "null".to_string())
}

pub fn json_compact(value: &impl serde::Serialize) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "null".to_string())
}

pub fn is_finite_number(v: &serde_json::Value) -> Option<f64> {
    v.as_f64().filter(|n| n.is_finite())
}

/// Node `path.resolve` without requiring the path to exist.
pub fn resolve_path(p: &str) -> String {
    let path = if std::path::Path::new(p).is_absolute() {
        std::path::PathBuf::from(p)
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| std::path::PathBuf::from("."))
            .join(p)
    };
    normalize_path(&path)
}

pub fn normalize_path(path: &std::path::Path) -> String {
    use std::path::{Component, PathBuf};
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::Prefix(pref) => out.push(pref.as_os_str()),
            Component::RootDir => out.push(std::path::MAIN_SEPARATOR_STR),
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(c) => out.push(c),
        }
    }
    if out.as_os_str().is_empty() {
        return std::path::MAIN_SEPARATOR_STR.to_string();
    }
    out.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_ansi_handles_csi_osc_and_plain_text() {
        assert_eq!(strip_ansi("Fast\u{200b} plain"), "Fast\u{200b} plain");
        assert_eq!(strip_ansi("\x1b[1m\x1b[36mA\x1b[39m\x1b[22m"), "A");
        assert_eq!(strip_ansi("\x1b[2K\rB"), "\rB");
        assert_eq!(strip_ansi("\x1b]8;;http://x\x07link\x1b]8;;\x1b\\"), "link");
        assert_eq!(strip_ansi("\x1b7C\x1b8"), "C");
        assert_eq!(strip_ansi("cut\x1b["), "cut");
    }

    #[test]
    fn tail_keeps_short_strings() {
        assert_eq!(tail("hi", 2048), "hi");
    }

    #[test]
    fn js_num_matches_json_stringify() {
        #[derive(serde::Serialize)]
        struct T {
            #[serde(serialize_with = "js_num")]
            a: f64,
            #[serde(serialize_with = "js_num")]
            b: f64,
            #[serde(serialize_with = "js_num_opt")]
            c: Option<f64>,
        }
        let j = serde_json::to_string(&T {
            a: 12.0,
            b: 0.0123,
            c: Some(3.0),
        })
        .unwrap();
        assert_eq!(j, r#"{"a":12,"b":0.0123,"c":3}"#);
    }

    #[test]
    fn clamp_wait_window() {
        assert_eq!(clamp_wait(0.0), 1000.0);
        assert_eq!(clamp_wait(999_999.0), 600_000.0);
        assert_eq!(clamp_wait(5000.0), 5000.0);
    }

    /// #435: a command built through the seam runs with the shim dir first on PATH.
    #[test]
    fn captured_command_puts_mutants_shim_first_on_path() {
        let dir = mutants_shim_dir();
        let cmd = captured_command("true");
        let path = cmd
            .get_envs()
            .find(|(k, _)| *k == "PATH")
            .and_then(|(_, v)| v)
            .expect("captured_command sets PATH")
            .to_string_lossy()
            .into_owned();
        let first = path.split(':').next().expect("PATH has a first entry");
        assert_eq!(first, dir.to_string_lossy());
        assert!(dir.join("cargo-mutants").is_file());
    }
}
