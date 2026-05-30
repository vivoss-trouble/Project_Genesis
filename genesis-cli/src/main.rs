mod commands;

use commands::corpus::{run_corpus_ingest, run_corpus_report};
use commands::smoke::run_lazarus_smoke;
use commands::synthesis::run_synthesis_smoke;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args = std::env::args().collect::<Vec<_>>();
    match args.get(1).map(String::as_str) {
        Some("lazarus-smoke") => run_lazarus_smoke(&args[2..]),
        Some("corpus-ingest") => run_corpus_ingest(&args[2..]),
        Some("corpus-report") => run_corpus_report(&args[2..]),
        Some("synthesis-smoke") => run_synthesis_smoke(&args[2..]),
        _ => {
            eprintln!(
                "usage:\n  genesis-cli lazarus-smoke <crate-root> <legacy-fn> <refactored-fn> <out-dir>\n  genesis-cli corpus-ingest <snapshot-file-or-dir> <out-dir>\n  genesis-cli corpus-report <snapshot-file-or-dir> <report-json>\n  genesis-cli synthesis-smoke <snapshot-file-or-dir> <business-method> <java-source-file> <out-dir>"
            );
            Ok(())
        }
    }
}
