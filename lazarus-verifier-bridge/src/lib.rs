use lazarus_contracts::{DecisionExpr, DecisionIr, EquivalenceReport, EquivalenceVerdict};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerificationRequest {
    pub legacy: Value,
    pub refactored: Value,
    pub variable_domains: BTreeMap<String, Vec<i64>>,
    pub max_cases: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BridgeConfig {
    pub max_cases: u64,
}

impl Default for BridgeConfig {
    fn default() -> Self {
        Self { max_cases: 100_000 }
    }
}

pub fn decision_expr_to_kernel_json(expr: &DecisionExpr) -> Value {
    match expr {
        DecisionExpr::Const { value } => json!({ "const": value }),
        DecisionExpr::Var { name } => json!({ "var": name }),
        DecisionExpr::Add { left, right } => json!({
            "op": "add",
            "args": [
                decision_expr_to_kernel_json(left),
                decision_expr_to_kernel_json(right),
            ],
        }),
        DecisionExpr::Sub { left, right } => json!({
            "op": "sub",
            "args": [
                decision_expr_to_kernel_json(left),
                decision_expr_to_kernel_json(right),
            ],
        }),
        DecisionExpr::Mul { left, right } => json!({
            "op": "mul",
            "args": [
                decision_expr_to_kernel_json(left),
                decision_expr_to_kernel_json(right),
            ],
        }),
        DecisionExpr::Min { left, right } => json!({
            "op": "min",
            "args": [
                decision_expr_to_kernel_json(left),
                decision_expr_to_kernel_json(right),
            ],
        }),
        DecisionExpr::Max { left, right } => json!({
            "op": "max",
            "args": [
                decision_expr_to_kernel_json(left),
                decision_expr_to_kernel_json(right),
            ],
        }),
        DecisionExpr::Abs { value } => json!({
            "op": "abs",
            "args": [decision_expr_to_kernel_json(value)],
        }),
    }
}

pub fn build_verification_request(
    legacy: &DecisionIr,
    refactored: &DecisionIr,
    config: &BridgeConfig,
) -> Result<VerificationRequest, String> {
    legacy.validate_bounded()?;
    refactored.validate_bounded()?;

    if legacy.input_domains != refactored.input_domains {
        return Err("legacy and refactored input domains differ".to_string());
    }

    let cases = case_space(&legacy.input_domains);
    if cases > config.max_cases as u128 {
        return Err(format!(
            "case space {cases} exceeds bridge max_cases {}",
            config.max_cases
        ));
    }

    Ok(VerificationRequest {
        legacy: decision_expr_to_kernel_json(&legacy.expression),
        refactored: decision_expr_to_kernel_json(&refactored.expression),
        variable_domains: legacy.input_domains.clone(),
        max_cases: config.max_cases,
    })
}

pub fn parse_kernel_report(value: &Value) -> Result<EquivalenceReport, String> {
    let verdict = match required_str(value, "verdict")? {
        "EQUIVALENT" => EquivalenceVerdict::Equivalent,
        "COUNTEREXAMPLE" => EquivalenceVerdict::Counterexample,
        "INCONCLUSIVE" => EquivalenceVerdict::Inconclusive,
        "INVALID_INPUT" => EquivalenceVerdict::InvalidInput,
        other => return Err(format!("unknown kernel verdict: {other}")),
    };

    let variables = value
        .get("variables")
        .and_then(Value::as_array)
        .ok_or_else(|| "kernel report variables must be an array".to_string())?
        .iter()
        .map(|item| {
            item.as_str()
                .map(str::to_string)
                .ok_or_else(|| "kernel report variable must be a string".to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;

    let cases_checked = value
        .get("cases_checked")
        .and_then(Value::as_u64)
        .ok_or_else(|| "kernel report cases_checked must be u64".to_string())?;

    Ok(EquivalenceReport {
        verdict,
        variables,
        cases_checked,
        counterexample: parse_optional_i64_map(value.get("counterexample"))?,
        legacy_value: value.get("legacy_value").and_then(Value::as_i64),
        refactored_value: value.get("refactored_value").and_then(Value::as_i64),
        reason: value
            .get("reason")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

fn parse_optional_i64_map(value: Option<&Value>) -> Result<Option<BTreeMap<String, i64>>, String> {
    let Some(value) = value else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    let object = value
        .as_object()
        .ok_or_else(|| "counterexample must be an object".to_string())?;
    let mut map = BTreeMap::new();
    for (key, value) in object {
        let value = value
            .as_i64()
            .ok_or_else(|| format!("counterexample value for {key} must be i64"))?;
        map.insert(key.clone(), value);
    }
    Ok(Some(map))
}

fn required_str<'a>(value: &'a Value, key: &str) -> Result<&'a str, String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("kernel report {key} must be a string"))
}

fn case_space(domains: &BTreeMap<String, Vec<i64>>) -> u128 {
    domains.values().fold(1u128, |acc, domain| {
        acc.saturating_mul(domain.len() as u128)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::{DecisionExpr, DecisionIr};

    #[test]
    fn converts_decision_expr_to_kernel_json() {
        let expr = DecisionExpr::Add {
            left: Box::new(DecisionExpr::Var {
                name: "input".to_string(),
            }),
            right: Box::new(DecisionExpr::Const { value: 1 }),
        };

        assert_eq!(
            decision_expr_to_kernel_json(&expr),
            json!({
                "op": "add",
                "args": [
                    { "var": "input" },
                    { "const": 1 },
                ],
            })
        );
    }

    #[test]
    fn builds_request_for_matching_domains() {
        let legacy = ir(
            "legacy",
            DecisionExpr::Var {
                name: "x".to_string(),
            },
        );
        let refactored = ir(
            "refactored",
            DecisionExpr::Add {
                left: Box::new(DecisionExpr::Var {
                    name: "x".to_string(),
                }),
                right: Box::new(DecisionExpr::Const { value: 0 }),
            },
        );

        let request =
            build_verification_request(&legacy, &refactored, &BridgeConfig::default()).unwrap();

        assert_eq!(request.legacy, json!({ "var": "x" }));
        assert_eq!(request.variable_domains["x"], vec![-1, 0, 1]);
    }

    #[test]
    fn rejects_mismatched_domains() {
        let legacy = ir(
            "legacy",
            DecisionExpr::Var {
                name: "x".to_string(),
            },
        );
        let mut refactored = ir(
            "refactored",
            DecisionExpr::Var {
                name: "x".to_string(),
            },
        );
        refactored.input_domains.insert("y".to_string(), vec![0]);

        assert!(
            build_verification_request(&legacy, &refactored, &BridgeConfig::default()).is_err()
        );
    }

    #[test]
    fn parses_equivalent_kernel_report() {
        let report = parse_kernel_report(&json!({
            "verdict": "EQUIVALENT",
            "variables": ["x"],
            "cases_checked": 3,
            "counterexample": null,
            "legacy_value": null,
            "refactored_value": null,
            "reason": "all finite-domain cases matched",
        }))
        .unwrap();

        assert_eq!(report.verdict, EquivalenceVerdict::Equivalent);
        assert_eq!(report.variables, vec!["x".to_string()]);
        assert_eq!(report.cases_checked, 3);
    }

    #[test]
    fn parses_counterexample_kernel_report() {
        let report = parse_kernel_report(&json!({
            "verdict": "COUNTEREXAMPLE",
            "variables": ["x"],
            "cases_checked": 1,
            "counterexample": {"x": -1},
            "legacy_value": -1,
            "refactored_value": 0,
            "reason": "outputs differ",
        }))
        .unwrap();

        assert_eq!(report.verdict, EquivalenceVerdict::Counterexample);
        assert_eq!(report.counterexample.unwrap()["x"], -1);
        assert_eq!(report.legacy_value, Some(-1));
        assert_eq!(report.refactored_value, Some(0));
    }

    fn ir(id: &str, expression: DecisionExpr) -> DecisionIr {
        let mut input_domains = BTreeMap::new();
        input_domains.insert("x".to_string(), vec![-1, 0, 1]);
        DecisionIr {
            ir_id: id.to_string(),
            source_unit_id: "crate/src/lib.rs".to_string(),
            input_domains,
            expression,
            side_effects: Vec::new(),
            invariants: Vec::new(),
        }
    }
}
