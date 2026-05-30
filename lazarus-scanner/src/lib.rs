use lazarus_contracts::{
    CodeUnit, DependencyEdge, DependencyGraph, DependencyKind, RiskLevel, SourceLanguage,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScanResult {
    pub graph: DependencyGraph,
    pub skip_reasons: Vec<SkipReason>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkipReason {
    pub path: String,
    pub reason: String,
}

impl ScanResult {
    pub fn empty() -> Self {
        Self {
            graph: DependencyGraph::new("empty-workspace"),
            skip_reasons: Vec::new(),
        }
    }

    pub fn with_skip(mut self, path: impl Into<String>, reason: impl Into<String>) -> Self {
        self.skip_reasons.push(SkipReason {
            path: path.into(),
            reason: reason.into(),
        });
        self
    }

    pub fn validate(&self) -> Result<(), String> {
        self.graph
            .validate()
            .map_err(|error| format!("scan result validation failed: {error}"))
    }

    fn filter_invalid_edges(&mut self) {
        let unit_ids = self
            .graph
            .units
            .iter()
            .map(|unit| unit.unit_id.as_str())
            .collect::<BTreeSet<_>>();
        let mut retained = Vec::with_capacity(self.graph.edges.len());

        for edge in self.graph.edges.drain(..) {
            let from_exists = unit_ids.contains(edge.from_unit_id.as_str());
            let to_exists = unit_ids.contains(edge.to_unit_id.as_str());
            if from_exists && to_exists {
                retained.push(edge);
                continue;
            }

            self.skip_reasons.push(SkipReason {
                path: format!("edge {} -> {}", edge.from_unit_id, edge.to_unit_id),
                reason: match (from_exists, to_exists) {
                    (false, false) => "from_unit and to_unit missing".to_string(),
                    (false, true) => "from_unit missing".to_string(),
                    (true, false) => "to_unit missing".to_string(),
                    (true, true) => unreachable!(),
                },
            });
        }

        self.graph.edges = retained;
    }

    pub fn validate_and_filter(mut self) -> Self {
        self.filter_invalid_edges();
        self
    }
}

#[derive(Clone, Debug)]
pub struct ScannerConfig {
    pub prefer_cargo: bool,
    pub max_depth: u32,
    pub include_dev_dependencies: bool,
    pub include_build_dependencies: bool,
}

impl Default for ScannerConfig {
    fn default() -> Self {
        Self {
            prefer_cargo: true,
            max_depth: 10,
            include_dev_dependencies: true,
            include_build_dependencies: false,
        }
    }
}

pub fn scan_crate(root: &Path, config: &ScannerConfig) -> ScanResult {
    let crate_name = crate_name(root);
    let mut result = ScanResult {
        graph: DependencyGraph::new(crate_name.clone()),
        skip_reasons: Vec::new(),
    };

    if !root.is_dir() {
        return result.with_skip(root.to_string_lossy(), "root directory does not exist");
    }

    if config.prefer_cargo {
        if has_cargo_toml(root) {
            match parse_cargo_toml_with_deps(root, config) {
                Ok((cargo_unit, external_units, dep_names)) => {
                    let cargo_id = cargo_unit.unit_id.clone();
                    result.graph.units.push(cargo_unit);
                    for unit in external_units {
                        push_unit_once(&mut result.graph.units, unit);
                    }
                    for dep in dep_names {
                        result.graph.edges.push(DependencyEdge {
                            from_unit_id: cargo_id.clone(),
                            to_unit_id: external_unit_id(&crate_name, &dep),
                            kind: DependencyKind::Imports,
                            evidence: "Cargo.toml dependency".to_string(),
                        });
                    }
                }
                Err(error) => result.skip_reasons.push(SkipReason {
                    path: root.join("Cargo.toml").to_string_lossy().into_owned(),
                    reason: format!("failed to parse Cargo.toml: {error}"),
                }),
            }
        } else {
            result.skip_reasons.push(SkipReason {
                path: root.join("Cargo.toml").to_string_lossy().into_owned(),
                reason: "Cargo.toml missing; source-only scan".to_string(),
            });
        }
    }

    if let Err(error) = collect_source_units_into(root, config, &mut result) {
        result.skip_reasons.push(SkipReason {
            path: root.join("src").to_string_lossy().into_owned(),
            reason: format!("failed to scan src directory: {error}"),
        });
    }

    result.validate_and_filter()
}

pub fn scan_workspace(roots: &[PathBuf], config: &ScannerConfig) -> ScanResult {
    if roots.is_empty() {
        return ScanResult::empty();
    }

    let unique_roots = roots
        .iter()
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();

    let mut units = BTreeMap::<String, CodeUnit>::new();
    let mut edges = Vec::<DependencyEdge>::new();
    let mut skip_reasons = Vec::<SkipReason>::new();

    for root in &unique_roots {
        if !root.is_dir() {
            skip_reasons.push(SkipReason {
                path: root.to_string_lossy().into_owned(),
                reason: "root directory does not exist".to_string(),
            });
            continue;
        }

        let scan = scan_crate(root, config);
        for unit in scan.graph.units {
            if units.insert(unit.unit_id.clone(), unit).is_some() {
                skip_reasons.push(SkipReason {
                    path: root.to_string_lossy().into_owned(),
                    reason: "duplicate unit_id overwritten during workspace merge".to_string(),
                });
            }
        }
        edges.extend(scan.graph.edges);
        skip_reasons.extend(scan.skip_reasons);
    }

    let mut result = ScanResult {
        graph: DependencyGraph {
            contract_version: lazarus_contracts::LAZARUS_CONTRACT_VERSION,
            codebase_id: if unique_roots.len() == 1 {
                crate_name(&unique_roots[0])
            } else {
                format!("workspace-merged-{}", unique_roots.len())
            },
            units: units.into_values().collect(),
            edges,
        },
        skip_reasons,
    };
    result = result.validate_and_filter();
    result
}

pub fn validate_scan_result(result: &ScanResult) -> Result<(), String> {
    result.validate()
}

fn has_cargo_toml(root: &Path) -> bool {
    root.join("Cargo.toml").is_file()
}

fn collect_source_units_into(
    root: &Path,
    config: &ScannerConfig,
    result: &mut ScanResult,
) -> Result<(), String> {
    let src_dir = root.join("src");
    if !src_dir.is_dir() {
        result.skip_reasons.push(SkipReason {
            path: src_dir.to_string_lossy().into_owned(),
            reason: "source directory does not exist".to_string(),
        });
        return Ok(());
    }

    let pattern = format!("{}/**/*.rs", src_dir.display());
    for entry in glob::glob(&pattern).map_err(|error| format!("glob error: {error}"))? {
        let path = match entry {
            Ok(path) => path,
            Err(error) => {
                result.skip_reasons.push(SkipReason {
                    path: root.to_string_lossy().into_owned(),
                    reason: error.to_string(),
                });
                continue;
            }
        };
        if !path.is_file() || exceeds_max_depth(&src_dir, &path, config.max_depth) {
            continue;
        }
        let relative = path
            .strip_prefix(root)
            .map_err(|error| format!("strip_prefix failed: {error}"))?;
        push_unit_once(
            &mut result.graph.units,
            CodeUnit {
                unit_id: source_unit_id(&crate_name(root), relative),
                language: SourceLanguage::Rust,
                path: path.to_string_lossy().into_owned(),
                content_hash: compute_content_hash(&path)?,
                entrypoints: Vec::new(),
                risk_level: RiskLevel::Low,
            },
        );
    }

    Ok(())
}

fn parse_cargo_toml_with_deps(
    root: &Path,
    config: &ScannerConfig,
) -> Result<(CodeUnit, Vec<CodeUnit>, Vec<String>), String> {
    let path = root.join("Cargo.toml");
    let content = fs::read_to_string(&path).map_err(|error| error.to_string())?;
    let value = content
        .parse::<toml::Value>()
        .map_err(|error| format!("toml parse error: {error}"))?;
    let crate_name = crate_name(root);

    let mut dep_names = BTreeSet::<String>::new();
    collect_dependency_keys(&value, "dependencies", &mut dep_names);
    if config.include_dev_dependencies {
        collect_dependency_keys(&value, "dev-dependencies", &mut dep_names);
    }
    if config.include_build_dependencies {
        collect_dependency_keys(&value, "build-dependencies", &mut dep_names);
    }

    let external_units = dep_names
        .iter()
        .map(|dep| CodeUnit {
            unit_id: external_unit_id(&crate_name, dep),
            language: SourceLanguage::Unknown,
            path: format!("cargo://{dep}"),
            content_hash: compute_external_dep_hash(dep),
            entrypoints: Vec::new(),
            risk_level: RiskLevel::Low,
        })
        .collect::<Vec<_>>();

    Ok((
        CodeUnit {
            unit_id: cargo_unit_id(&crate_name),
            language: SourceLanguage::Unknown,
            path: path.to_string_lossy().into_owned(),
            content_hash: compute_content_hash(&path)?,
            entrypoints: Vec::new(),
            risk_level: RiskLevel::Low,
        },
        external_units,
        dep_names.into_iter().collect(),
    ))
}

fn collect_dependency_keys(
    value: &toml::Value,
    table_name: &str,
    dep_names: &mut BTreeSet<String>,
) {
    if let Some(table) = value.get(table_name).and_then(toml::Value::as_table) {
        dep_names.extend(table.keys().map(|key| sanitize_segment(key)));
    }
}

fn push_unit_once(units: &mut Vec<CodeUnit>, unit: CodeUnit) {
    if !units
        .iter()
        .any(|existing| existing.unit_id == unit.unit_id)
    {
        units.push(unit);
    }
}

fn cargo_unit_id(crate_name: &str) -> String {
    format!("{crate_name}/Cargo.toml")
}

fn external_unit_id(crate_name: &str, dep: &str) -> String {
    format!("{crate_name}/external/{}", sanitize_segment(dep))
}

fn source_unit_id(crate_name: &str, relative_path: &Path) -> String {
    let relative = relative_path
        .components()
        .map(|component| sanitize_segment(&component.as_os_str().to_string_lossy()))
        .collect::<Vec<_>>()
        .join("/");
    format!("{crate_name}/{relative}")
}

fn crate_name(root: &Path) -> String {
    root.file_name()
        .map(|name| sanitize_segment(&name.to_string_lossy()))
        .unwrap_or_else(|| "unknown".to_string())
}

fn sanitize_segment(value: &str) -> String {
    let sanitized = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.' | ':') {
                ch
            } else {
                '_'
            }
        })
        .collect::<String>();
    if sanitized.is_empty() {
        "unknown".to_string()
    } else {
        sanitized
    }
}

fn compute_content_hash(path: &Path) -> Result<String, String> {
    let bytes = fs::read(path).map_err(|error| error.to_string())?;
    Ok(hex_sha256(&bytes))
}

fn compute_external_dep_hash(dep: &str) -> String {
    hex_sha256(format!("external:{dep}").as_bytes())
}

fn hex_sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn exceeds_max_depth(src_dir: &Path, path: &Path, max_depth: u32) -> bool {
    if max_depth == 0 {
        return false;
    }
    let Ok(relative) = path.strip_prefix(src_dir) else {
        return true;
    };
    relative.components().count() > max_depth as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_roots_return_valid_empty_graph() {
        let result = scan_workspace(&[], &ScannerConfig::default());
        assert!(result.skip_reasons.is_empty());
        assert!(result.graph.units.is_empty());
        assert!(result.graph.edges.is_empty());
        assert!(result.validate().is_ok());
    }

    #[test]
    fn missing_root_is_skip_not_error() {
        let root = std::env::temp_dir().join(format!("lazarus-missing-{}", std::process::id()));
        let result = scan_workspace(&[root], &ScannerConfig::default());
        assert_eq!(result.skip_reasons.len(), 1);
        assert!(result.validate().is_ok());
    }

    #[test]
    fn cargo_dependencies_create_external_units_and_closed_edges() {
        let root = fixture_root("cargo-deps");
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(
            root.join("Cargo.toml"),
            "[package]\nname = \"fixture\"\nversion = \"0.1.0\"\n\n[dependencies]\nserde = \"1\"\ntokio = { version = \"1\" }\n",
        )
        .unwrap();
        fs::write(root.join("src/lib.rs"), "pub fn fixture() {}\n").unwrap();

        let result = scan_crate(&root, &ScannerConfig::default());
        assert!(result.validate().is_ok(), "{:?}", result.skip_reasons);
        assert!(has_unit(&result, "cargo-deps/Cargo.toml"));
        assert!(has_unit(&result, "cargo-deps/external/serde"));
        assert!(has_unit(&result, "cargo-deps/external/tokio"));
        assert!(has_edge(
            &result,
            "cargo-deps/Cargo.toml",
            "cargo-deps/external/serde"
        ));
        assert!(result.graph.units.iter().all(|unit| {
            unit.content_hash.len() == 64
                && unit
                    .content_hash
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
        }));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn missing_cargo_falls_back_to_source_units() {
        let root = fixture_root("source-only");
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();

        let result = scan_crate(&root, &ScannerConfig::default());
        assert!(result.validate().is_ok());
        assert!(has_unit(&result, "source-only/src/main.rs"));
        assert!(
            result
                .skip_reasons
                .iter()
                .any(|skip| skip.reason.contains("Cargo.toml missing"))
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn duplicate_roots_are_deduped() {
        let root = fixture_root("dedupe");
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(root.join("src/lib.rs"), "pub fn fixture() {}\n").unwrap();

        let result = scan_workspace(&[root.clone(), root.clone()], &ScannerConfig::default());
        assert!(result.validate().is_ok());
        assert_eq!(
            result
                .graph
                .units
                .iter()
                .filter(|unit| unit.unit_id == "dedupe/src/lib.rs")
                .count(),
            1
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn max_depth_filters_deep_source_files() {
        let root = fixture_root("depth");
        fs::create_dir_all(root.join("src/a/b")).unwrap();
        fs::write(root.join("src/lib.rs"), "pub fn root() {}\n").unwrap();
        fs::write(root.join("src/a/b/deep.rs"), "pub fn deep() {}\n").unwrap();

        let result = scan_crate(
            &root,
            &ScannerConfig {
                max_depth: 1,
                ..ScannerConfig::default()
            },
        );
        assert!(has_unit(&result, "depth/src/lib.rs"));
        assert!(!has_unit(&result, "depth/src/a/b/deep.rs"));

        let _ = fs::remove_dir_all(root);
    }

    fn fixture_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir()
            .join(format!("lazarus-scanner-fixtures-{}", std::process::id()))
            .join(name);
        let _ = fs::remove_dir_all(&root);
        root
    }

    fn has_unit(result: &ScanResult, unit_id: &str) -> bool {
        result
            .graph
            .units
            .iter()
            .any(|unit| unit.unit_id == unit_id)
    }

    fn has_edge(result: &ScanResult, from: &str, to: &str) -> bool {
        result
            .graph
            .edges
            .iter()
            .any(|edge| edge.from_unit_id == from && edge.to_unit_id == to)
    }
}
