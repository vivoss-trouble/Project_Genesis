use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

pub const LAZARUS_CONTRACT_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceLanguage {
    Cobol,
    OldJava,
    Java,
    Rust,
    Python,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RiskLevel {
    Low,
    Medium,
    High,
    Critical,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodeUnit {
    pub unit_id: String,
    pub language: SourceLanguage,
    pub path: String,
    pub content_hash: String,
    pub entrypoints: Vec<String>,
    pub risk_level: RiskLevel,
}

impl CodeUnit {
    pub fn validate(&self) -> Result<(), String> {
        require_id("unit_id", &self.unit_id)?;
        require_non_empty("path", &self.path)?;
        require_hash("content_hash", &self.content_hash)?;
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyKind {
    Calls,
    Reads,
    Writes,
    Imports,
    Emits,
    ExternalIo,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyEdge {
    pub from_unit_id: String,
    pub to_unit_id: String,
    pub kind: DependencyKind,
    pub evidence: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyGraph {
    pub contract_version: u32,
    pub codebase_id: String,
    pub units: Vec<CodeUnit>,
    pub edges: Vec<DependencyEdge>,
}

impl DependencyGraph {
    pub fn new(codebase_id: impl Into<String>) -> Self {
        Self {
            contract_version: LAZARUS_CONTRACT_VERSION,
            codebase_id: codebase_id.into(),
            units: Vec::new(),
            edges: Vec::new(),
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.contract_version != LAZARUS_CONTRACT_VERSION {
            return Err(format!(
                "unsupported contract version: {}",
                self.contract_version
            ));
        }
        require_id("codebase_id", &self.codebase_id)?;
        let mut seen = std::collections::BTreeSet::new();
        for unit in &self.units {
            unit.validate()?;
            if !seen.insert(unit.unit_id.as_str()) {
                return Err(format!("duplicate code unit: {}", unit.unit_id));
            }
        }
        for edge in &self.edges {
            if !seen.contains(edge.from_unit_id.as_str()) {
                return Err(format!(
                    "edge references missing from_unit_id: {}",
                    edge.from_unit_id
                ));
            }
            if !seen.contains(edge.to_unit_id.as_str()) {
                return Err(format!(
                    "edge references missing to_unit_id: {}",
                    edge.to_unit_id
                ));
            }
            require_non_empty("edge.evidence", &edge.evidence)?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SideEffectKind {
    ReadOnly,
    DatabaseRead,
    DatabaseWrite,
    FileWrite,
    NetworkCall,
    TimeRead,
    RandomRead,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SideEffect {
    pub kind: SideEffectKind,
    pub target: String,
    pub evidence: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DecisionExpr {
    Const {
        value: i64,
    },
    Var {
        name: String,
    },
    Add {
        left: Box<DecisionExpr>,
        right: Box<DecisionExpr>,
    },
    Sub {
        left: Box<DecisionExpr>,
        right: Box<DecisionExpr>,
    },
    Mul {
        left: Box<DecisionExpr>,
        right: Box<DecisionExpr>,
    },
    Min {
        left: Box<DecisionExpr>,
        right: Box<DecisionExpr>,
    },
    Max {
        left: Box<DecisionExpr>,
        right: Box<DecisionExpr>,
    },
    Abs {
        value: Box<DecisionExpr>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DecisionIr {
    pub ir_id: String,
    pub source_unit_id: String,
    pub input_domains: BTreeMap<String, Vec<i64>>,
    pub expression: DecisionExpr,
    pub side_effects: Vec<SideEffect>,
    pub invariants: Vec<String>,
}

impl DecisionIr {
    pub fn validate_bounded(&self) -> Result<(), String> {
        require_id("ir_id", &self.ir_id)?;
        require_id("source_unit_id", &self.source_unit_id)?;
        if self.input_domains.is_empty() {
            return Err("input_domains must not be empty".to_string());
        }
        let mut total_cases: u128 = 1;
        for (name, domain) in &self.input_domains {
            require_id("input domain variable", name)?;
            if domain.is_empty() {
                return Err(format!("input domain {name} is empty"));
            }
            total_cases = total_cases.saturating_mul(domain.len() as u128);
        }
        if total_cases > 100_000 {
            return Err(format!(
                "bounded verification case space too large: {total_cases}"
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum EquivalenceVerdict {
    Equivalent,
    Counterexample,
    Inconclusive,
    InvalidInput,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EquivalenceReport {
    pub verdict: EquivalenceVerdict,
    pub variables: Vec<String>,
    pub cases_checked: u64,
    pub counterexample: Option<BTreeMap<String, i64>>,
    pub legacy_value: Option<i64>,
    pub refactored_value: Option<i64>,
    pub reason: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ShadowVerdict {
    Match,
    Mismatch,
    PrimaryError,
    ShadowError,
    Timeout,
    PolicyRejected,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ShadowReport {
    pub request_id: String,
    pub operation: String,
    pub verdict: ShadowVerdict,
    pub primary_hash: Option<String>,
    pub shadow_hash: Option<String>,
    pub diff: BTreeMap<String, Value>,
    pub elapsed_ms: u64,
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LazarusJobState {
    Discovered,
    Scanned,
    IrExtracted,
    VerifiedBounded,
    Generated,
    Compiled,
    ShadowRunning,
    PromotionCandidate,
    Approved,
    CutoverReady,
    FailedWithEvidence,
    ManualReview,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LazarusJobEvent {
    ScanCompleted {
        graph_hash: String,
    },
    IrExtracted {
        ir_hash: String,
    },
    BoundedVerificationPassed {
        report_hash: String,
    },
    RustGenerated {
        artifact_hash: String,
    },
    CompilePassed {
        artifact_hash: String,
    },
    ShadowStarted {
        ledger_path: String,
    },
    ShadowPromotionCandidate {
        sample_count: u64,
        mismatch_count: u64,
    },
    Approved {
        approver: String,
    },
    CutoverPrepared {
        runbook_hash: String,
    },
    Failed {
        reason: String,
        evidence_hash: String,
    },
    ManualReviewRequested {
        reason: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LazarusJob {
    pub contract_version: u32,
    pub job_id: String,
    pub codebase_id: String,
    pub state: LazarusJobState,
    pub evidence: BTreeMap<String, String>,
}

impl LazarusJob {
    pub fn new(job_id: impl Into<String>, codebase_id: impl Into<String>) -> Self {
        Self {
            contract_version: LAZARUS_CONTRACT_VERSION,
            job_id: job_id.into(),
            codebase_id: codebase_id.into(),
            state: LazarusJobState::Discovered,
            evidence: BTreeMap::new(),
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.contract_version != LAZARUS_CONTRACT_VERSION {
            return Err(format!(
                "unsupported contract version: {}",
                self.contract_version
            ));
        }
        require_id("job_id", &self.job_id)?;
        require_id("codebase_id", &self.codebase_id)?;
        Ok(())
    }
}

fn require_id(field: &str, value: &str) -> Result<(), String> {
    require_non_empty(field, value)?;
    if value.len() > 128 {
        return Err(format!("{field} exceeds 128 bytes"));
    }
    if !value.bytes().all(|byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.' | b':' | b'/')
    }) {
        return Err(format!("{field} contains unsupported characters"));
    }
    Ok(())
}

fn require_hash(field: &str, value: &str) -> Result<(), String> {
    require_non_empty(field, value)?;
    if value.len() < 16 || value.len() > 128 {
        return Err(format!("{field} must be 16..128 chars"));
    }
    if !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(format!("{field} must be hex"));
    }
    Ok(())
}

fn require_non_empty(field: &str, value: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        return Err(format!("{field} must not be empty"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dependency_graph_rejects_edges_to_missing_units() {
        let mut graph = DependencyGraph::new("bank-core");
        graph.units.push(CodeUnit {
            unit_id: "account".to_string(),
            language: SourceLanguage::OldJava,
            path: "src/Account.java".to_string(),
            content_hash: "0123456789abcdef".to_string(),
            entrypoints: vec!["post".to_string()],
            risk_level: RiskLevel::High,
        });
        graph.edges.push(DependencyEdge {
            from_unit_id: "account".to_string(),
            to_unit_id: "ledger".to_string(),
            kind: DependencyKind::Writes,
            evidence: "Account.post writes Ledger".to_string(),
        });

        assert!(graph.validate().is_err());
    }

    #[test]
    fn decision_ir_enforces_finite_case_space() {
        let mut domains = BTreeMap::new();
        domains.insert("x".to_string(), (0..400).collect());
        domains.insert("y".to_string(), (0..400).collect());
        let ir = DecisionIr {
            ir_id: "fee-ir".to_string(),
            source_unit_id: "fees".to_string(),
            input_domains: domains,
            expression: DecisionExpr::Var {
                name: "x".to_string(),
            },
            side_effects: Vec::new(),
            invariants: Vec::new(),
        };

        assert!(ir.validate_bounded().is_err());
    }
}
