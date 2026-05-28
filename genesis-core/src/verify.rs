use serde_json::{Value, json};

use crate::act::{GenesisAction, WaitExpectedState};
use crate::audit::VerificationResult;

pub fn verify_pending_action(
    action_id: &str,
    action: &GenesisAction,
    sense_payload: &str,
) -> (VerificationResult, Value) {
    verify_action_inner(Some(action_id), action, sense_payload)
}

#[cfg(test)]
pub fn verify_action(action: &GenesisAction, sense_payload: &str) -> (VerificationResult, Value) {
    verify_action_inner(None, action, sense_payload)
}

fn verify_action_inner(
    expected_action_id: Option<&str>,
    action: &GenesisAction,
    sense_payload: &str,
) -> (VerificationResult, Value) {
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
        GenesisAction::Wait {
            ms, expected_state, ..
        } => verify_wait_condition(*ms, expected_state, &state),
        GenesisAction::ClickPoint { target_id, .. } => {
            verify_dynamic_action(expected_action_id, target_id, &state)
        }
    }
}

fn verify_dynamic_action(
    expected_action_id: Option<&str>,
    target_id: &str,
    state: &Value,
) -> (VerificationResult, Value) {
    let dynamic_state = state.get("dynamic_state");
    let verdict = dynamic_state
        .and_then(|value| value.get("last_verdict"))
        .filter(|value| !value.is_null());

    let Some(verdict) = verdict else {
        let evidence = json!({
            "policy": "dynamic_last_verdict",
            "target": target_id,
            "failure_kind": "DynamicVerdictMissing",
            "last_verdict": Value::Null,
        });
        return (
            VerificationResult::Failed {
                reason: "dynamic_verdict_missing".to_string(),
            },
            evidence,
        );
    };

    let status = verdict.get("status").and_then(Value::as_str);
    let failure_kind = verdict.get("failure_kind").and_then(Value::as_str);
    let warning_kind = verdict.get("warning_kind").and_then(Value::as_str);
    let reason = verdict.get("reason").and_then(Value::as_str);
    let verdict_target = verdict.get("target_id").and_then(Value::as_str);
    let verdict_action_id = verdict.get("action_id").and_then(Value::as_str);

    let evidence = json!({
        "policy": "dynamic_last_verdict",
        "target": target_id,
        "expected_action_id": expected_action_id,
        "verdict_action_id": verdict_action_id,
        "verdict_target_id": verdict_target,
        "failure_kind": failure_kind,
        "warning_kind": warning_kind,
        "frame_delta": verdict.get("frame_delta").cloned().unwrap_or(Value::Null),
        "spatial_drift_px": verdict.get("spatial_drift_px").cloned().unwrap_or(Value::Null),
        "staleness_policy": verdict.get("staleness_policy").cloned().unwrap_or(Value::Null),
        "observed_frame_id": verdict.get("observed_frame_id").cloned().unwrap_or(Value::Null),
        "last_verdict": verdict,
    });

    if let Some(expected) = expected_action_id {
        if verdict_action_id != Some(expected) {
            return (
                VerificationResult::Failed {
                    reason: format!(
                        "dynamic_verdict_action_mismatch:expected={expected}:actual={}",
                        verdict_action_id.unwrap_or("<missing>")
                    ),
                },
                json!({
                    "policy": "dynamic_last_verdict",
                    "target": target_id,
                    "expected_action_id": expected,
                    "verdict_action_id": verdict_action_id,
                    "verdict_target_id": verdict_target,
                    "failure_kind": "DynamicVerdictActionMismatch",
                    "warning_kind": Value::Null,
                    "last_verdict": verdict,
                }),
            );
        }
    }

    match status {
        Some("Verified") if verdict_target == Some(target_id) => {
            (VerificationResult::Verified, evidence)
        }
        Some("Verified") => (
            VerificationResult::Failed {
                reason: "dynamic_verdict_target_mismatch".to_string(),
            },
            evidence,
        ),
        Some("Failed") => (
            VerificationResult::Failed {
                reason: match (failure_kind, reason) {
                    (Some(kind), Some(message)) => format!("dynamic_failure:{kind}:{message}"),
                    (Some(kind), None) => format!("dynamic_failure:{kind}"),
                    (None, Some(message)) => format!("dynamic_failure:{message}"),
                    (None, None) => "dynamic_failure:unknown".to_string(),
                },
            },
            evidence,
        ),
        _ => (
            VerificationResult::Failed {
                reason: "dynamic_verdict_invalid".to_string(),
            },
            evidence,
        ),
    }
}

fn verify_wait_condition(
    ms: u64,
    expected_state: &WaitExpectedState,
    state: &Value,
) -> (VerificationResult, Value) {
    match expected_state {
        WaitExpectedState::ElementVisible { selector } => {
            let web_state = state.get("web_state");
            let mode = web_state
                .and_then(|value| value.get("mode"))
                .and_then(Value::as_str);
            let observed = web_state
                .and_then(|value| value.get("elements"))
                .and_then(Value::as_array)
                .is_some_and(|elements| {
                    elements.iter().any(|element| {
                        let selector_matches =
                            element.get("selector").and_then(Value::as_str) == Some(selector);
                        let has_no_error = element.get("error").is_none();
                        let rendered_in_browser = mode != Some("playwright")
                            || element
                                .get("box")
                                .is_some_and(|bounding_box| !bounding_box.is_null());
                        selector_matches && has_no_error && rendered_in_browser
                    })
                });
            let evidence = json!({
                "policy": "one_tick_wait_condition",
                "ms": ms,
                "expected": {
                    "type": "element_visible",
                    "selector": selector,
                },
                "actual": {
                    "element_status": if observed { "visible" } else { "not_found" },
                    "web_mode": mode,
                },
                "failure_kind": if observed { Value::Null } else { json!("WaitConditionNotMet") },
            });

            if observed {
                (VerificationResult::Verified, evidence)
            } else {
                (
                    VerificationResult::Failed {
                        reason: format!("wait_condition_not_met:element_visible:{selector}"),
                    },
                    evidence,
                )
            }
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn wait_for(selector: &str) -> GenesisAction {
        GenesisAction::Wait {
            ms: 1_500,
            expected_state: WaitExpectedState::ElementVisible {
                selector: selector.to_string(),
            },
            reason: "observe next frame".to_string(),
        }
    }

    #[test]
    fn wait_verifies_when_expected_element_is_visible() {
        let payload = r#"{"web_state":{"mode":"http_probe","elements":[{"selector":"a"}]}}"#;
        let (result, evidence) = verify_action(&wait_for("a"), payload);
        assert!(matches!(result, VerificationResult::Verified));
        assert_eq!(evidence["actual"]["element_status"], "visible");
    }

    #[test]
    fn wait_fails_when_expected_element_is_absent() {
        let payload = r#"{"web_state":{"mode":"http_probe","elements":[{"selector":"a"}]}}"#;
        let (result, evidence) = verify_action(&wait_for("button"), payload);
        assert!(matches!(result, VerificationResult::Failed { .. }));
        assert_eq!(evidence["failure_kind"], "WaitConditionNotMet");
    }

    #[test]
    fn click_point_uses_dynamic_arena_verdict() {
        let action = GenesisAction::ClickPoint {
            target_id: "heal".to_string(),
            x: 10.0,
            y: 10.0,
            frame_id: 5,
            reason: "test".to_string(),
        };
        let payload = r#"{"dynamic_state":{"last_verdict":{"action_id":"act-9-1","status":"Verified","failure_kind":null,"warning_kind":"StaleButHit","target_id":"heal","frame_delta":4,"spatial_drift_px":3.0,"staleness_policy":"stale_but_hit","observed_frame_id":9}}}"#;
        let (result, evidence) = verify_pending_action("act-9-1", &action, payload);
        assert!(matches!(result, VerificationResult::Verified));
        assert_eq!(evidence["warning_kind"], "StaleButHit");
        assert_eq!(evidence["frame_delta"], 4);
    }

    #[test]
    fn click_point_fails_with_dynamic_failure_kind() {
        let action = GenesisAction::ClickPoint {
            target_id: "heal".to_string(),
            x: -100.0,
            y: -100.0,
            frame_id: 1,
            reason: "test".to_string(),
        };
        let payload = r#"{"dynamic_state":{"last_verdict":{"action_id":"act-3-1","status":"Failed","failure_kind":"StaleFrame","reason":"frame stale and point missed target","target_id":"heal","frame_delta":99}}}"#;
        let (result, evidence) = verify_pending_action("act-3-1", &action, payload);
        assert!(matches!(result, VerificationResult::Failed { .. }));
        assert_eq!(evidence["failure_kind"], "StaleFrame");
    }

    #[test]
    fn click_point_rejects_ghost_verdict_action_id() {
        let action = GenesisAction::ClickPoint {
            target_id: "heal".to_string(),
            x: 10.0,
            y: 10.0,
            frame_id: 5,
            reason: "test".to_string(),
        };
        let payload = r#"{"dynamic_state":{"last_verdict":{"action_id":"act-old","status":"Verified","failure_kind":null,"target_id":"heal","frame_delta":0}}}"#;
        let (result, evidence) = verify_pending_action("act-new", &action, payload);
        assert!(matches!(result, VerificationResult::Failed { .. }));
        assert_eq!(evidence["failure_kind"], "DynamicVerdictActionMismatch");
    }
}
