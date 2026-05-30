use lazarus_breakwater::StateSnapshot;
use lazarus_synthesizer::BehaviorCase;
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

type SnapshotRecord = (StateSnapshot, usize);
type SnapshotReadResult = Result<SnapshotRecord, String>;

pub(crate) fn run_corpus_report(args: &[String]) -> Result<(), String> {
    if args.len() != 2 {
        return Err(
            "usage: genesis-cli corpus-report <snapshot-file-or-dir> <report-json>".to_string(),
        );
    }
    let input = PathBuf::from(&args[0]);
    let report_path = PathBuf::from(&args[1]);
    if let Some(parent) = report_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let snapshot_paths = collect_snapshot_paths(&input)?;
    let report = build_corpus_report(&snapshot_paths)?;
    fs::write(
        &report_path,
        serde_json::to_vec_pretty(&report).map_err(|error| error.to_string())?,
    )
    .map_err(|error| error.to_string())?;
    println!(
        "corpus-report complete: snapshots={}, valid={}, invalid={}, methods={}, report={}",
        report["total_snapshots"],
        report["valid_ingestable_count"],
        report["invalid_count"],
        report["method_count"],
        report_path.display()
    );
    Ok(())
}

pub(crate) fn run_corpus_ingest(args: &[String]) -> Result<(), String> {
    if args.len() != 2 {
        return Err(
            "usage: genesis-cli corpus-ingest <snapshot-file-or-dir> <out-dir>".to_string(),
        );
    }
    let input = PathBuf::from(&args[0]);
    let out_dir = PathBuf::from(&args[1]);
    fs::create_dir_all(&out_dir).map_err(|error| error.to_string())?;
    let snapshot_paths = collect_snapshot_paths(&input)?;
    let corpus_path = out_dir.join("state-snapshots.jsonl");
    let manifest_path = out_dir.join("corpus-ingest-manifest.json");
    let mut corpus = fs::File::create(&corpus_path).map_err(|error| error.to_string())?;
    let mut accepted = Vec::new();
    let mut rejected = Vec::new();

    for path in snapshot_paths {
        let reports = ingest_snapshot_file(&path, &mut corpus);
        for report in reports {
            match report {
                Ok(snapshot_hash) => accepted.push(serde_json::json!({
                    "path": path.to_string_lossy(),
                    "snapshot_hash": snapshot_hash,
                })),
                Err(error) => rejected.push(serde_json::json!({
                    "path": path.to_string_lossy(),
                    "reason": error,
                })),
            }
        }
    }

    let manifest = serde_json::json!({
        "accepted_count": accepted.len(),
        "rejected_count": rejected.len(),
        "corpus_path": corpus_path,
        "accepted": accepted,
        "rejected": rejected,
    });
    fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).map_err(|error| error.to_string())?,
    )
    .map_err(|error| error.to_string())?;

    println!(
        "corpus-ingest complete: accepted={}, rejected={}, corpus={}, manifest={}",
        manifest["accepted_count"],
        manifest["rejected_count"],
        corpus_path.display(),
        manifest_path.display()
    );
    Ok(())
}

pub(crate) fn load_valid_snapshots_for_method(
    input: &Path,
    business_method: &str,
) -> Result<Vec<StateSnapshot>, String> {
    let mut snapshots = Vec::new();
    for path in collect_snapshot_paths(input)? {
        for record in read_snapshot_records(&path)? {
            let (snapshot, _) = record?;
            if snapshot
                .trace_tags
                .get("business_method")
                .is_some_and(|method| method == business_method)
            {
                snapshot.validate_ingestable()?;
                snapshots.push(snapshot);
            }
        }
    }
    Ok(snapshots)
}

pub(crate) fn derive_row_count_behavior_case(
    snapshot: &StateSnapshot,
) -> Result<BehaviorCase, String> {
    let dependency = snapshot
        .downstream_dependencies
        .first()
        .ok_or_else(|| format!("snapshot {} has no dependencies", snapshot.snapshot_id))?;
    let id = extract_id_from_uri(&snapshot.upstream.uri)
        .or_else(|| {
            dependency
                .query_or_request
                .as_deref()
                .and_then(extract_id_from_sql)
        })
        .or_else(|| {
            dependency
                .rows
                .first()
                .and_then(|row| row.get("id"))
                .and_then(serde_json::Value::as_i64)
        })
        .ok_or_else(|| {
            format!(
                "snapshot {} has no id in upstream uri or first dependency row",
                snapshot.snapshot_id
            )
        })?;
    Ok(BehaviorCase {
        case_id: snapshot.snapshot_id.clone(),
        payload: serde_json::json!({ "id": id }),
        expected: serde_json::json!({ "value": dependency.rows.len() as i64 }),
    })
}

fn extract_id_from_uri(uri: &str) -> Option<i64> {
    let query = uri.split_once('?')?.1;
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        if key == "id" {
            value.parse::<i64>().ok()
        } else {
            None
        }
    })
}

fn extract_id_from_sql(sql: &str) -> Option<i64> {
    let normalized = sql.to_ascii_lowercase();
    let marker = "where id =";
    let start = normalized.find(marker)? + marker.len();
    normalized[start..]
        .trim_start()
        .split(|ch: char| !ch.is_ascii_digit() && ch != '-')
        .next()
        .and_then(|value| value.parse::<i64>().ok())
}

fn collect_snapshot_paths(input: &Path) -> Result<Vec<PathBuf>, String> {
    if input.is_file() {
        return Ok(vec![input.to_path_buf()]);
    }
    if !input.is_dir() {
        return Err(format!(
            "snapshot input path does not exist: {}",
            input.display()
        ));
    }
    let mut paths = fs::read_dir(input)
        .map_err(|error| error.to_string())?
        .map(|entry| {
            entry
                .map(|entry| entry.path())
                .map_err(|error| error.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    paths.retain(|path| {
        path.extension().is_some_and(|extension| {
            let extension = extension.to_string_lossy();
            extension == "json" || extension == "jsonl"
        })
    });
    paths.sort();
    Ok(paths)
}

fn ingest_snapshot_file(path: &Path, corpus: &mut fs::File) -> Vec<Result<String, String>> {
    let bytes = match fs::read(path).map_err(|error| error.to_string()) {
        Ok(bytes) => bytes,
        Err(error) => return vec![Err(error)],
    };
    if path
        .extension()
        .is_some_and(|extension| extension.to_string_lossy() == "jsonl")
    {
        let body = String::from_utf8_lossy(&bytes);
        return body
            .lines()
            .enumerate()
            .filter(|(_, line)| !line.trim().is_empty())
            .map(|(index, line)| {
                ingest_snapshot_bytes(line.as_bytes(), corpus)
                    .map_err(|error| format!("line {}: {error}", index + 1))
            })
            .collect();
    }
    vec![ingest_snapshot_bytes(&bytes, corpus)]
}

fn ingest_snapshot_bytes(bytes: &[u8], corpus: &mut fs::File) -> Result<String, String> {
    let snapshot: StateSnapshot = serde_json::from_slice(bytes)
        .map_err(|error| format!("invalid StateSnapshot JSON: {error}"))?;
    snapshot.validate_ingestable()?;
    let line = serde_json::to_vec(&snapshot).map_err(|error| error.to_string())?;
    corpus.write_all(&line).map_err(|error| error.to_string())?;
    corpus.write_all(b"\n").map_err(|error| error.to_string())?;
    Ok(snapshot.snapshot_hash)
}

#[derive(Default)]
struct MethodReport {
    total_snapshots: usize,
    valid_ingestable_count: usize,
    invalid_count: usize,
    complete_count: usize,
    truncated_invalid_count: usize,
    dropped_count: usize,
    missing_trace_tag_count: usize,
    dependency_count: usize,
    mutation_intent_count: usize,
    unique_operation_count: usize,
    unique_uri_count: usize,
    unique_dependency_query_count: usize,
    total_dependency_rows: usize,
    max_dependency_rows: usize,
    total_snapshot_bytes: usize,
    operations: BTreeMap<String, usize>,
    uris: BTreeMap<String, usize>,
    dependency_kinds: BTreeMap<String, usize>,
    dependency_queries: BTreeMap<String, usize>,
    validation_errors: BTreeMap<String, usize>,
}

fn build_corpus_report(paths: &[PathBuf]) -> Result<Value, String> {
    let mut methods = BTreeMap::<String, MethodReport>::new();
    let mut total_snapshots = 0usize;
    let mut valid_ingestable_count = 0usize;
    let mut invalid_count = 0usize;
    let mut missing_trace_tag_count = 0usize;

    for path in paths {
        for item in read_snapshot_records(path)? {
            total_snapshots += 1;
            let (snapshot, bytes_len) = match item {
                Ok(item) => item,
                Err(error) => {
                    invalid_count += 1;
                    let method = methods.entry("__parse_error__".to_string()).or_default();
                    method.invalid_count += 1;
                    increment(&mut method.validation_errors, error);
                    continue;
                }
            };
            let method_tag = snapshot
                .trace_tags
                .get("business_method")
                .cloned()
                .unwrap_or_else(|| {
                    missing_trace_tag_count += 1;
                    "__missing_business_method__".to_string()
                });
            let validation_error = snapshot.validate_ingestable().err();
            if validation_error.is_some() {
                invalid_count += 1;
            } else {
                valid_ingestable_count += 1;
            }
            let method = methods.entry(method_tag).or_default();
            method.total_snapshots += 1;
            method.total_snapshot_bytes += bytes_len;
            if validation_error.is_some() {
                method.invalid_count += 1;
            } else {
                method.valid_ingestable_count += 1;
            }
            if !snapshot.trace_tags.contains_key("business_method") {
                method.missing_trace_tag_count += 1;
            }
            match format!("{:?}", snapshot.status).as_str() {
                "Complete" => method.complete_count += 1,
                "TruncatedInvalid" => method.truncated_invalid_count += 1,
                "Dropped" => method.dropped_count += 1,
                _ => {}
            }
            if let Some(error) = validation_error {
                increment(&mut method.validation_errors, error);
            }
            increment(&mut method.operations, snapshot.operation.clone());
            increment(&mut method.uris, snapshot.upstream.uri.clone());
            method.dependency_count += snapshot.downstream_dependencies.len();
            method.mutation_intent_count += snapshot.mutation_intents.len();
            for dependency in &snapshot.downstream_dependencies {
                let row_count = dependency.rows.len();
                method.total_dependency_rows += row_count;
                method.max_dependency_rows = method.max_dependency_rows.max(row_count);
                increment(
                    &mut method.dependency_kinds,
                    format!("{:?}", dependency.kind),
                );
                if let Some(query) = &dependency.query_or_request {
                    increment(&mut method.dependency_queries, query.clone());
                }
            }
        }
    }

    let mut methods_json = BTreeMap::new();
    let mut pilot_candidates = Vec::new();
    for (method_tag, mut method) in methods {
        method.unique_operation_count = method.operations.len();
        method.unique_uri_count = method.uris.len();
        method.unique_dependency_query_count = method.dependency_queries.len();
        let readiness = pilot_readiness(&method);
        let avg_snapshot_bytes = method
            .total_snapshot_bytes
            .checked_div(method.total_snapshots)
            .unwrap_or(0);
        pilot_candidates.push(serde_json::json!({
            "business_method": method_tag,
            "recommended": readiness.recommended,
            "score": readiness.score,
            "reasons": readiness.reasons.clone(),
        }));
        methods_json.insert(
            method_tag,
            serde_json::json!({
                "total_snapshots": method.total_snapshots,
                "valid_ingestable_count": method.valid_ingestable_count,
                "invalid_count": method.invalid_count,
                "complete_count": method.complete_count,
                "truncated_invalid_count": method.truncated_invalid_count,
                "dropped_count": method.dropped_count,
                "missing_trace_tag_count": method.missing_trace_tag_count,
                "dependency_count": method.dependency_count,
                "mutation_intent_count": method.mutation_intent_count,
                "unique_operation_count": method.unique_operation_count,
                "unique_uri_count": method.unique_uri_count,
                "unique_dependency_query_count": method.unique_dependency_query_count,
                "total_dependency_rows": method.total_dependency_rows,
                "max_dependency_rows": method.max_dependency_rows,
                "avg_snapshot_bytes": avg_snapshot_bytes,
                "operations": method.operations,
                "uris": method.uris,
                "dependency_kinds": method.dependency_kinds,
                "dependency_queries": method.dependency_queries,
                "validation_errors": method.validation_errors,
                "pilot_readiness": {
                    "recommended": readiness.recommended,
                    "score": readiness.score,
                    "reasons": readiness.reasons,
                },
            }),
        );
    }
    pilot_candidates.sort_by(|left, right| {
        right["score"]
            .as_i64()
            .unwrap_or_default()
            .cmp(&left["score"].as_i64().unwrap_or_default())
            .then_with(|| {
                left["business_method"]
                    .as_str()
                    .unwrap_or_default()
                    .cmp(right["business_method"].as_str().unwrap_or_default())
            })
    });

    Ok(serde_json::json!({
        "total_snapshots": total_snapshots,
        "valid_ingestable_count": valid_ingestable_count,
        "invalid_count": invalid_count,
        "missing_trace_tag_count": missing_trace_tag_count,
        "method_count": methods_json.keys().filter(|key| !key.starts_with("__")).count(),
        "pilot_candidate_criteria": {
            "min_valid_snapshots": 100,
            "max_truncated_invalid_ratio": 0.01,
            "required_missing_trace_tag_count": 0,
            "max_mutation_intent_count": 0,
            "max_unique_dependency_query_count": 5
        },
        "pilot_candidates": pilot_candidates,
        "methods": methods_json,
    }))
}

struct PilotReadiness {
    recommended: bool,
    score: i64,
    reasons: Vec<String>,
}

fn pilot_readiness(method: &MethodReport) -> PilotReadiness {
    if method.total_snapshots == 0 {
        return PilotReadiness {
            recommended: false,
            score: 0,
            reasons: vec!["no snapshots captured".to_string()],
        };
    }
    let mut reasons = Vec::new();
    let mut score = 100i64;
    if method.valid_ingestable_count < 100 {
        reasons.push(format!(
            "valid_ingestable_count {} below 100",
            method.valid_ingestable_count
        ));
        score -= 30;
    }
    let truncated_ratio = method.truncated_invalid_count as f64 / method.total_snapshots as f64;
    if truncated_ratio > 0.01 {
        reasons.push(format!(
            "truncated_invalid_ratio {:.4} exceeds 0.01",
            truncated_ratio
        ));
        score -= 25;
    }
    if method.missing_trace_tag_count != 0 {
        reasons.push(format!(
            "missing_trace_tag_count {} must be 0",
            method.missing_trace_tag_count
        ));
        score -= 25;
    }
    if method.mutation_intent_count != 0 {
        reasons.push(format!(
            "mutation_intent_count {} should be 0 for first pilot",
            method.mutation_intent_count
        ));
        score -= 15;
    }
    if method.unique_dependency_query_count > 5 {
        reasons.push(format!(
            "unique_dependency_query_count {} exceeds 5",
            method.unique_dependency_query_count
        ));
        score -= 15;
    }
    if method.invalid_count != 0 {
        reasons.push(format!(
            "invalid_count {} should be 0",
            method.invalid_count
        ));
        score -= 10;
    }
    PilotReadiness {
        recommended: reasons.is_empty(),
        score: score.max(0),
        reasons,
    }
}

fn read_snapshot_records(path: &Path) -> Result<Vec<SnapshotReadResult>, String> {
    let bytes = fs::read(path).map_err(|error| error.to_string())?;
    if path
        .extension()
        .is_some_and(|extension| extension.to_string_lossy() == "jsonl")
    {
        let body = String::from_utf8_lossy(&bytes);
        return Ok(body
            .lines()
            .enumerate()
            .filter(|(_, line)| !line.trim().is_empty())
            .map(|(index, line)| {
                serde_json::from_slice::<StateSnapshot>(line.as_bytes())
                    .map(|snapshot| (snapshot, line.len()))
                    .map_err(|error| format!("{} line {}: {error}", path.display(), index + 1))
            })
            .collect());
    }
    Ok(vec![
        serde_json::from_slice::<StateSnapshot>(&bytes)
            .map(|snapshot| (snapshot, bytes.len()))
            .map_err(|error| format!("{}: {error}", path.display())),
    ])
}

fn increment(map: &mut BTreeMap<String, usize>, key: String) {
    *map.entry(key).or_insert(0) += 1;
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_breakwater::{
        DependencyKind, DownstreamDependency, MutationIntent, MutationKind, SnapshotContext,
        SnapshotLimits, StateSnapshot, StateSnapshotInput, UpstreamRequest,
    };

    #[test]
    fn corpus_ingest_accepts_valid_snapshot_and_rejects_unmasked_snapshot() {
        let root =
            std::env::temp_dir().join(format!("genesis-cli-corpus-ingest-{}", std::process::id()));
        let input = root.join("in");
        let out = root.join("out");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&input).unwrap();

        let valid = sample_snapshot("valid", serde_json::json!({"amount": 7, "card": "***"}));
        fs::write(
            input.join("valid.json"),
            serde_json::to_vec_pretty(&valid).unwrap(),
        )
        .unwrap();
        fs::write(
            input.join("valid.jsonl"),
            serde_json::to_string(&valid).unwrap(),
        )
        .unwrap();
        let mut invalid = sample_snapshot(
            "invalid",
            serde_json::json!({"amount": 8, "card_number": "4111111111111111"}),
        );
        invalid.snapshot_hash = invalid.compute_hash().unwrap();
        fs::write(
            input.join("invalid.json"),
            serde_json::to_vec_pretty(&invalid).unwrap(),
        )
        .unwrap();

        run_corpus_ingest(&[
            input.to_string_lossy().into_owned(),
            out.to_string_lossy().into_owned(),
        ])
        .unwrap();
        let corpus = fs::read_to_string(out.join("state-snapshots.jsonl")).unwrap();
        let manifest: Value =
            serde_json::from_slice(&fs::read(out.join("corpus-ingest-manifest.json")).unwrap())
                .unwrap();

        assert_eq!(corpus.lines().count(), 2);
        assert_eq!(manifest["accepted_count"], 2);
        assert_eq!(manifest["rejected_count"], 1);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn corpus_report_groups_by_business_method_and_counts_invalid_snapshots() {
        let root =
            std::env::temp_dir().join(format!("genesis-cli-corpus-report-{}", std::process::id()));
        let input = root.join("in");
        let report_path = root.join("report.json");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&input).unwrap();

        let valid = sample_snapshot("valid", serde_json::json!({"amount": 7, "card": "***"}));
        let mut invalid = sample_snapshot(
            "invalid",
            serde_json::json!({"amount": 8, "card_number": "4111111111111111"}),
        );
        invalid.snapshot_hash = invalid.compute_hash().unwrap();
        fs::write(
            input.join("snapshots.jsonl"),
            format!(
                "{}\n{}\n",
                serde_json::to_string(&valid).unwrap(),
                serde_json::to_string(&invalid).unwrap()
            ),
        )
        .unwrap();

        run_corpus_report(&[
            input.to_string_lossy().into_owned(),
            report_path.to_string_lossy().into_owned(),
        ])
        .unwrap();

        let report: Value = serde_json::from_slice(&fs::read(report_path).unwrap()).unwrap();
        assert_eq!(report["total_snapshots"], 2);
        assert_eq!(report["valid_ingestable_count"], 1);
        assert_eq!(report["invalid_count"], 1);
        assert_eq!(
            report["methods"]["com.bank.FeeService.fee"]["total_snapshots"],
            2
        );
        assert_eq!(
            report["methods"]["com.bank.FeeService.fee"]["unique_dependency_query_count"],
            1
        );
        assert_eq!(
            report["pilot_candidates"][0]["business_method"],
            "com.bank.FeeService.fee"
        );
        assert_eq!(report["pilot_candidates"][0]["recommended"], false);
        assert!(
            report["pilot_candidates"][0]["reasons"]
                .as_array()
                .unwrap()
                .iter()
                .any(|reason| reason
                    .as_str()
                    .unwrap()
                    .contains("valid_ingestable_count 1 below 100"))
        );
        let _ = fs::remove_dir_all(root);
    }

    fn sample_snapshot(id: &str, body: Value) -> StateSnapshot {
        let mut snapshot = StateSnapshot::new(StateSnapshotInput {
            snapshot_id: id.to_string(),
            trace_id: format!("trace-{id}"),
            operation: "fee".to_string(),
            context: SnapshotContext {
                captured_at_unix_ms: 1,
                epoch_unix_ms: 1,
                locale: Some("en_US".to_string()),
                principal: Some("user-1".to_string()),
                thread_name: Some("http-1".to_string()),
                env: BTreeMap::new(),
            },
            upstream: UpstreamRequest {
                method: "POST".to_string(),
                uri: "/fee".to_string(),
                headers: BTreeMap::from([("authorization_token".to_string(), "***".to_string())]),
                body,
                raw_body_sha256: None,
            },
            downstream_dependencies: vec![DownstreamDependency {
                dependency_id: "jdbc-1".to_string(),
                kind: DependencyKind::JdbcRead,
                target: "accounts".to_string(),
                query_or_request: Some("select balance from accounts".to_string()),
                rows: vec![BTreeMap::from([(
                    "balance".to_string(),
                    serde_json::json!(7),
                )])],
                response: Value::Null,
                deterministic: true,
            }],
            mutation_intents: vec![MutationIntent {
                intent_id: "write-1".to_string(),
                kind: MutationKind::DbUpdate,
                target: "accounts".to_string(),
                statement_or_request: Some("update accounts".to_string()),
                params: serde_json::json!({"card": "***"}),
            }],
            limits: SnapshotLimits::default(),
        })
        .unwrap();
        snapshot.trace_tags.insert(
            "business_method".to_string(),
            "com.bank.FeeService.fee".to_string(),
        );
        snapshot.snapshot_hash = snapshot.compute_hash().unwrap();
        snapshot
    }
}
