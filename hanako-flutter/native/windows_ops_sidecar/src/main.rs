mod capture;
mod ocr;
mod protocol;
mod ui_parser;
mod uia;

use anyhow::Result;
use std::io::{self, BufRead, Write};

fn main() -> Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(line) => line,
            Err(err) => {
                eprintln!("stdin read failed: {err}");
                continue;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        let response = protocol::dispatch(&line);
        let payload = serde_json::to_string(&response)?;
        writeln!(stdout, "{payload}")?;
        stdout.flush()?;
    }

    Ok(())
}
