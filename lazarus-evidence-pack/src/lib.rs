use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use lazarus_contracts::{LazarusJob, LazarusJobState};
use lazarus_converter_pipeline::CompileReceipt;
use lazarus_cutover_gate::CutoverGateReport;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

pub const LAZARUS_SIGNER_KEY_ID_ENV: &str = "LAZARUS_SIGNER_KEY_ID";
pub const LAZARUS_ED25519_PRIVATE_KEY_HEX_ENV: &str = "LAZARUS_ED25519_PRIVATE_KEY_HEX";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EvidencePackInput {
    pub job: LazarusJob,
    pub compile_receipt: CompileReceipt,
    pub cutover_report: CutoverGateReport,
    pub shadow_ledger_path: PathBuf,
    pub runbook_path: PathBuf,
    pub output_dir: PathBuf,
    pub signer: EvidenceSigner,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvidencePackManifest {
    pub contract_version: u32,
    pub job_id: String,
    pub codebase_id: String,
    pub final_state: LazarusJobState,
    pub job_evidence: BTreeMap<String, String>,
    pub cutover_accepted: bool,
    pub file_hashes: BTreeMap<String, String>,
    pub manifest_hash: String,
    pub signature: EvidenceSignature,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvidenceSignature {
    pub algorithm: String,
    pub key_id: String,
    pub public_key_hex: String,
    pub signature_hex: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvidenceBatchSignature {
    pub root_hash: String,
    pub signature: EvidenceSignature,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EvidenceSigner {
    pub key_id: String,
    pub private_key_hex: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EvidencePackOutput {
    pub manifest_path: PathBuf,
    pub manifest: EvidencePackManifest,
}

pub trait EvidenceSignatureProvider {
    fn sign_evidence(&self, bytes: &[u8]) -> Result<EvidenceSignature, String>;
}

pub fn sign_evidence_hash_batch<P: EvidenceSignatureProvider>(
    signer: &P,
    evidence_hashes: &[String],
) -> Result<EvidenceBatchSignature, String> {
    let root_hash = evidence_batch_root_hash(evidence_hashes)?;
    let signature = signer.sign_evidence(root_hash.as_bytes())?;
    Ok(EvidenceBatchSignature {
        root_hash,
        signature,
    })
}

pub fn evidence_batch_root_hash(evidence_hashes: &[String]) -> Result<String, String> {
    if evidence_hashes.is_empty() {
        return Err("evidence batch must contain at least one hash".to_string());
    }
    let mut hashes = evidence_hashes.to_vec();
    hashes.sort();
    for hash in &hashes {
        if hash.len() != 64 {
            return Err(format!("evidence hash must be 64 hex chars: {hash}"));
        }
        hex_decode(hash)?;
    }
    let canonical = serde_json::to_vec(&hashes).map_err(|error| error.to_string())?;
    Ok(hex_sha256(&canonical))
}

pub fn write_evidence_pack(input: &EvidencePackInput) -> Result<EvidencePackOutput, String> {
    validate_input(input)?;
    fs::create_dir_all(&input.output_dir).map_err(|error| error.to_string())?;
    let mut file_hashes = BTreeMap::new();
    insert_file_hash(
        &mut file_hashes,
        "generated_source",
        &input.compile_receipt.artifact_path,
    )?;
    insert_file_hash(
        &mut file_hashes,
        "compiled_artifact",
        &input.compile_receipt.output_path,
    )?;
    insert_file_hash(&mut file_hashes, "shadow_ledger", &input.shadow_ledger_path)?;
    insert_file_hash(&mut file_hashes, "runbook", &input.runbook_path)?;

    let unsigned = EvidencePackUnsignedManifest {
        contract_version: input.job.contract_version,
        job_id: input.job.job_id.as_str(),
        codebase_id: input.job.codebase_id.as_str(),
        final_state: input.job.state,
        job_evidence: &input.job.evidence,
        cutover_accepted: input.cutover_report.accepted,
        file_hashes: &file_hashes,
    };
    let unsigned_bytes = serde_json::to_vec(&unsigned).map_err(|error| error.to_string())?;
    let manifest_hash = hex_sha256(&unsigned_bytes);
    let signature = input.signer.sign_evidence(&unsigned_bytes)?;
    let manifest = EvidencePackManifest {
        contract_version: input.job.contract_version,
        job_id: input.job.job_id.clone(),
        codebase_id: input.job.codebase_id.clone(),
        final_state: input.job.state,
        job_evidence: input.job.evidence.clone(),
        cutover_accepted: input.cutover_report.accepted,
        file_hashes,
        manifest_hash,
        signature,
    };

    let manifest_path = input.output_dir.join("lazarus-evidence-manifest.json");
    let manifest_json = serde_json::to_vec_pretty(&manifest).map_err(|error| error.to_string())?;
    fs::write(&manifest_path, manifest_json).map_err(|error| error.to_string())?;

    Ok(EvidencePackOutput {
        manifest_path,
        manifest,
    })
}

impl EvidenceSigner {
    pub fn new(
        key_id: impl Into<String>,
        private_key_hex: impl Into<String>,
    ) -> Result<Self, String> {
        let signer = Self {
            key_id: key_id.into(),
            private_key_hex: private_key_hex.into(),
        };
        signer.signing_key()?;
        Ok(signer)
    }

    pub fn deterministic_test_signer() -> Self {
        Self {
            key_id: "local-test-key".to_string(),
            private_key_hex: hex_encode(&[7_u8; 32]),
        }
    }

    pub fn from_env() -> Result<Self, String> {
        let private_key_hex = env::var(LAZARUS_ED25519_PRIVATE_KEY_HEX_ENV).map_err(|_| {
            format!("missing environment variable {LAZARUS_ED25519_PRIVATE_KEY_HEX_ENV}")
        })?;
        let key_id =
            env::var(LAZARUS_SIGNER_KEY_ID_ENV).unwrap_or_else(|_| "env-ed25519-key".to_string());
        Self::new(key_id, private_key_hex)
    }

    pub fn from_env_or_deterministic_test_signer() -> Self {
        Self::from_env().unwrap_or_else(|_| Self::deterministic_test_signer())
    }

    fn sign(&self, bytes: &[u8]) -> Result<EvidenceSignature, String> {
        let signing_key = self.signing_key()?;
        let verifying_key = signing_key.verifying_key();
        let signature = signing_key.sign(bytes);
        Ok(EvidenceSignature {
            algorithm: "ed25519".to_string(),
            key_id: self.key_id.clone(),
            public_key_hex: hex_encode(verifying_key.as_bytes()),
            signature_hex: hex_encode(&signature.to_bytes()),
        })
    }

    fn signing_key(&self) -> Result<SigningKey, String> {
        let bytes = hex_decode(&self.private_key_hex)?;
        let array: [u8; 32] = bytes
            .try_into()
            .map_err(|_| "ed25519 private key must be 32 bytes".to_string())?;
        Ok(SigningKey::from_bytes(&array))
    }
}

impl EvidenceSignatureProvider for EvidenceSigner {
    fn sign_evidence(&self, bytes: &[u8]) -> Result<EvidenceSignature, String> {
        self.sign(bytes)
    }
}

pub fn verify_manifest_signature(manifest: &EvidencePackManifest) -> Result<(), String> {
    if manifest.signature.algorithm != "ed25519" {
        return Err(format!(
            "unsupported evidence signature algorithm: {}",
            manifest.signature.algorithm
        ));
    }
    let unsigned = EvidencePackUnsignedManifest {
        contract_version: manifest.contract_version,
        job_id: &manifest.job_id,
        codebase_id: &manifest.codebase_id,
        final_state: manifest.final_state,
        job_evidence: &manifest.job_evidence,
        cutover_accepted: manifest.cutover_accepted,
        file_hashes: &manifest.file_hashes,
    };
    let unsigned_bytes = serde_json::to_vec(&unsigned).map_err(|error| error.to_string())?;
    let actual_hash = hex_sha256(&unsigned_bytes);
    if manifest.manifest_hash != actual_hash {
        return Err(format!(
            "manifest hash mismatch: expected {}, actual {actual_hash}",
            manifest.manifest_hash
        ));
    }
    verify_signature_bytes(&manifest.signature, &unsigned_bytes)
}

pub fn verify_batch_signature(batch: &EvidenceBatchSignature) -> Result<(), String> {
    if batch.root_hash.len() != 64 {
        return Err("batch root_hash must be 64 hex chars".to_string());
    }
    hex_decode(&batch.root_hash)?;
    verify_signature_bytes(&batch.signature, batch.root_hash.as_bytes())
}

#[derive(Serialize)]
struct EvidencePackUnsignedManifest<'a> {
    contract_version: u32,
    job_id: &'a str,
    codebase_id: &'a str,
    final_state: LazarusJobState,
    job_evidence: &'a BTreeMap<String, String>,
    cutover_accepted: bool,
    file_hashes: &'a BTreeMap<String, String>,
}

fn validate_input(input: &EvidencePackInput) -> Result<(), String> {
    input.job.validate()?;
    if input.job.state != LazarusJobState::CutoverReady {
        return Err(format!(
            "evidence pack requires CutoverReady job, got {:?}",
            input.job.state
        ));
    }
    if !input.cutover_report.accepted {
        return Err("evidence pack requires accepted cutover report".to_string());
    }
    let expected_artifact_hash = input
        .job
        .evidence
        .get("artifact_hash")
        .ok_or_else(|| "missing artifact_hash evidence".to_string())?;
    if expected_artifact_hash != &input.compile_receipt.artifact_hash {
        return Err(format!(
            "artifact hash mismatch: job={expected_artifact_hash}, receipt={}",
            input.compile_receipt.artifact_hash
        ));
    }
    let expected_runbook_hash = input
        .job
        .evidence
        .get("runbook_hash")
        .ok_or_else(|| "missing runbook_hash evidence".to_string())?;
    if input.cutover_report.runbook_hash.as_ref() != Some(expected_runbook_hash) {
        return Err("runbook hash evidence does not match cutover report".to_string());
    }
    Ok(())
}

fn insert_file_hash(
    file_hashes: &mut BTreeMap<String, String>,
    label: &str,
    path: &Path,
) -> Result<(), String> {
    let bytes =
        fs::read(path).map_err(|error| format!("failed to read {}: {error}", path.display()))?;
    file_hashes.insert(label.to_string(), hex_sha256(&bytes));
    Ok(())
}

fn hex_sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn hex_decode(value: &str) -> Result<Vec<u8>, String> {
    if !value.len().is_multiple_of(2) {
        return Err("hex string length must be even".to_string());
    }
    (0..value.len())
        .step_by(2)
        .map(|index| {
            u8::from_str_radix(&value[index..index + 2], 16)
                .map_err(|error| format!("invalid hex at byte {}: {error}", index / 2))
        })
        .collect()
}

fn verify_signature_bytes(signature: &EvidenceSignature, bytes: &[u8]) -> Result<(), String> {
    if signature.algorithm != "ed25519" {
        return Err(format!(
            "unsupported evidence signature algorithm: {}",
            signature.algorithm
        ));
    }
    let public_key_bytes = hex_decode(&signature.public_key_hex)?;
    let public_key_array: [u8; 32] = public_key_bytes
        .try_into()
        .map_err(|_| "ed25519 public key must be 32 bytes".to_string())?;
    let verifying_key =
        VerifyingKey::from_bytes(&public_key_array).map_err(|error| error.to_string())?;
    let signature_bytes = hex_decode(&signature.signature_hex)?;
    let signature_array: [u8; 64] = signature_bytes
        .try_into()
        .map_err(|_| "ed25519 signature must be 64 bytes".to_string())?;
    let signature = Signature::from_bytes(&signature_array);
    verifying_key
        .verify(bytes, &signature)
        .map_err(|error| format!("evidence signature verification failed: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::{LazarusJob, LazarusJobState};
    use lazarus_converter_pipeline::CompileReceipt;
    use lazarus_cutover_gate::{CutoverGateReport, ShadowLedgerSummaryDto};

    #[test]
    fn writes_manifest_for_cutover_ready_job() {
        let root = test_dir("manifest");
        let source_path = root.join("generated.rs");
        let output_path = root.join("libgenerated.rlib");
        let ledger_path = root.join("shadow.jsonl");
        let runbook_path = root.join("runbook.md");
        fs::write(&source_path, "pub fn f() -> i64 { 1 }\n").unwrap();
        fs::write(&output_path, "compiled").unwrap();
        fs::write(&ledger_path, "{\"verdict\":\"MATCH\"}\n").unwrap();
        fs::write(&runbook_path, "rollback: restore\ncutover: switch\n").unwrap();
        let source_hash = hex_sha256(&fs::read(&source_path).unwrap());
        let runbook_hash = hex_sha256(&fs::read(&runbook_path).unwrap());
        let mut job = LazarusJob::new("job-1", "bank-core");
        job.state = LazarusJobState::CutoverReady;
        job.evidence
            .insert("artifact_hash".to_string(), source_hash.clone());
        job.evidence
            .insert("runbook_hash".to_string(), runbook_hash.clone());
        let output = write_evidence_pack(&EvidencePackInput {
            job,
            compile_receipt: CompileReceipt {
                artifact_path: source_path,
                output_path,
                artifact_hash: source_hash,
            },
            cutover_report: CutoverGateReport {
                accepted: true,
                reasons: Vec::new(),
                runbook_hash: Some(runbook_hash),
                artifact_hash: None,
                shadow_summary: Some(ShadowLedgerSummaryDto {
                    total: 1,
                    matches: 1,
                    mismatches: 0,
                    errors: 0,
                }),
                transition: None,
            },
            shadow_ledger_path: ledger_path,
            runbook_path,
            output_dir: root.join("pack"),
            signer: EvidenceSigner::deterministic_test_signer(),
        })
        .unwrap();

        assert!(output.manifest_path.is_file());
        assert_eq!(output.manifest.final_state, LazarusJobState::CutoverReady);
        assert!(output.manifest.file_hashes.contains_key("runbook"));
        assert_eq!(output.manifest.manifest_hash.len(), 64);
        assert_eq!(output.manifest.signature.algorithm, "ed25519");
        verify_manifest_signature(&output.manifest).unwrap();
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn detects_tampered_signed_manifest() {
        let root = test_dir("tamper");
        let source_path = root.join("generated.rs");
        let output_path = root.join("libgenerated.rlib");
        let ledger_path = root.join("shadow.jsonl");
        let runbook_path = root.join("runbook.md");
        fs::write(&source_path, "pub fn f() -> i64 { 1 }\n").unwrap();
        fs::write(&output_path, "compiled").unwrap();
        fs::write(&ledger_path, "{\"verdict\":\"MATCH\"}\n").unwrap();
        fs::write(&runbook_path, "rollback: restore\ncutover: switch\n").unwrap();
        let source_hash = hex_sha256(&fs::read(&source_path).unwrap());
        let runbook_hash = hex_sha256(&fs::read(&runbook_path).unwrap());
        let mut job = LazarusJob::new("job-1", "bank-core");
        job.state = LazarusJobState::CutoverReady;
        job.evidence
            .insert("artifact_hash".to_string(), source_hash.clone());
        job.evidence
            .insert("runbook_hash".to_string(), runbook_hash.clone());
        let mut output = write_evidence_pack(&EvidencePackInput {
            job,
            compile_receipt: CompileReceipt {
                artifact_path: source_path,
                output_path,
                artifact_hash: source_hash,
            },
            cutover_report: CutoverGateReport {
                accepted: true,
                reasons: Vec::new(),
                runbook_hash: Some(runbook_hash),
                artifact_hash: None,
                shadow_summary: None,
                transition: None,
            },
            shadow_ledger_path: ledger_path,
            runbook_path,
            output_dir: root.join("pack"),
            signer: EvidenceSigner::deterministic_test_signer(),
        })
        .unwrap();

        output.manifest.codebase_id = "tampered".to_string();

        assert!(verify_manifest_signature(&output.manifest).is_err());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn signs_batch_root_hash_once() {
        let signer = EvidenceSigner::deterministic_test_signer();
        let hashes = vec!["1".repeat(64), "2".repeat(64), "3".repeat(64)];

        let batch = sign_evidence_hash_batch(&signer, &hashes).unwrap();

        assert_eq!(batch.root_hash.len(), 64);
        assert_eq!(batch.signature.algorithm, "ed25519");
        verify_batch_signature(&batch).unwrap();
        assert_eq!(
            batch.root_hash,
            evidence_batch_root_hash(&hashes.into_iter().rev().collect::<Vec<_>>()).unwrap()
        );
    }

    fn test_dir(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "lazarus-evidence-pack-{label}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }
}
