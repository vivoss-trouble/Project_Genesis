use lazarus_contracts::{DecisionIr, EquivalenceReport};
use lazarus_verifier_bridge::{
    BridgeConfig, VerificationRequest, build_verification_request, parse_kernel_report,
};
use serde_json::Value;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const PYTHON_DRIVER: &str = r#"
import importlib.util
import json
import sys

kernel_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("lazarus_verification_kernel", kernel_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

request = json.load(sys.stdin)
report = module.prove_equivalent(
    request["legacy"],
    request["refactored"],
    request["variable_domains"],
    int(request.get("max_cases", 100000)),
)
print(report.to_json())
"#;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunnerConfig {
    pub python_bin: PathBuf,
    pub kernel_path: PathBuf,
}

impl RunnerConfig {
    pub fn new(python_bin: impl Into<PathBuf>, kernel_path: impl Into<PathBuf>) -> Self {
        Self {
            python_bin: python_bin.into(),
            kernel_path: kernel_path.into(),
        }
    }

    pub fn repo_default(repo_root: impl AsRef<Path>) -> Self {
        Self::new(
            "python3",
            repo_root.as_ref().join("engine/VerificationKernel.py"),
        )
    }
}

pub fn run_verification(
    request: &VerificationRequest,
    config: &RunnerConfig,
) -> Result<EquivalenceReport, String> {
    validate_runner_config(config)?;
    let request_json = serde_json::to_vec(request).map_err(|error| error.to_string())?;
    let mut child = Command::new(&config.python_bin)
        .arg("-c")
        .arg(PYTHON_DRIVER)
        .arg(&config.kernel_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("failed to spawn python verifier: {error}"))?;

    {
        let stdin = child
            .stdin
            .as_mut()
            .ok_or_else(|| "failed to open python verifier stdin".to_string())?;
        stdin
            .write_all(&request_json)
            .map_err(|error| format!("failed to write verifier request: {error}"))?;
    }

    let output = child
        .wait_with_output()
        .map_err(|error| format!("failed to wait for python verifier: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "python verifier exited with status {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let stdout = String::from_utf8(output.stdout)
        .map_err(|error| format!("python verifier stdout was not utf-8: {error}"))?;
    let value = serde_json::from_str::<Value>(stdout.trim()).map_err(|error| {
        format!("python verifier emitted invalid JSON: {error}; stdout={stdout:?}")
    })?;
    parse_kernel_report(&value)
}

pub fn run_ir_equivalence(
    legacy: &DecisionIr,
    refactored: &DecisionIr,
    bridge_config: &BridgeConfig,
    runner_config: &RunnerConfig,
) -> Result<EquivalenceReport, String> {
    let request = build_verification_request(legacy, refactored, bridge_config)?;
    run_verification(&request, runner_config)
}

fn validate_runner_config(config: &RunnerConfig) -> Result<(), String> {
    if config.python_bin.as_os_str().is_empty() {
        return Err("python_bin must not be empty".to_string());
    }
    if !config.kernel_path.is_file() {
        return Err(format!(
            "verification kernel not found: {}",
            config.kernel_path.display()
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::{DecisionExpr, EquivalenceVerdict};
    use std::collections::BTreeMap;

    #[test]
    fn runs_equivalent_kernel_request() {
        let request = VerificationRequest {
            legacy: serde_json::json!({ "var": "x" }),
            refactored: serde_json::json!({
                "op": "add",
                "args": [
                    { "var": "x" },
                    { "const": 0 },
                ],
            }),
            variable_domains: BTreeMap::from([("x".to_string(), vec![-1, 0, 1])]),
            max_cases: 100_000,
        };

        let report = run_verification(&request, &test_config()).unwrap();
        assert_eq!(report.verdict, EquivalenceVerdict::Equivalent);
    }

    #[test]
    fn runs_counterexample_kernel_request() {
        let request = VerificationRequest {
            legacy: serde_json::json!({ "var": "x" }),
            refactored: serde_json::json!({ "const": 0 }),
            variable_domains: BTreeMap::from([("x".to_string(), vec![-1, 0, 1])]),
            max_cases: 100_000,
        };

        let report = run_verification(&request, &test_config()).unwrap();
        assert_eq!(report.verdict, EquivalenceVerdict::Counterexample);
        assert_eq!(report.counterexample.unwrap()["x"], -1);
    }

    #[test]
    fn rejects_missing_kernel_path() {
        let request = VerificationRequest {
            legacy: serde_json::json!({ "const": 1 }),
            refactored: serde_json::json!({ "const": 1 }),
            variable_domains: BTreeMap::new(),
            max_cases: 100_000,
        };
        let config = RunnerConfig::new("python3", "/definitely/missing/VerificationKernel.py");

        assert!(run_verification(&request, &config).is_err());
    }

    #[test]
    fn runs_ir_equivalence() {
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

        let report = run_ir_equivalence(
            &legacy,
            &refactored,
            &BridgeConfig::default(),
            &test_config(),
        )
        .unwrap();
        assert_eq!(report.verdict, EquivalenceVerdict::Equivalent);
    }

    fn test_config() -> RunnerConfig {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        RunnerConfig::new(
            "python3",
            manifest_dir.join("../engine/VerificationKernel.py"),
        )
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
