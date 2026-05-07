mod capture;
mod cuda_driver;
mod ocr;
mod protocol;
mod recovery;
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

        let response = protocol::dispatch_with_progress(&line, &mut |id, result| {
            let response = protocol::progress(id, result);
            match serde_json::to_string(&response) {
                Ok(payload) => {
                    let _ = writeln!(stdout, "{payload}");
                    let _ = stdout.flush();
                }
                Err(err) => eprintln!("progress encode failed: {err}"),
            }
        });
        let payload = serde_json::to_string(&response)?;
        writeln!(stdout, "{payload}")?;
        stdout.flush()?;
    }

    Ok(())
}
