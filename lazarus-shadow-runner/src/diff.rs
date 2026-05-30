use crate::{ShadowEndpoint, ShadowRequest, ShadowRunnerConfig};
use lazarus_contracts::{ShadowReport, ShadowVerdict};
use serde_json::{Map, Value};
use sha2::{Digest as _, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::time::Instant;

pub fn execute_shadow_request(
    request: &ShadowRequest,
    primary: &ShadowEndpoint,
    shadow: &ShadowEndpoint,
    config: &ShadowRunnerConfig,
) -> ShadowReport {
    let start = Instant::now();
    let primary_result = primary(&request.payload);
    let shadow_payload = if config.inject_shadow_marker {
        inject_shadow_marker(request.payload.clone())
    } else {
        request.payload.clone()
    };
    let shadow_result = shadow(&shadow_payload);

    let elapsed_ms = start.elapsed().as_millis().min(u128::from(u64::MAX)) as u64;
    match (primary_result, shadow_result) {
        (Err(error), _) => report(
            request,
            ShadowVerdict::PrimaryError,
            None,
            None,
            BTreeMap::new(),
            elapsed_ms,
            Some(error),
        ),
        (Ok(primary_value), Err(error)) => report(
            request,
            ShadowVerdict::ShadowError,
            Some(&primary_value),
            None,
            BTreeMap::new(),
            elapsed_ms,
            Some(error),
        ),
        (Ok(primary_value), Ok(shadow_value)) => {
            let left = strip_ignored(&primary_value, &config.ignored_fields);
            let right = strip_ignored(&shadow_value, &config.ignored_fields);
            let diff = semantic_diff(&left, &right, config.numeric_tolerance, "$");
            report(
                request,
                if diff.is_empty() {
                    ShadowVerdict::Match
                } else {
                    ShadowVerdict::Mismatch
                },
                Some(&left),
                Some(&right),
                diff,
                elapsed_ms,
                None,
            )
        }
    }
}

fn report(
    request: &ShadowRequest,
    verdict: ShadowVerdict,
    primary: Option<&Value>,
    shadow: Option<&Value>,
    diff: BTreeMap<String, Value>,
    elapsed_ms: u64,
    error: Option<String>,
) -> ShadowReport {
    ShadowReport {
        request_id: request.request_id.clone(),
        operation: request.operation.clone(),
        verdict,
        primary_hash: primary.map(stable_hash),
        shadow_hash: shadow.map(stable_hash),
        diff,
        elapsed_ms,
        error,
    }
}

fn inject_shadow_marker(mut value: Value) -> Value {
    if let Value::Object(map) = &mut value {
        map.insert("_lazarus_shadow_mode".to_string(), Value::Bool(true));
    }
    value
}

fn strip_ignored(value: &Value, ignored_fields: &BTreeSet<String>) -> Value {
    match value {
        Value::Object(map) => {
            let mut stripped = Map::new();
            for (key, value) in map {
                if !ignored_fields.contains(key) {
                    stripped.insert(key.clone(), strip_ignored(value, ignored_fields));
                }
            }
            Value::Object(stripped)
        }
        Value::Array(items) => Value::Array(
            items
                .iter()
                .map(|item| strip_ignored(item, ignored_fields))
                .collect(),
        ),
        _ => value.clone(),
    }
}

fn semantic_diff(
    left: &Value,
    right: &Value,
    tolerance: f64,
    path: &str,
) -> BTreeMap<String, Value> {
    let mut diff = BTreeMap::new();
    match (left, right) {
        (Value::Object(left_map), Value::Object(right_map)) => {
            let keys = left_map
                .keys()
                .chain(right_map.keys())
                .cloned()
                .collect::<BTreeSet<_>>();
            for key in keys {
                let child_path = format!("{path}.{key}");
                match (left_map.get(&key), right_map.get(&key)) {
                    (Some(left_value), Some(right_value)) => {
                        diff.extend(semantic_diff(
                            left_value,
                            right_value,
                            tolerance,
                            &child_path,
                        ));
                    }
                    (Some(left_value), None) => {
                        diff.insert(
                            child_path,
                            serde_json::json!({"left": left_value, "right": "<missing>"}),
                        );
                    }
                    (None, Some(right_value)) => {
                        diff.insert(
                            child_path,
                            serde_json::json!({"left": "<missing>", "right": right_value}),
                        );
                    }
                    (None, None) => {}
                }
            }
        }
        (Value::Array(left_items), Value::Array(right_items)) => {
            if left_items.len() != right_items.len() {
                diff.insert(
                    format!("{path}.length"),
                    serde_json::json!({"left": left_items.len(), "right": right_items.len()}),
                );
            }
            for (index, (left_value, right_value)) in
                left_items.iter().zip(right_items.iter()).enumerate()
            {
                diff.extend(semantic_diff(
                    left_value,
                    right_value,
                    tolerance,
                    &format!("{path}[{index}]"),
                ));
            }
        }
        _ if values_equal(left, right, tolerance) => {}
        _ => {
            diff.insert(
                path.to_string(),
                serde_json::json!({"left": left, "right": right}),
            );
        }
    }
    diff
}

fn values_equal(left: &Value, right: &Value, tolerance: f64) -> bool {
    match (left, right) {
        (Value::Number(left_num), Value::Number(right_num)) => {
            match (left_num.as_f64(), right_num.as_f64()) {
                (Some(left), Some(right)) => (left - right).abs() <= tolerance,
                _ => left == right,
            }
        }
        _ => left == right,
    }
}

fn stable_hash(value: &Value) -> String {
    let stable = serde_json::to_vec(value).expect("serde_json::Value serialization cannot fail");
    let mut hasher = Sha256::new();
    hasher.update(stable);
    format!("{:x}", hasher.finalize())
}
