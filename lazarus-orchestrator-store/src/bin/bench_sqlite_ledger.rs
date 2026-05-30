use rusqlite::{Connection, params};
use std::path::PathBuf;
use std::time::Instant;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args = std::env::args().collect::<Vec<_>>();
    let count = args
        .get(1)
        .map(|value| value.parse::<usize>())
        .transpose()
        .map_err(|error| error.to_string())?
        .unwrap_or(100_000);
    let batch_size = args
        .get(2)
        .map(|value| value.parse::<usize>())
        .transpose()
        .map_err(|error| error.to_string())?
        .unwrap_or(1_000);
    if count == 0 || batch_size == 0 {
        return Err("count and batch_size must be > 0".to_string());
    }
    let db_path = args
        .get(3)
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("lazarus-sqlite-ledger-bench.sqlite"));
    let mut conn = Connection::open(&db_path).map_err(|error| error.to_string())?;
    conn.execute_batch(
        "
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS shadow_ledger (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            request_id TEXT NOT NULL,
            verdict TEXT NOT NULL,
            report_json TEXT NOT NULL
        );
        DELETE FROM shadow_ledger;
        ",
    )
    .map_err(|error| error.to_string())?;

    let start = Instant::now();
    let mut written = 0;
    while written < count {
        let end = std::cmp::min(written + batch_size, count);
        let tx = conn.transaction().map_err(|error| error.to_string())?;
        {
            let mut stmt = tx
                .prepare(
                    "INSERT INTO shadow_ledger(request_id, verdict, report_json)
                     VALUES (?1, ?2, ?3)",
                )
                .map_err(|error| error.to_string())?;
            for index in written..end {
                let request_id = format!("bench-{index}");
                let report_json = format!(
                    "{{\"request_id\":\"{request_id}\",\"operation\":\"bench\",\"verdict\":\"MATCH\",\"primary_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"shadow_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"diff\":{{}},\"elapsed_ms\":1,\"error\":null}}"
                );
                stmt.execute(params![request_id, "MATCH", report_json])
                    .map_err(|error| error.to_string())?;
            }
        }
        tx.commit().map_err(|error| error.to_string())?;
        written = end;
    }
    let elapsed = start.elapsed();
    let tps = count as f64 / elapsed.as_secs_f64();
    println!(
        "sqlite_ledger_bench count={count} batch_size={batch_size} elapsed_ms={} tps={:.2} db={}",
        elapsed.as_millis(),
        tps,
        db_path.display()
    );
    Ok(())
}
