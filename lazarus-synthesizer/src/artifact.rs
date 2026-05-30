use crate::types::SynthesizerConfig;
use lazarus_artifact_runner::WasmArtifact;
use std::fs;
use std::process::Command;

pub(crate) fn compile_candidate_source(
    source: &str,
    source_hash: &str,
    input_order: &[String],
    config: &SynthesizerConfig,
) -> Result<WasmArtifact, String> {
    let source_path = config
        .out_dir
        .join(format!("{}_{}.rs", config.function_name, source_hash));
    let wasm_path = config
        .out_dir
        .join(format!("{}_{}.wasm", config.function_name, source_hash));
    fs::write(&source_path, source).map_err(|error| error.to_string())?;
    let output = Command::new(&config.rustc_bin)
        .arg("--target=wasm32-wasip1")
        .arg("--crate-type=cdylib")
        .arg("--edition=2024")
        .arg(&source_path)
        .arg("-o")
        .arg(&wasm_path)
        .output()
        .map_err(|error| format!("failed to spawn rustc for synthesized wasm: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "rustc synthesized wasm build failed with status {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(WasmArtifact {
        source_path,
        wasm_path,
        source_hash: source_hash.to_string(),
        input_order: input_order.to_vec(),
        function_name: config.function_name.clone(),
    })
}
