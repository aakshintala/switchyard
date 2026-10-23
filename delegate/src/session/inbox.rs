use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Note {
    Idle,
    Dead,
}

pub fn utc_stamp(ms: u64) -> String {
    let seconds = ms / 1_000;
    let days = (seconds / 86_400) as i64;
    let z = days + 719_468;
    let era = z / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_part = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_part + 2) / 5 + 1;
    let month = if month_part < 10 {
        month_part + 3
    } else {
        month_part - 9
    };
    if month <= 2 {
        year += 1;
    }

    let second_of_day = seconds % 86_400;
    let hour = second_of_day / 3_600;
    let minute = (second_of_day % 3_600) / 60;
    let second = second_of_day % 60;
    format!("{year:04}{month:02}{day:02}T{hour:02}{minute:02}{second:02}Z")
}

pub fn notify(inbox: &Path, id: &str, note: Note, now_ms: u64) -> std::io::Result<PathBuf> {
    fs::create_dir_all(inbox)?;
    let sender = format!("session-{id}");
    let stamp = utc_stamp(now_ms);
    let pid = std::process::id();
    let random = crate::util::random_uuid().replace('-', "");
    let file_name = format!("{sender}-{stamp}-{pid}-{random}.md");
    let destination = inbox.join(file_name);
    let temporary = inbox.join(format!(".tmp.{}.tmp", crate::util::random_uuid()));
    let content = match note {
        Note::Idle => format!("[session {id} idle]\n"),
        Note::Dead => format!("[session {id} dead]\n"),
    };

    use std::os::unix::fs::OpenOptionsExt;
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(content.as_bytes())?;
        drop(file);
        fs::rename(&temporary, &destination)?;
        Ok(destination)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
