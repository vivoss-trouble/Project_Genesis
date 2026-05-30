use crate::types::{BehaviorCase, CorpusSplit, SemanticMismatch};
use lazarus_artifact_runner::{WasmArtifact, WasmArtifactExecutor};
use serde_json::Value;

pub(crate) fn validate_cases(
    iteration: usize,
    split: CorpusSplit,
    cases: &[BehaviorCase],
    artifact: &WasmArtifact,
    executor: &WasmArtifactExecutor,
    fuel: u64,
) -> Vec<SemanticMismatch> {
    cases
        .iter()
        .filter_map(
            |case| match executor.execute_as_json(artifact, &case.payload, fuel) {
                Ok(actual) if actual == case.expected => None,
                Ok(actual) => Some(SemanticMismatch {
                    iteration,
                    split,
                    case_id: case.case_id.clone(),
                    payload: case.payload.clone(),
                    expected: case.expected.clone(),
                    actual: Some(actual),
                    error: None,
                }),
                Err(error) => Some(SemanticMismatch {
                    iteration,
                    split,
                    case_id: case.case_id.clone(),
                    payload: case.payload.clone(),
                    expected: case.expected.clone(),
                    actual: None,
                    error: Some(error),
                }),
            },
        )
        .collect()
}

pub(crate) fn summarize_mismatches(mismatches: &[SemanticMismatch]) -> String {
    mismatches
        .iter()
        .take(5)
        .map(|mismatch| {
            format!(
                "{:?} case {} payload={} expected={} actual={} error={}",
                mismatch.split,
                mismatch.case_id,
                mismatch.payload,
                mismatch.expected,
                mismatch
                    .actual
                    .as_ref()
                    .map(Value::to_string)
                    .unwrap_or_else(|| "null".to_string()),
                mismatch.error.as_deref().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}
