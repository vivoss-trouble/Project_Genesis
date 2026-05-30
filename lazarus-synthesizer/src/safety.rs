use crate::types::{MaintainabilityReport, SourcePolicyReport};

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
