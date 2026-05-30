use lazarus_contracts::{DecisionExpr, DecisionIr};

pub(super) fn render_executable_source(
    ir: &DecisionIr,
    input_order: &[String],
    function_name: &str,
) -> Result<String, String> {
    for input in input_order {
        validate_identifier(input, "input")?;
    }
    let signature = input_order
        .iter()
        .map(|name| format!("{name}: i64"))
        .collect::<Vec<_>>()
        .join(", ");
    let parse_args = input_order
        .iter()
        .enumerate()
        .map(|(index, name)| {
            format!(
                "    let {name}: i64 = args[{arg_index}].parse().unwrap_or_else(|_| {{ eprintln!(\"invalid i64 arg {name}\"); std::process::exit(65); }});\n",
                arg_index = index + 1
            )
        })
        .collect::<String>();
    let call_args = input_order.join(", ");
    let expected_arg_count = input_order.len() + 1;
    let expr = compile_expr(&ir.expression)?;

    Ok(format!(
        "// Generated executable artifact by Project Lazarus.\n\
fn {function_name}({signature}) -> i64 {{\n\
    {expr}\n\
}}\n\
\n\
fn main() {{\n\
    let args: Vec<String> = std::env::args().collect();\n\
    if args.len() != {expected_arg_count} {{\n\
        eprintln!(\"expected {} i64 args, got {{}}\", args.len().saturating_sub(1));\n\
        std::process::exit(64);\n\
    }}\n\
{parse_args}\
    println!(\"{{}}\", {function_name}({call_args}));\n\
}}\n",
        input_order.len()
    ))
}

pub(super) fn render_wasm_source(
    ir: &DecisionIr,
    input_order: &[String],
    function_name: &str,
) -> Result<String, String> {
    for input in input_order {
        validate_identifier(input, "input")?;
    }
    let signature = input_order
        .iter()
        .map(|name| format!("{name}: i64"))
        .collect::<Vec<_>>()
        .join(", ");
    let expr = compile_wasm_expr(&ir.expression)?;

    Ok(format!(
        "#![no_std]\n\
#[panic_handler]\n\
fn panic(_: &core::panic::PanicInfo) -> ! {{ loop {{}} }}\n\
\n\
#[unsafe(no_mangle)]\n\
pub extern \"C\" fn {function_name}({signature}) -> i64 {{\n\
    {expr}\n\
}}\n"
    ))
}

pub(super) fn sorted_inputs(ir: &DecisionIr) -> Vec<String> {
    let mut inputs = ir
        .input_domains
        .keys()
        .filter(|name| name.as_str() != "__unit")
        .cloned()
        .collect::<Vec<_>>();
    inputs.sort();
    inputs
}

pub(super) fn validate_identifier(value: &str, field: &str) -> Result<(), String> {
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

fn compile_expr(expr: &DecisionExpr) -> Result<String, String> {
    match expr {
        DecisionExpr::Const { value } => Ok(value.to_string()),
        DecisionExpr::Var { name } => {
            validate_identifier(name, "var")?;
            Ok(name.clone())
        }
        DecisionExpr::Add { left, right } => Ok(format!(
            "({}).saturating_add({})",
            compile_expr(left)?,
            compile_expr(right)?
        )),
        DecisionExpr::Sub { left, right } => Ok(format!(
            "({}).saturating_sub({})",
            compile_expr(left)?,
            compile_expr(right)?
        )),
        DecisionExpr::Mul { left, right } => Ok(format!(
            "({}).saturating_mul({})",
            compile_expr(left)?,
            compile_expr(right)?
        )),
        DecisionExpr::Min { left, right } => Ok(format!(
            "std::cmp::min({}, {})",
            compile_expr(left)?,
            compile_expr(right)?
        )),
        DecisionExpr::Max { left, right } => Ok(format!(
            "std::cmp::max({}, {})",
            compile_expr(left)?,
            compile_expr(right)?
        )),
        DecisionExpr::Abs { value } => Ok(format!("({}).saturating_abs()", compile_expr(value)?)),
    }
}

fn compile_wasm_expr(expr: &DecisionExpr) -> Result<String, String> {
    match expr {
        DecisionExpr::Const { value } => Ok(value.to_string()),
        DecisionExpr::Var { name } => {
            validate_identifier(name, "var")?;
            Ok(name.clone())
        }
        DecisionExpr::Add { left, right } => Ok(format!(
            "({}).saturating_add({})",
            compile_wasm_expr(left)?,
            compile_wasm_expr(right)?
        )),
        DecisionExpr::Sub { left, right } => Ok(format!(
            "({}).saturating_sub({})",
            compile_wasm_expr(left)?,
            compile_wasm_expr(right)?
        )),
        DecisionExpr::Mul { left, right } => Ok(format!(
            "({}).saturating_mul({})",
            compile_wasm_expr(left)?,
            compile_wasm_expr(right)?
        )),
        DecisionExpr::Min { left, right } => Ok(format!(
            "core::cmp::min({}, {})",
            compile_wasm_expr(left)?,
            compile_wasm_expr(right)?
        )),
        DecisionExpr::Max { left, right } => Ok(format!(
            "core::cmp::max({}, {})",
            compile_wasm_expr(left)?,
            compile_wasm_expr(right)?
        )),
        DecisionExpr::Abs { value } => {
            Ok(format!("({}).saturating_abs()", compile_wasm_expr(value)?))
        }
    }
}
