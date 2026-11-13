//! Human-readable `delegate models` and `delegate doctor` output.

use crate::backends::Backend;
use crate::config::build_deps;
use crate::doctor::{RunDoctorOpts, run_doctor};
use crate::types::Config;

/// `delegate models`: an aligned table of id, label, backend and $/1M prices.
pub fn models() -> Result<i32, String> {
    let deps = build_deps().map_err(|e| e.to_string())?;
    print!("{}", models_table(&deps.config));
    Ok(0)
}

/// `delegate doctor`: one ok/warn/skip/fail line per check. Exit 1 on any fail.
pub fn doctor() -> Result<i32, String> {
    let deps = build_deps().map_err(|e| e.to_string())?;
    let (text, code) = doctor_text(&deps.config);
    print!("{text}");
    Ok(code)
}

/// `delegate version`: print the package version, embedded build commit and freshness status.
pub fn version() -> i32 {
    print!("{}", version_text());
    0
}

fn version_text() -> String {
    format!(
        "delegate {} (built from {})\n{}",
        env!("CARGO_PKG_VERSION"),
        crate::build_info::build_commit(),
        crate::build_info::status_line()
    )
}

pub(crate) fn status_line(status: &str, msg: &str) -> String {
    format!("{status:<5} {msg}\n")
}

/// Rows sort by backend, then by id. A `*` marks the default model.
pub fn models_table(config: &Config) -> String {
    let mut rows: Vec<(&String, &crate::types::ModelEntry)> = config.models.iter().collect();
    rows.sort_by(|a, b| (&a.1.backend, a.0).cmp(&(&b.1.backend, b.0)));
    let ins: Vec<String> = rows
        .iter()
        .map(|(_, e)| format!("{:.2}", e.price.input))
        .collect();
    let outs: Vec<String> = rows
        .iter()
        .map(|(_, e)| format!("{:.2}", e.price.output))
        .collect();
    let tiers: Vec<String> = rows.iter().map(|(_, e)| e.tiers.join(",")).collect();
    let id_w = rows
        .iter()
        .map(|(id, _)| id.len())
        .max()
        .unwrap_or(0)
        .max("ID".len());
    let label_w = rows
        .iter()
        .map(|(_, e)| e.label.len())
        .max()
        .unwrap_or(0)
        .max("LABEL".len());
    let backend_w = rows
        .iter()
        .map(|(_, e)| e.backend.len())
        .max()
        .unwrap_or(0)
        .max("BACKEND".len());
    let in_w = ins
        .iter()
        .map(|s| s.len())
        .max()
        .unwrap_or(0)
        .max("$IN/1M".len());
    let out_w = outs
        .iter()
        .map(|s| s.len())
        .max()
        .unwrap_or(0)
        .max("$OUT/1M".len());
    let tiers_w = tiers
        .iter()
        .map(|s| s.len())
        .max()
        .unwrap_or(0)
        .max("TIERS".len());

    let header = format!(
        "  {0:<id_w$}  {1:<label_w$}  {2:<backend_w$}  {3:>in_w$}  {4:>out_w$}  {5:<tiers_w$}",
        "ID", "LABEL", "BACKEND", "$IN/1M", "$OUT/1M", "TIERS"
    );
    let mut out = format!("{}\n", header.trim_end());
    for (i, (id, entry)) in rows.iter().enumerate() {
        let mark = if *id == &config.default { "*" } else { " " };
        let row = format!(
            "{mark} {0:<id_w$}  {1:<label_w$}  {2:<backend_w$}  {3:>in_w$}  {4:>out_w$}  {5:<tiers_w$}",
            id, entry.label, entry.backend, ins[i], outs[i], tiers[i]
        );
        out.push_str(row.trim_end());
        out.push('\n');
    }
    out
}

pub fn doctor_text(config: &Config) -> (String, i32) {
    let report = run_doctor(RunDoctorOpts {
        config,
        resolve_bin: None,
        bin_exists: None,
        run_command: None,
        read_package_version: None,
    });
    let mut text = String::new();
    let mut failed = false;

    if report.plugin.version == "unknown" {
        text += &status_line("fail", "delegate: version unknown");
        failed = true;
    } else {
        text += &status_line(
            "ok",
            &format!(
                "delegate {} (built from {})",
                report.plugin.version,
                crate::build_info::build_commit()
            ),
        );
    }
    text += &crate::build_info::status_line();

    for backend in Backend::ALL {
        let (section, bad) = backend.doctor_lines(&report);
        text += &section;
        failed |= bad;
    }

    // One skip line per backend that is not implemented yet, with its model count.
    let mut skips: std::collections::BTreeMap<&str, usize> = std::collections::BTreeMap::new();
    for entry in config.models.values() {
        if Backend::from_name(&entry.backend).is_none() {
            *skips.entry(entry.backend.as_str()).or_default() += 1;
        }
    }
    for (backend, n) in &skips {
        let word = if *n == 1 { "model" } else { "models" };
        text += &status_line(
            "skip",
            &format!("{backend}: backend not implemented ({n} {word})"),
        );
    }

    (text, i32::from(failed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ModelEntry, Price};
    use std::collections::HashMap;

    fn config() -> Config {
        let mut models: HashMap<String, ModelEntry> = HashMap::new();
        for (id, label, backend) in [
            ("b-2", "B Two", "pi"),
            ("a-1", "A One", "claude"),
            ("composer-2.5", "Composer 2.5", "cursor"),
        ] {
            models.insert(
                id.into(),
                ModelEntry {
                    label: label.into(),
                    backend: backend.into(),
                    price: Price {
                        input: 1.0,
                        output: 2.0,
                        cache_read: 0.0,
                        cache_write: 0.0,
                    },
                    tiers: if id == "a-1" {
                        vec!["standard".into(), "strong".into()]
                    } else {
                        vec![]
                    },
                    reviewer: None,
                    allowed: false,
                },
            );
        }
        Config {
            default: "composer-2.5".into(),
            price_map: models.iter().map(|(k, v)| (k.clone(), v.price)).collect(),
            models,
            profile: crate::types::HostProfile::default(),
        }
    }

    #[test]
    fn table_sorts_and_marks_default() {
        let t = models_table(&config());
        let lines: Vec<&str> = t.lines().collect();
        assert_eq!(lines.len(), 4);
        assert!(lines[0].starts_with("  ID"));
        assert!(lines[0].contains("TIERS"));
        assert!(lines[1].ends_with("standard,strong"));
        assert!(lines.iter().all(|line| line.trim_end() == *line));
        let ids: Vec<&str> = lines[1..]
            .iter()
            .map(|l| l[2..].split_whitespace().next().unwrap())
            .collect();
        assert_eq!(ids, ["a-1", "composer-2.5", "b-2"]);
        assert!(lines[2].starts_with('*'));
        assert!(!lines[1].starts_with('*') && !lines[3].starts_with('*'));
    }
}
