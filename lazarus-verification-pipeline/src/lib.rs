use lazarus_contracts::{DecisionIr, EquivalenceReport, EquivalenceVerdict, LazarusJobEvent};
use lazarus_ir_extractor::{ExtractResult, ExtractorConfig, extract_ir_from_scan};
use lazarus_orchestrator::{LazarusOrchestrator, StateTransition};
use lazarus_scanner::{ScanResult, ScannerConfig, scan_workspace};
use lazarus_verifier_bridge::BridgeConfig;
use lazarus_verifier_runner::{RunnerConfig, run_ir_equivalence};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct PipelineConfig {
    pub scanner: ScannerConfig,
    pub extractor: ExtractorConfig,
    pub bridge: BridgeConfig,
    pub runner: RunnerConfig,
}

impl PipelineConfig {
    pub fn repo_default(repo_root: impl AsRef<std::path::Path>) -> Self {
        Self {
            scanner: ScannerConfig::default(),
            extractor: ExtractorConfig::default(),
            bridge: BridgeConfig::default(),
            runner: RunnerConfig::repo_default(repo_root),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ScanExtractSummary {
    pub scan_unit_count: usize,
    pub scan_edge_count: usize,
    pub scan_skip_count: usize,
    pub ir_count: usize,
    pub ir_skip_count: usize,
}

#[derive(Clone, Debug)]
pub struct ScanExtractOutput {
    pub scan: ScanResult,
    pub extract: ExtractResult,
    pub transitions: Vec<StateTransition>,
    pub summary: ScanExtractSummary,
}

#[derive(Clone, Debug)]
pub struct VerificationOutput {
    pub report: EquivalenceReport,
    pub transition: Option<StateTransition>,
    pub report_hash: String,
}

pub fn run_scan_extract_stage(
    roots: &[PathBuf],
    orchestrator: &mut LazarusOrchestrator,
    job_id: &str,
    config: &PipelineConfig,
) -> Result<ScanExtractOutput, String> {
    let scan = scan_workspace(roots, &config.scanner);
    scan.validate()?;
    let graph_hash = stable_hash(&scan.graph)?;
    let scan_transition = orchestrator.apply(
        job_id,
        LazarusJobEvent::ScanCompleted {
            graph_hash: graph_hash.clone(),
        },
    )?;

    let extract = extract_ir_from_scan(&scan, &config.extractor);
    for ir in &extract.irs {
        ir.validate_bounded()?;
    }
    let ir_hash = stable_hash(&extract.irs)?;
    let ir_transition = orchestrator.apply(job_id, LazarusJobEvent::IrExtracted { ir_hash })?;

    let summary = ScanExtractSummary {
        scan_unit_count: scan.graph.units.len(),
        scan_edge_count: scan.graph.edges.len(),
        scan_skip_count: scan.skip_reasons.len(),
        ir_count: extract.irs.len(),
        ir_skip_count: extract.skip_reasons.len(),
    };

    Ok(ScanExtractOutput {
        scan,
        extract,
        transitions: vec![scan_transition, ir_transition],
        summary,
    })
}

pub fn run_bounded_verification_stage(
    orchestrator: &mut LazarusOrchestrator,
    job_id: &str,
    legacy: &DecisionIr,
    refactored: &DecisionIr,
    config: &PipelineConfig,
) -> Result<VerificationOutput, String> {
    let report = run_ir_equivalence(legacy, refactored, &config.bridge, &config.runner)?;
    let report_hash = stable_hash(&report)?;
    let transition = if report.verdict == EquivalenceVerdict::Equivalent {
        Some(orchestrator.apply(
            job_id,
            LazarusJobEvent::BoundedVerificationPassed {
                report_hash: report_hash.clone(),
            },
        )?)
    } else {
        None
    };

    Ok(VerificationOutput {
        report,
        transition,
        report_hash,
    })
}

pub fn find_ir_by_function_target<'a>(
    irs: &'a [DecisionIr],
    function_name: &str,
) -> Option<&'a DecisionIr> {
    irs.iter().find(|ir| {
        ir.side_effects
            .iter()
            .any(|effect| effect.target == function_name)
    })
}

fn stable_hash<T: Serialize>(value: &T) -> Result<String, String> {
    let bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    Ok(format!("{:x}", hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::LazarusJobState;
    use std::fs;
    use std::path::Path;

    #[test]
    fn scan_extract_stage_advances_to_ir_extracted() {
        let root = fixture(
            "scan_extract",
            "pub fn legacy(x: i64) -> i64 { x }\npub fn refactored(x: i64) -> i64 { x + 0 }\n",
        );
        let mut orchestrator = LazarusOrchestrator::new();
        orchestrator.create_job("job-1", "scan_extract").unwrap();

        let output = run_scan_extract_stage(
            std::slice::from_ref(&root),
            &mut orchestrator,
            "job-1",
            &test_config(),
        )
        .unwrap();

        assert_eq!(output.transitions.len(), 2);
        assert_eq!(output.summary.ir_count, 2);
        assert_eq!(
            orchestrator.job("job-1").unwrap().state,
            LazarusJobState::IrExtracted
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn equivalent_pair_advances_to_verified_bounded() {
        let root = fixture(
            "verified_pair",
            "pub fn legacy(x: i64) -> i64 { x }\npub fn refactored(x: i64) -> i64 { x + 0 }\n",
        );
        let mut orchestrator = LazarusOrchestrator::new();
        orchestrator.create_job("job-2", "verified_pair").unwrap();
        let config = test_config();
        let output = run_scan_extract_stage(
            std::slice::from_ref(&root),
            &mut orchestrator,
            "job-2",
            &config,
        )
        .unwrap();
        let legacy = find_ir_by_function_target(&output.extract.irs, "legacy").unwrap();
        let refactored = find_ir_by_function_target(&output.extract.irs, "refactored").unwrap();

        let verification =
            run_bounded_verification_stage(&mut orchestrator, "job-2", legacy, refactored, &config)
                .unwrap();

        assert_eq!(verification.report.verdict, EquivalenceVerdict::Equivalent);
        assert!(verification.transition.is_some());
        assert_eq!(
            orchestrator.job("job-2").unwrap().state,
            LazarusJobState::VerifiedBounded
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn counterexample_does_not_advance_state() {
        let root = fixture(
            "counterexample_pair",
            "pub fn legacy(x: i64) -> i64 { x }\npub fn refactored(x: i64) -> i64 { 0 }\n",
        );
        let mut orchestrator = LazarusOrchestrator::new();
        orchestrator
            .create_job("job-3", "counterexample_pair")
            .unwrap();
        let config = test_config();
        let output = run_scan_extract_stage(
            std::slice::from_ref(&root),
            &mut orchestrator,
            "job-3",
            &config,
        )
        .unwrap();
        let legacy = find_ir_by_function_target(&output.extract.irs, "legacy").unwrap();
        let refactored = find_ir_by_function_target(&output.extract.irs, "refactored").unwrap();

        let verification =
            run_bounded_verification_stage(&mut orchestrator, "job-3", legacy, refactored, &config)
                .unwrap();

        assert_eq!(
            verification.report.verdict,
            EquivalenceVerdict::Counterexample
        );
        assert!(verification.transition.is_none());
        assert_eq!(
            orchestrator.job("job-3").unwrap().state,
            LazarusJobState::IrExtracted
        );

        let _ = fs::remove_dir_all(root);
    }

    fn test_config() -> PipelineConfig {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        PipelineConfig::repo_default(manifest_dir.join(".."))
    }

    fn fixture(name: &str, source: &str) -> PathBuf {
        let root = std::env::temp_dir()
            .join(format!("lazarus-pipeline-fixtures-{}", std::process::id()))
            .join(name);
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(
            root.join("Cargo.toml"),
            format!("[package]\nname = \"{name}\"\nversion = \"0.1.0\"\n"),
        )
        .unwrap();
        fs::write(root.join("src/lib.rs"), source).unwrap();
        root
    }

    #[allow(dead_code)]
    fn assert_path(path: &Path) {
        assert!(path.exists(), "path missing: {}", path.display());
    }
}
