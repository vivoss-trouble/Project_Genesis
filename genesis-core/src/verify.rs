use serde_json::{Value, json};

use crate::act::{GenesisAction, WaitExpectedState};
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
        GenesisAction::Wait {
            ms, expected_state, ..
        } => verify_wait_condition(*ms, expected_state, &state),
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
}
