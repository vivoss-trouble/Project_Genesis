use crate::types::{BehaviorCase, MaintainabilityReport, SourcePolicyReport, SynthesisInput};
use serde_json::Value;

pub const DEFAULT_MAX_SOURCE_BYTES: usize = 64 * 1024;
pub const DEFAULT_MAX_SOURCE_LINES: usize = 240;
pub const DEFAULT_MAX_BRANCH_TOKENS: usize = 64;

pub fn validate_source_policy(source: &str) -> SourcePolicyReport {
    let forbidden = [
        "std::fs",
        "std::net",
        "std::process",
        "std::os",
        "std::ffi",
        "std::alloc",
        "Command::",
        "include_str!",
        "include_bytes!",
        "extern crate",
        "serde",
        "serde_json",
        "from_raw_parts",
        "Vec::from_raw_parts",
        "unsafe {",
        "unsafe fn",
    ];
    let mut violations = forbidden
        .iter()
        .filter(|token| source.contains(**token))
        .map(|token| format!("forbidden token: {token}"))
        .collect::<Vec<_>>();
    let maintainability = analyze_maintainability(source);
    violations.extend(
        maintainability
            .violations
            .iter()
            .map(|violation| format!("maintainability: {violation}")),
    );
    SourcePolicyReport {
        accepted: violations.is_empty(),
        violations,
        maintainability,
    }
}

pub fn validate_source_policy_for_input(
    source: &str,
    input: &SynthesisInput,
) -> SourcePolicyReport {
    let mut report = validate_source_policy(source);
    report.violations.extend(
        detect_literal_replay(source, &input.behavior_cases)
            .into_iter()
            .map(|violation| format!("overfitting: {violation}")),
    );
    report.accepted = report.violations.is_empty();
    report
}

pub fn analyze_maintainability(source: &str) -> MaintainabilityReport {
    let source_bytes = source.len();
    let source_lines = source.lines().count();
    let branch_tokens = count_branch_tokens(source);
    let mut violations = Vec::new();
    if source_bytes > DEFAULT_MAX_SOURCE_BYTES {
        violations.push(format!(
            "source_bytes {} exceeds {}",
            source_bytes, DEFAULT_MAX_SOURCE_BYTES
        ));
    }
    if source_lines > DEFAULT_MAX_SOURCE_LINES {
        violations.push(format!(
            "source_lines {} exceeds {}",
            source_lines, DEFAULT_MAX_SOURCE_LINES
        ));
    }
    if branch_tokens > DEFAULT_MAX_BRANCH_TOKENS {
        violations.push(format!(
            "branch_tokens {} exceeds {}",
            branch_tokens, DEFAULT_MAX_BRANCH_TOKENS
        ));
    }
    MaintainabilityReport {
        accepted: violations.is_empty(),
        source_bytes,
        source_lines,
        branch_tokens,
        max_source_bytes: DEFAULT_MAX_SOURCE_BYTES,
        max_source_lines: DEFAULT_MAX_SOURCE_LINES,
        max_branch_tokens: DEFAULT_MAX_BRANCH_TOKENS,
        violations,
    }
}

fn count_branch_tokens(source: &str) -> usize {
    source
        .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
        .filter(|token| matches!(*token, "if" | "else" | "match" | "for" | "while" | "loop"))
        .count()
}

fn detect_literal_replay(source: &str, behavior_cases: &[BehaviorCase]) -> Vec<String> {
    let mut violations = Vec::new();
    let mut expected_literals = Vec::new();
    for case in behavior_cases {
        collect_expected_literals(&case.expected, &mut expected_literals);
    }

    for literal in expected_literals {
        match literal {
            ExpectedLiteral::String(value) => {
                if value.len() >= 3 && contains_string_literal(source, &value) {
                    violations.push(format!(
                        "candidate embeds expected string literal '{}'",
                        preview_literal(&value)
                    ));
                }
            }
            ExpectedLiteral::Number(value) => {
                if behavior_cases.len() < 3 && contains_returned_number_literal(source, &value) {
                    violations.push(format!(
                        "candidate embeds expected numeric result literal {value} with fewer than 3 behavior cases"
                    ));
                }
            }
            ExpectedLiteral::Bool(value) => {
                if behavior_cases.len() < 3 && contains_returned_bool_literal(source, value) {
                    violations.push(format!(
                        "candidate embeds expected boolean result literal {value} with fewer than 3 behavior cases"
                    ));
                }
            }
        }
    }

    violations.sort();
    violations.dedup();
    violations
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum ExpectedLiteral {
    String(String),
    Number(String),
    Bool(bool),
}

fn collect_expected_literals(value: &Value, out: &mut Vec<ExpectedLiteral>) {
    match value {
        Value::String(value) => out.push(ExpectedLiteral::String(value.clone())),
        Value::Number(value) => out.push(ExpectedLiteral::Number(value.to_string())),
        Value::Bool(value) => out.push(ExpectedLiteral::Bool(*value)),
        Value::Array(values) => {
            for value in values {
                collect_expected_literals(value, out);
            }
        }
        Value::Object(map) => {
            for value in map.values() {
                collect_expected_literals(value, out);
            }
        }
        Value::Null => {}
    }
}

fn contains_string_literal(source: &str, value: &str) -> bool {
    let Ok(quoted) = serde_json::to_string(value) else {
        return false;
    };
    source.contains(&quoted)
        || source.contains(&format!("r#\"{value}\"#"))
        || source.contains(&format!("r##\"{value}\"##"))
}

fn contains_returned_number_literal(source: &str, value: &str) -> bool {
    contains_returned_literal_patterns(source, value)
}

fn contains_returned_bool_literal(source: &str, value: bool) -> bool {
    contains_returned_literal_patterns(source, if value { "true" } else { "false" })
}

fn contains_returned_literal_patterns(source: &str, value: &str) -> bool {
    [
        format!("return {value}"),
        format!("{{ {value} }}"),
        format!("=> {value}"),
        format!("= {value};"),
        format!("Ok({value})"),
    ]
    .iter()
    .any(|pattern| source.contains(pattern))
}

fn preview_literal(value: &str) -> String {
    const MAX_PREVIEW: usize = 48;
    if value.len() <= MAX_PREVIEW {
        value.to_string()
    } else {
        format!("{}...", &value[..MAX_PREVIEW])
    }
}
