use genesis_os_driver::{LogicalPoint, default_driver};
use serde::Serialize;

#[derive(Serialize)]
struct CliError {
    status: &'static str,
    error: String,
}

fn main() {
    if let Err(error) = run() {
        print_json(&CliError {
            status: "error",
            error: error.to_string(),
        });
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "probe".to_string());
    let rest: Vec<String> = args.collect();
    let driver = default_driver();

    match command.as_str() {
        "probe" => print_json(&driver.probe()),
        "selftest" => {
            let probe = driver.probe();
            print_json(&probe);
            let point = center_point(&probe).unwrap_or(LogicalPoint { x: 100.0, y: 100.0 });
            let receipt = driver.move_mouse(point, false)?;
            print_json(&receipt);
        }
        "move" => {
            let options = Options::parse(&rest)?;
            let receipt = driver.move_mouse(options.point, options.armed)?;
            print_json(&receipt);
        }
        "click" => {
            let options = Options::parse(&rest)?;
            let receipt = driver.click_left(options.point, options.armed)?;
            print_json(&receipt);
        }
        _ => {
            return Err(format!(
                "unknown command '{command}'. Use probe, selftest, move, or click"
            )
            .into());
        }
    }

    Ok(())
}

#[derive(Debug)]
struct Options {
    point: LogicalPoint,
    armed: bool,
}

impl Options {
    fn parse(args: &[String]) -> Result<Self, Box<dyn std::error::Error>> {
        let mut x = None;
        let mut y = None;
        let mut armed = false;
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--x" => {
                    index += 1;
                    x = Some(parse_value(args, index, "--x")?);
                }
                "--y" => {
                    index += 1;
                    y = Some(parse_value(args, index, "--y")?);
                }
                "--armed" => armed = true,
                flag => return Err(format!("unknown option '{flag}'").into()),
            }
            index += 1;
        }

        Ok(Self {
            point: LogicalPoint {
                x: x.ok_or("missing --x")?,
                y: y.ok_or("missing --y")?,
            },
            armed,
        })
    }
}

fn parse_value(
    args: &[String],
    index: usize,
    name: &str,
) -> Result<f64, Box<dyn std::error::Error>> {
    let value = args
        .get(index)
        .ok_or_else(|| format!("{name} requires a value"))?;
    Ok(value.parse::<f64>()?)
}

fn center_point(probe: &genesis_os_driver::DriverProbe) -> Option<LogicalPoint> {
    let display = probe.main_display.as_ref()?;
    Some(LogicalPoint {
        x: display.logical_origin_x + display.logical_width / 2.0,
        y: display.logical_origin_y + display.logical_height / 2.0,
    })
}

fn print_json<T: Serialize>(value: &T) {
    println!(
        "{}",
        serde_json::to_string_pretty(value).expect("JSON serialization failed")
    );
}
