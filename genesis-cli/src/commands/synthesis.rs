use crate::commands::corpus::{derive_row_count_behavior_case, load_valid_snapshots_for_method};
use lazarus_synthesizer::{
    OpenAiOracleAdapter, SynthesisInput, SynthesisVerdict, SynthesizerConfig,
    synthesize_with_oracle,
};
use std::fs;
use std::path::PathBuf;

pub(crate) fn run_synthesis_smoke(args: &[String]) -> Result<(), String> {
    if args.len() != 4 {
        return Err(
            "usage: genesis-cli synthesis-smoke <snapshot-file-or-dir> <business-method> <java-source-file> <out-dir>"
                .to_string(),
        );
    }
    let snapshot_input = PathBuf::from(&args[0]);
    let business_method = &args[1];
    let java_source_path = PathBuf::from(&args[2]);
    let out_dir = PathBuf::from(&args[3]);
    fs::create_dir_all(&out_dir).map_err(|error| error.to_string())?;

    let snapshots = load_valid_snapshots_for_method(&snapshot_input, business_method)?;
    if snapshots.is_empty() {
        return Err(format!(
            "no valid snapshots found for business method {business_method}"
        ));
    }
    let behavior_cases = snapshots
        .iter()
        .map(derive_row_count_behavior_case)
        .collect::<Result<Vec<_>, _>>()?;
    let legacy_source = fs::read_to_string(&java_source_path).map_err(|error| {
        format!(
            "failed to read Java source {}: {error}",
            java_source_path.display()
        )
    })?;

    let input = SynthesisInput {
        legacy_source,
        input_order: vec!["id".to_string()],
        state_snapshots: snapshots,
        behavior_cases,
    };
    let mut config = SynthesizerConfig::new("compute", &out_dir);
    config.training_percent = 100;
    config.precompiled_cache_dir = Some(out_dir.join("cwasm"));
    let mut oracle = OpenAiOracleAdapter::from_env()?;
    let report = synthesize_with_oracle(&mut oracle, &input, &config)?;
    let smoke_passed = report.verdict == SynthesisVerdict::Accepted;
    let smoke_status = if smoke_passed {
        "SmokeTestPassed"
    } else {
        "SmokeTestFailed"
    };
    let verdict = format!("{:?}", report.verdict);
    let report_path = out_dir.join("synthesis-smoke-report.json");
    fs::write(
        &report_path,
        serde_json::to_vec_pretty(&serde_json::json!({
            "status": smoke_status,
            "production_ready": false,
            "business_method": business_method,
            "snapshot_count": input.state_snapshots.len(),
            "behavior_case_count": input.behavior_cases.len(),
            "synthesis": report,
        }))
        .map_err(|error| error.to_string())?,
    )
    .map_err(|error| error.to_string())?;
    println!(
        "synthesis-smoke complete: status={}, verdict={}, production_ready=false, report={}",
        smoke_status,
        verdict,
        report_path.display()
    );
    Ok(())
}
