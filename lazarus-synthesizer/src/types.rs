use lazarus_artifact_runner::WasmArtifact;
use lazarus_breakwater::StateSnapshot;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::PathBuf;

pub const DEFAULT_MAX_ITERATIONS: usize = 5;
pub const DEFAULT_TRAINING_PERCENT: u8 = 30;
pub const DEFAULT_SYNTHESIS_FUEL: u64 = 20_000;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SynthesisVerdict {
    Accepted,
    CompileFailed,
    SemanticMismatch,
    PolicyRejected,
    ManualInterventionRequired,
}

#[derive(Clone, Debug)]
pub struct SynthesizerConfig {
    pub function_name: String,
    pub out_dir: PathBuf,
    pub rustc_bin: PathBuf,
    pub max_iterations: usize,
    pub training_percent: u8,
    pub fuel: u64,
    pub precompiled_cache_dir: Option<PathBuf>,
}

impl SynthesizerConfig {
    pub fn new(function_name: impl Into<String>, out_dir: impl Into<PathBuf>) -> Self {
        Self {
            function_name: function_name.into(),
            out_dir: out_dir.into(),
            rustc_bin: PathBuf::from("rustc"),
            max_iterations: DEFAULT_MAX_ITERATIONS,
            training_percent: DEFAULT_TRAINING_PERCENT,
            fuel: DEFAULT_SYNTHESIS_FUEL,
            precompiled_cache_dir: None,
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        validate_identifier(&self.function_name, "function_name")?;
        if self.max_iterations == 0 {
            return Err("max_iterations must be > 0".to_string());
        }
        if self.training_percent > 100 {
            return Err("training_percent must be <= 100".to_string());
        }
        if self.fuel == 0 {
            return Err("fuel must be > 0".to_string());
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BehaviorCase {
    pub case_id: String,
    pub payload: Value,
    pub expected: Value,
}

impl BehaviorCase {
    pub fn validate(&self) -> Result<(), String> {
        require_non_empty("case_id", &self.case_id)?;
        if !self.payload.is_object() {
            return Err(format!(
                "case {} payload must be a JSON object",
                self.case_id
            ));
        }
        self.expected
            .get("value")
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("case {} expected.value must be i64", self.case_id))?;
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SynthesisInput {
    pub legacy_source: String,
    pub input_order: Vec<String>,
    pub state_snapshots: Vec<StateSnapshot>,
    pub behavior_cases: Vec<BehaviorCase>,
}

impl SynthesisInput {
    pub fn validate(&self) -> Result<(), String> {
        require_non_empty("legacy_source", &self.legacy_source)?;
        if self.input_order.is_empty() {
            return Err("input_order must not be empty".to_string());
        }
        let mut seen = BTreeSet::new();
        for input in &self.input_order {
            validate_identifier(input, "input_order")?;
            if !seen.insert(input) {
                return Err(format!("duplicate input_order entry: {input}"));
            }
        }
        if self.behavior_cases.is_empty() {
            return Err("behavior_cases must not be empty".to_string());
        }
        for snapshot in &self.state_snapshots {
            snapshot.validate_ingestable()?;
        }
        for case in &self.behavior_cases {
            case.validate()?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OracleFeedback {
    pub kind: String,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OraclePrompt {
    pub iteration: usize,
    pub function_name: String,
    pub input_order: Vec<String>,
    pub legacy_source: String,
    pub visible_state_snapshots: Vec<StateSnapshot>,
    pub visible_behavior_cases: Vec<BehaviorCase>,
    pub prior_feedback: Vec<OracleFeedback>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OracleCandidate {
    pub rust_source: String,
    pub rationale: String,
}

pub trait OracleClient {
    fn propose(&mut self, prompt: &OraclePrompt) -> Result<OracleCandidate, String>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PromptStage {
    InitialGeneration,
    CompileFix,
    SemanticFix,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SourcePolicyReport {
    pub accepted: bool,
    pub violations: Vec<String>,
    pub maintainability: MaintainabilityReport,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MaintainabilityReport {
    pub accepted: bool,
    pub source_bytes: usize,
    pub source_lines: usize,
    pub branch_tokens: usize,
    pub max_source_bytes: usize,
    pub max_source_lines: usize,
    pub max_branch_tokens: usize,
    pub violations: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CompileFailure {
    pub iteration: usize,
    pub stderr: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SemanticMismatch {
    pub iteration: usize,
    pub split: CorpusSplit,
    pub case_id: String,
    pub payload: Value,
    pub expected: Value,
    pub actual: Option<Value>,
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CorpusSplit {
    Training,
    Blind,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct IterationReport {
    pub iteration: usize,
    pub candidate_hash: String,
    pub policy: SourcePolicyReport,
    pub compiled: bool,
    pub compile_error: Option<String>,
    pub mismatches: Vec<SemanticMismatch>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SynthesisReport {
    pub verdict: SynthesisVerdict,
    pub iterations: Vec<IterationReport>,
    pub training_case_count: usize,
    pub blind_case_count: usize,
    pub visible_snapshot_count: usize,
    pub accepted_source_hash: Option<String>,
    pub accepted_source: Option<String>,
    pub artifact: Option<WasmArtifact>,
    pub feedback: Vec<OracleFeedback>,
}

pub(crate) fn validate_identifier(value: &str, field: &str) -> Result<(), String> {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return Err(format!("{field} is required"));
    };
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return Err(format!("{field} must start with '_' or ASCII letter"));
    }
    if !chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric()) {
        return Err(format!(
            "{field} must contain only ASCII letters, digits, and '_'"
        ));
    }
    Ok(())
}

pub(crate) fn require_non_empty(field: &str, value: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        Err(format!("{field} must not be empty"))
    } else {
        Ok(())
    }
}
