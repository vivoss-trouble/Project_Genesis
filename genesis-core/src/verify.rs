use serde_json::{Value, json};

use crate::act::GenesisAction;
use crate::audit::VerificationResult;

pub fn verify_action(action: &GenesisAction, sense_payload: &str) -> (VerificationResult, Value) {
    let state = serde_json::from_str::<Value>(sense_payload).unwrap_or(Value::Null);

    match action {
        GenesisAction::Noop { reason } => (
            VerificationResult::Verified,
            json!({
                "policy": "noop_is_always_verified",
                "reason": reason,
            }),
        ),
        GenesisAction::Click { target, .. } if target == "#heal-btn" => {
            verify_fantasy_heal(target, &state)
        }
        GenesisAction::Click { target, .. }
        | GenesisAction::Type { target, .. }
        | GenesisAction::AssertUiState { target, .. } => verify_web_action(target, &state),
        GenesisAction::Key { code, .. } => (
            VerificationResult::Verified,
            json!({
                "policy": "key_dispatch_only",
                "code": code,
            }),
        ),
        GenesisAction::Wait { ms, .. } => (
            VerificationResult::Verified,
            json!({
                "policy": "wait_elapsed_by_next_tick",
                "ms": ms,
            }),
        ),
    }
}

fn verify_fantasy_heal(target: &str, state: &Value) -> (VerificationResult, Value) {
    let health = state
        .get("fantasy_state")
        .and_then(|fantasy_state| fantasy_state.get("health"))
        .and_then(Value::as_u64);

    let evidence = json!({
        "policy": "fantasy_heal_health_threshold",
        "target": target,
        "expected": { "health_gte": 90 },
        "actual": { "health": health },
    });

    match health {
        Some(value) if value >= 90 => (VerificationResult::Verified, evidence),
        Some(value) => (
            VerificationResult::Failed {
                reason: format!("health_not_recovered:{value}"),
            },
            evidence,
        ),
        None => (
            VerificationResult::Failed {
                reason: "missing_fantasy_health".to_string(),
            },
            evidence,
        ),
    }
}

fn verify_web_action(target: &str, state: &Value) -> (VerificationResult, Value) {
    let web_state = state.get("web_state");
    let last_error = web_state
        .and_then(|value| value.get("last_error"))
        .filter(|value| !value.is_null())
        .cloned();
    let last_error_kind = web_state
        .and_then(|value| value.get("last_error_kind"))
        .and_then(Value::as_str);
    let last_action_target = web_state
        .and_then(|value| value.get("last_action"))
        .and_then(|action| action.get("target"))
        .and_then(Value::as_str);
    let url = web_state
        .and_then(|value| value.get("url"))
        .and_then(Value::as_str);
    let title = web_state
        .and_then(|value| value.get("title"))
        .and_then(Value::as_str);

    let evidence = json!({
        "policy": "web_last_action_matches",
        "target": target,
        "failure_kind": last_error_kind,
        "last_action_target": last_action_target,
        "last_error": last_error,
        "url": url,
        "title": title,
    });

    if let Some(error) = last_error {
        let reason = match (last_error_kind, error.as_str()) {
            (Some(kind), Some(message)) => format!("web_failure:{kind}:{message}"),
            (Some(kind), None) => format!("web_failure:{kind}:{error}"),
            (None, Some(message)) => format!("web_last_error:{message}"),
            (None, None) => format!("web_last_error:{error}"),
        };
        return (VerificationResult::Failed { reason }, evidence);
    }

    if last_action_target == Some(target) {
        (VerificationResult::Verified, evidence)
    } else {
        (
            VerificationResult::Failed {
                reason: "web_action_not_observed".to_string(),
            },
            evidence,
        )
    }
}
