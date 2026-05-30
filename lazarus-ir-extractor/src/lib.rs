//! Bounded Rust expression extractor for Project Lazarus.
//!
//! This crate extracts only small, pure arithmetic functions into `DecisionIr`.
//! Unsupported code is skipped with evidence; it is never converted into a fake
//! IR just to keep the pipeline moving.

use lazarus_contracts::{DecisionExpr, DecisionIr, SideEffect, SideEffectKind, SourceLanguage};
use lazarus_scanner::ScanResult;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use syn::{
    BinOp, Block, Expr, ExprBinary, ExprCall, ExprLit, ExprMethodCall, ExprPath, ExprReturn,
    ExprUnary, FnArg, Item, ItemFn, Lit, Pat, ReturnType, Stmt, UnOp,
};

#[derive(Clone, Debug)]
pub struct ExtractorConfig {
    pub default_domain_min: i64,
    pub default_domain_max: i64,
    pub max_cases: u128,
}

impl Default for ExtractorConfig {
    fn default() -> Self {
        Self {
            default_domain_min: 0,
            default_domain_max: 100,
            max_cases: 100_000,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IrSkipReason {
    pub path: String,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtractResult {
    pub irs: Vec<DecisionIr>,
    pub skip_reasons: Vec<IrSkipReason>,
}

pub fn extract_ir_from_scan(scan_result: &ScanResult, config: &ExtractorConfig) -> ExtractResult {
    let source_units = scan_result
        .graph
        .units
        .iter()
        .map(|unit| unit.unit_id.as_str())
        .collect::<BTreeSet<_>>();
    let mut irs = Vec::new();
    let mut skip_reasons = Vec::new();

    for unit in &scan_result.graph.units {
        if unit.language != SourceLanguage::Rust {
            continue;
        }
        if !source_units.contains(unit.unit_id.as_str()) {
            skip_reasons.push(IrSkipReason {
                path: unit.path.clone(),
                reason: format!("source unit missing from graph: {}", unit.unit_id),
            });
            continue;
        }

        let content = match fs::read_to_string(&unit.path) {
            Ok(content) => content,
            Err(error) => {
                skip_reasons.push(IrSkipReason {
                    path: unit.path.clone(),
                    reason: format!("failed to read file: {error}"),
                });
                continue;
            }
        };
        let parsed = match syn::parse_file(&content) {
            Ok(parsed) => parsed,
            Err(error) => {
                skip_reasons.push(IrSkipReason {
                    path: unit.path.clone(),
                    reason: format!("failed to parse Rust file: {error}"),
                });
                continue;
            }
        };

        for item in parsed.items {
            let Item::Fn(function) = item else {
                continue;
            };
            match extract_function(&function, &unit.unit_id, &content, config) {
                Ok(ir) => irs.push(ir),
                Err(reason) => skip_reasons.push(IrSkipReason {
                    path: unit.path.clone(),
                    reason: format!("{}: {reason}", function.sig.ident),
                }),
            }
        }
    }

    ExtractResult { irs, skip_reasons }
}

pub fn verify_all_bounded(result: &ExtractResult) -> Result<(), String> {
    let errors = result
        .irs
        .iter()
        .filter_map(|ir| {
            ir.validate_bounded()
                .err()
                .map(|error| format!("ir_id={}: {error}", ir.ir_id))
        })
        .collect::<Vec<_>>();
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
    }
}

fn extract_function(
    function: &ItemFn,
    source_unit_id: &str,
    content: &str,
    config: &ExtractorConfig,
) -> Result<DecisionIr, String> {
    require_i64_return(function)?;
    reject_impure_or_complex_body(function)?;

    let params = collect_i64_params(function)?;
    let return_expr = extract_return_expr(&function.block)?;
    let expression = parse_decision_expr(return_expr, &params)?;
    let input_domains = build_input_domains(&params, config)?;
    let ir = DecisionIr {
        ir_id: hash_ir(content, &function.sig.ident.to_string(), &params),
        source_unit_id: source_unit_id.to_string(),
        input_domains,
        expression,
        side_effects: vec![SideEffect {
            kind: SideEffectKind::ReadOnly,
            target: function.sig.ident.to_string(),
            evidence: "pure bounded arithmetic expression".to_string(),
        }],
        invariants: vec!["extractor:v1:pure_arithmetic".to_string()],
    };
    ir.validate_bounded()
        .map_err(|error| format!("validate_bounded failed: {error}"))?;
    if case_space(&ir.input_domains) > config.max_cases {
        return Err(format!(
            "case space {} exceeds configured max_cases {}",
            case_space(&ir.input_domains),
            config.max_cases
        ));
    }
    Ok(ir)
}

fn require_i64_return(function: &ItemFn) -> Result<(), String> {
    match &function.sig.output {
        ReturnType::Type(_, ty) if type_last_segment(ty) == Some("i64".to_string()) => Ok(()),
        _ => Err("only explicit i64 return functions are supported".to_string()),
    }
}

fn collect_i64_params(function: &ItemFn) -> Result<Vec<String>, String> {
    let mut params = Vec::new();
    for arg in &function.sig.inputs {
        let FnArg::Typed(pat_type) = arg else {
            return Err("methods with self receiver are unsupported".to_string());
        };
        let Pat::Ident(ident) = pat_type.pat.as_ref() else {
            return Err("only identifier parameters are supported".to_string());
        };
        if type_last_segment(&pat_type.ty) != Some("i64".to_string()) {
            return Err(format!("parameter {} is not i64", ident.ident));
        }
        params.push(ident.ident.to_string());
    }
    Ok(params)
}

fn build_input_domains(
    params: &[String],
    config: &ExtractorConfig,
) -> Result<BTreeMap<String, Vec<i64>>, String> {
    if config.default_domain_min > config.default_domain_max {
        return Err("default_domain_min exceeds default_domain_max".to_string());
    }
    let mut domains = BTreeMap::new();
    if params.is_empty() {
        domains.insert("__unit".to_string(), vec![0]);
        return Ok(domains);
    }
    for param in params {
        domains.insert(
            param.clone(),
            (config.default_domain_min..=config.default_domain_max).collect(),
        );
    }
    Ok(domains)
}

fn reject_impure_or_complex_body(function: &ItemFn) -> Result<(), String> {
    for stmt in &function.block.stmts {
        reject_stmt(stmt, &function.sig.ident.to_string())?;
    }
    Ok(())
}

fn reject_stmt(stmt: &Stmt, function_name: &str) -> Result<(), String> {
    match stmt {
        Stmt::Expr(expr, _) => reject_expr(expr, function_name),
        Stmt::Local(_) => Err("local bindings are unsupported in v1".to_string()),
        Stmt::Item(_) => Err("nested items are unsupported".to_string()),
        Stmt::Macro(_) => Err("macros are unsupported".to_string()),
    }
}

fn reject_expr(expr: &Expr, function_name: &str) -> Result<(), String> {
    match expr {
        Expr::Binary(binary) => {
            reject_expr(&binary.left, function_name)?;
            reject_expr(&binary.right, function_name)
        }
        Expr::Call(call) => reject_call(call, function_name),
        Expr::Lit(_) | Expr::Path(_) => Ok(()),
        Expr::MethodCall(method_call) => reject_method_call(method_call, function_name),
        Expr::Paren(paren) => reject_expr(&paren.expr, function_name),
        Expr::Return(return_expr) => {
            if let Some(expr) = &return_expr.expr {
                reject_expr(expr, function_name)
            } else {
                Err("empty return is unsupported".to_string())
            }
        }
        Expr::Unary(unary) => reject_expr(&unary.expr, function_name),
        Expr::ForLoop(_) | Expr::Loop(_) | Expr::While(_) => {
            Err("loops are unsupported".to_string())
        }
        Expr::Macro(_) => Err("macros are unsupported".to_string()),
        _ => Err(format!("unsupported expression: {}", expr_kind(expr))),
    }
}

fn reject_call(call: &ExprCall, function_name: &str) -> Result<(), String> {
    let callee = path_expr_name(&call.func);
    if callee.as_deref() == Some(function_name) {
        return Err("recursion is unsupported".to_string());
    }
    if matches!(callee.as_deref(), Some("min" | "max" | "abs")) {
        for arg in &call.args {
            reject_expr(arg, function_name)?;
        }
        Ok(())
    } else {
        Err(format!(
            "function call {} is unsupported",
            callee.unwrap_or_else(|| "<unknown>".to_string())
        ))
    }
}

fn reject_method_call(method_call: &ExprMethodCall, function_name: &str) -> Result<(), String> {
    let method = method_call.method.to_string();
    if !matches!(method.as_str(), "min" | "max" | "abs") {
        return Err(format!("method call {method} is unsupported"));
    }
    reject_expr(&method_call.receiver, function_name)?;
    for arg in &method_call.args {
        reject_expr(arg, function_name)?;
    }
    Ok(())
}

fn extract_return_expr(block: &Block) -> Result<&Expr, String> {
    let Some(stmt) = block.stmts.last() else {
        return Err("empty function body".to_string());
    };
    match stmt {
        Stmt::Expr(
            Expr::Return(ExprReturn {
                expr: Some(expr), ..
            }),
            _,
        ) => Ok(expr),
        Stmt::Expr(expr, None) => Ok(expr),
        Stmt::Expr(expr, Some(_)) => {
            if let Expr::Return(ExprReturn {
                expr: Some(expr), ..
            }) = expr
            {
                Ok(expr)
            } else {
                Err("function body must end with expression or return expression".to_string())
            }
        }
        _ => Err("function body must end with expression or return expression".to_string()),
    }
}

fn parse_decision_expr(expr: &Expr, params: &[String]) -> Result<DecisionExpr, String> {
    match expr {
        Expr::Binary(binary) => parse_binary(binary, params),
        Expr::Call(call) => parse_call(call, params),
        Expr::Lit(lit) => parse_lit(lit),
        Expr::MethodCall(method_call) => parse_method_call(method_call, params),
        Expr::Paren(paren) => parse_decision_expr(&paren.expr, params),
        Expr::Path(path) => parse_path(path, params),
        Expr::Return(return_expr) => {
            let Some(expr) = &return_expr.expr else {
                return Err("empty return is unsupported".to_string());
            };
            parse_decision_expr(expr, params)
        }
        Expr::Unary(unary) => parse_unary(unary, params),
        _ => Err(format!(
            "unsupported expression for IR: {}",
            expr_kind(expr)
        )),
    }
}

fn parse_binary(binary: &ExprBinary, params: &[String]) -> Result<DecisionExpr, String> {
    let left = Box::new(parse_decision_expr(&binary.left, params)?);
    let right = Box::new(parse_decision_expr(&binary.right, params)?);
    match binary.op {
        BinOp::Add(_) => Ok(DecisionExpr::Add { left, right }),
        BinOp::Sub(_) => Ok(DecisionExpr::Sub { left, right }),
        BinOp::Mul(_) => Ok(DecisionExpr::Mul { left, right }),
        _ => Err("only add/sub/mul binary operators are supported".to_string()),
    }
}

fn parse_call(call: &ExprCall, params: &[String]) -> Result<DecisionExpr, String> {
    let name = path_expr_name(&call.func).ok_or_else(|| "unsupported call target".to_string())?;
    match (name.as_str(), call.args.len()) {
        ("abs", 1) => Ok(DecisionExpr::Abs {
            value: Box::new(parse_decision_expr(&call.args[0], params)?),
        }),
        ("min", 2) => Ok(DecisionExpr::Min {
            left: Box::new(parse_decision_expr(&call.args[0], params)?),
            right: Box::new(parse_decision_expr(&call.args[1], params)?),
        }),
        ("max", 2) => Ok(DecisionExpr::Max {
            left: Box::new(parse_decision_expr(&call.args[0], params)?),
            right: Box::new(parse_decision_expr(&call.args[1], params)?),
        }),
        _ => Err(format!("unsupported call expression: {name}")),
    }
}

fn parse_lit(lit: &ExprLit) -> Result<DecisionExpr, String> {
    let Lit::Int(value) = &lit.lit else {
        return Err("only integer literals are supported".to_string());
    };
    Ok(DecisionExpr::Const {
        value: value
            .base10_parse::<i64>()
            .map_err(|error| format!("invalid integer literal: {error}"))?,
    })
}

fn parse_method_call(
    method_call: &ExprMethodCall,
    params: &[String],
) -> Result<DecisionExpr, String> {
    let method = method_call.method.to_string();
    match (method.as_str(), method_call.args.len()) {
        ("abs", 0) => Ok(DecisionExpr::Abs {
            value: Box::new(parse_decision_expr(&method_call.receiver, params)?),
        }),
        ("min", 1) => Ok(DecisionExpr::Min {
            left: Box::new(parse_decision_expr(&method_call.receiver, params)?),
            right: Box::new(parse_decision_expr(&method_call.args[0], params)?),
        }),
        ("max", 1) => Ok(DecisionExpr::Max {
            left: Box::new(parse_decision_expr(&method_call.receiver, params)?),
            right: Box::new(parse_decision_expr(&method_call.args[0], params)?),
        }),
        _ => Err(format!("unsupported method call: {method}")),
    }
}

fn parse_path(path: &ExprPath, params: &[String]) -> Result<DecisionExpr, String> {
    if path.qself.is_some() {
        return Err("qualified paths are unsupported".to_string());
    }
    let Some(ident) = path.path.get_ident() else {
        return Err("multi-segment paths are unsupported".to_string());
    };
    let name = ident.to_string();
    if params.contains(&name) {
        Ok(DecisionExpr::Var { name })
    } else {
        Err(format!("unknown variable path: {name}"))
    }
}

fn parse_unary(unary: &ExprUnary, params: &[String]) -> Result<DecisionExpr, String> {
    match unary.op {
        UnOp::Neg(_) => Ok(DecisionExpr::Sub {
            left: Box::new(DecisionExpr::Const { value: 0 }),
            right: Box::new(parse_decision_expr(&unary.expr, params)?),
        }),
        _ => Err("only unary negation is supported".to_string()),
    }
}

fn path_expr_name(expr: &Expr) -> Option<String> {
    let Expr::Path(path) = expr else {
        return None;
    };
    path.path
        .segments
        .last()
        .map(|segment| segment.ident.to_string())
}

fn type_last_segment(ty: &syn::Type) -> Option<String> {
    let syn::Type::Path(path) = ty else {
        return None;
    };
    path.path
        .segments
        .last()
        .map(|segment| segment.ident.to_string())
}

fn hash_ir(content: &str, function_name: &str, params: &[String]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(function_name.as_bytes());
    hasher.update(b"|");
    for param in params {
        hasher.update(param.as_bytes());
        hasher.update(b",");
    }
    hasher.update(b"|");
    hasher.update(content.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn case_space(domains: &BTreeMap<String, Vec<i64>>) -> u128 {
    domains.values().fold(1u128, |acc, domain| {
        acc.saturating_mul(domain.len() as u128)
    })
}

fn expr_kind(expr: &Expr) -> &'static str {
    match expr {
        Expr::Array(_) => "array",
        Expr::Assign(_) => "assign",
        Expr::Async(_) => "async",
        Expr::Await(_) => "await",
        Expr::Binary(_) => "binary",
        Expr::Block(_) => "block",
        Expr::Break(_) => "break",
        Expr::Call(_) => "call",
        Expr::Cast(_) => "cast",
        Expr::Closure(_) => "closure",
        Expr::Const(_) => "const",
        Expr::Continue(_) => "continue",
        Expr::Field(_) => "field",
        Expr::ForLoop(_) => "for_loop",
        Expr::Group(_) => "group",
        Expr::If(_) => "if",
        Expr::Index(_) => "index",
        Expr::Infer(_) => "infer",
        Expr::Let(_) => "let",
        Expr::Lit(_) => "lit",
        Expr::Loop(_) => "loop",
        Expr::Macro(_) => "macro",
        Expr::Match(_) => "match",
        Expr::MethodCall(_) => "method_call",
        Expr::Paren(_) => "paren",
        Expr::Path(_) => "path",
        Expr::Range(_) => "range",
        Expr::RawAddr(_) => "raw_addr",
        Expr::Reference(_) => "reference",
        Expr::Repeat(_) => "repeat",
        Expr::Return(_) => "return",
        Expr::Struct(_) => "struct",
        Expr::Try(_) => "try",
        Expr::TryBlock(_) => "try_block",
        Expr::Tuple(_) => "tuple",
        Expr::Unary(_) => "unary",
        Expr::Unsafe(_) => "unsafe",
        Expr::Verbatim(_) => "verbatim",
        Expr::While(_) => "while",
        Expr::Yield(_) => "yield",
        _ => "unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lazarus_contracts::DecisionExpr;
    use lazarus_scanner::{ScannerConfig, scan_crate};
    use std::path::{Path, PathBuf};

    #[test]
    fn simple_const_function_can_be_extracted() {
        let root = fixture("const_fn", "pub fn simple_fee() -> i64 { 42 }");
        let result = extract_fixture(&root);

        assert_eq!(result.irs.len(), 1, "{:?}", result.skip_reasons);
        assert!(matches!(
            result.irs[0].expression,
            DecisionExpr::Const { value: 42 }
        ));
        assert!(result.irs[0].input_domains.contains_key("__unit"));
        assert!(verify_all_bounded(&result).is_ok());
    }

    #[test]
    fn input_plus_one_can_be_extracted() {
        let root = fixture(
            "add_fn",
            "pub fn increment(input: i64) -> i64 { input + 1 }",
        );
        let result = extract_fixture(&root);

        assert_eq!(result.irs.len(), 1, "{:?}", result.skip_reasons);
        assert!(matches!(result.irs[0].expression, DecisionExpr::Add { .. }));
        assert!(result.irs[0].input_domains.contains_key("input"));
    }

    #[test]
    fn input_mul_two_can_be_extracted() {
        let root = fixture("mul_fn", "pub fn double(input: i64) -> i64 { input * 2 }");
        let result = extract_fixture(&root);

        assert_eq!(result.irs.len(), 1, "{:?}", result.skip_reasons);
        assert!(matches!(result.irs[0].expression, DecisionExpr::Mul { .. }));
    }

    #[test]
    fn multi_param_generates_multiple_input_domains() {
        let root = fixture("multi_fn", "pub fn sum(a: i64, b: i64) -> i64 { a + b }");
        let result = extract_fixture(&root);

        assert_eq!(result.irs.len(), 1, "{:?}", result.skip_reasons);
        assert!(result.irs[0].input_domains.contains_key("a"));
        assert!(result.irs[0].input_domains.contains_key("b"));
        assert!(verify_all_bounded(&result).is_ok());
    }

    #[test]
    fn min_max_abs_can_be_extracted() {
        let root = fixture(
            "min_max_abs_fn",
            "pub fn clamp_abs(input: i64) -> i64 { input.abs().min(100).max(0) }",
        );
        let result = extract_fixture(&root);

        assert_eq!(result.irs.len(), 1, "{:?}", result.skip_reasons);
        assert!(matches!(result.irs[0].expression, DecisionExpr::Max { .. }));
    }

    #[test]
    fn println_is_skipped_as_side_effect() {
        let root = fixture(
            "println_fn",
            "pub fn debug_fee(input: i64) -> i64 { println!(\"{}\", input); input * 2 }",
        );
        let result = extract_fixture(&root);

        assert!(result.irs.is_empty());
        assert!(
            result
                .skip_reasons
                .iter()
                .any(|skip| skip.reason.contains("macros are unsupported"))
        );
    }

    #[test]
    fn fs_operation_is_skipped_as_unsupported_call() {
        let root = fixture(
            "fs_fn",
            "pub fn load_fee() -> i64 { std::fs::read_to_string(\"data.txt\"); 42 }",
        );
        let result = extract_fixture(&root);

        assert!(result.irs.is_empty());
        assert!(!result.skip_reasons.is_empty());
    }

    #[test]
    fn loop_function_is_skipped() {
        let root = fixture(
            "loop_fn",
            "pub fn accumulate() -> i64 { for i in 0..10 { return i; } 0 }",
        );
        let result = extract_fixture(&root);

        assert!(result.irs.is_empty());
        assert!(
            result
                .skip_reasons
                .iter()
                .any(|skip| skip.reason.contains("loops are unsupported"))
        );
    }

    #[test]
    fn non_rust_units_are_ignored() {
        let scan = ScanResult {
            graph: lazarus_contracts::DependencyGraph {
                contract_version: lazarus_contracts::LAZARUS_CONTRACT_VERSION,
                codebase_id: "non-rust".to_string(),
                units: vec![lazarus_contracts::CodeUnit {
                    unit_id: "non-rust/src/legacy.java".to_string(),
                    language: lazarus_contracts::SourceLanguage::OldJava,
                    path: "src/legacy.java".to_string(),
                    content_hash: "0123456789abcdef".to_string(),
                    entrypoints: Vec::new(),
                    risk_level: lazarus_contracts::RiskLevel::Low,
                }],
                edges: Vec::new(),
            },
            skip_reasons: Vec::new(),
        };
        let result = extract_ir_from_scan(&scan, &ExtractorConfig::default());

        assert!(result.irs.is_empty());
        assert!(result.skip_reasons.is_empty());
    }

    #[test]
    fn bounded_validation_rejects_too_many_params() {
        let root = fixture(
            "too_many_params",
            "pub fn big(a: i64, b: i64, c: i64) -> i64 { a + b + c }",
        );
        let result = extract_fixture(&root);

        assert!(result.irs.is_empty());
        assert!(
            result
                .skip_reasons
                .iter()
                .any(|skip| skip.reason.contains("validate_bounded failed"))
        );
    }

    #[test]
    fn stricter_config_case_space_is_enforced() {
        let root = fixture(
            "strict_cases",
            "pub fn sum(a: i64, b: i64) -> i64 { a + b }",
        );
        let scan = scan_crate(&root, &ScannerConfig::default());
        let result = extract_ir_from_scan(
            &scan,
            &ExtractorConfig {
                max_cases: 10,
                ..ExtractorConfig::default()
            },
        );

        assert!(result.irs.is_empty());
        assert!(
            result
                .skip_reasons
                .iter()
                .any(|skip| skip.reason.contains("exceeds configured max_cases"))
        );
    }

    fn extract_fixture(root: &Path) -> ExtractResult {
        let scan = scan_crate(root, &ScannerConfig::default());
        assert!(scan.validate().is_ok(), "{:?}", scan.skip_reasons);
        extract_ir_from_scan(&scan, &ExtractorConfig::default())
    }

    fn fixture(name: &str, source: &str) -> PathBuf {
        let root = std::env::temp_dir()
            .join(format!(
                "lazarus-ir-extractor-fixtures-{}",
                std::process::id()
            ))
            .join(name);
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(
            root.join("Cargo.toml"),
            format!("[package]\nname = \"{name}\"\nversion = \"0.1.0\"\n"),
        )
        .unwrap();
        std::fs::write(root.join("src/lib.rs"), source).unwrap();
        root
    }
}
