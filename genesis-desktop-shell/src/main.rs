use genesis_desktop_shell::GenesisDesktopShell;
use genesis_platform::desktop::DesktopPlatformAdapter;
use genesis_platform::{PlatformError, RuntimeProfile};
use genesis_sdk::{EvidenceBytesPage, EvidenceListPage};
use std::time::Duration;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args = std::env::args().collect::<Vec<_>>();
    let shell = GenesisDesktopShell::new(default_adapter()?).with_timeout(Duration::from_secs(3));

    match args.get(1).map(String::as_str) {
        Some("health") => print_json(&shell.health()),
        Some("evidence-list") => {
            let offset = parse_usize(args.get(2), 0, "offset")?;
            let limit = parse_usize(args.get(3), 32, "limit")?;
            let page = shell
                .list_evidence(offset, limit)
                .map_err(|error| error.to_string())?;
            print_json(&evidence_list_json(&page))
        }
        Some("evidence-read") => {
            let path = args.get(2).ok_or_else(|| {
                "usage: genesis-desktop-shell evidence-read <path> [offset] [limit]".to_string()
            })?;
            let offset = parse_usize(args.get(3), 0, "offset")?;
            let limit = parse_usize(args.get(4), 4096, "limit")?;
            let page = shell
                .read_evidence_page(path, offset, limit)
                .map_err(|error| error.to_string())?;
            print_json(&evidence_bytes_json(&page))
        }
        Some("send-local-action") => {
            let service = args.get(2).ok_or_else(|| {
                "usage: genesis-desktop-shell send-local-action <service> <action-json>".to_string()
            })?;
            let action = args.get(3).ok_or_else(|| {
                "usage: genesis-desktop-shell send-local-action <service> <action-json>".to_string()
            })?;
            print_json(
                &shell
                    .send_local_action(service, action)
                    .map_err(|error| error.to_string())?,
            )
        }
        Some("request-remote-action") => {
            let url = args.get(2).ok_or_else(|| {
                "usage: genesis-desktop-shell request-remote-action <url> <action-json>".to_string()
            })?;
            let action = args.get(3).ok_or_else(|| {
                "usage: genesis-desktop-shell request-remote-action <url> <action-json>".to_string()
            })?;
            print_json(
                &shell
                    .request_remote_action(url, action)
                    .map_err(|error| error.to_string())?,
            )
        }
        _ => {
            eprintln!(
                "usage:\n  genesis-desktop-shell health\n  genesis-desktop-shell evidence-list [offset] [limit]\n  genesis-desktop-shell evidence-read <path> [offset] [limit]\n  genesis-desktop-shell send-local-action <service> <action-json>\n  genesis-desktop-shell request-remote-action <url> <action-json>"
            );
            Ok(())
        }
    }
}

fn default_adapter() -> Result<DesktopPlatformAdapter, String> {
    DesktopPlatformAdapter::current("genesis", RuntimeProfile::DesktopSafe)
        .map_err(platform_error_to_string)
}

fn parse_usize(raw: Option<&String>, default: usize, name: &str) -> Result<usize, String> {
    raw.map(|value| {
        value
            .parse::<usize>()
            .map_err(|error| format!("{name} must be a usize: {error}"))
    })
    .transpose()
    .map(|value| value.unwrap_or(default))
}

fn print_json<T: serde::Serialize>(value: &T) -> Result<(), String> {
    println!(
        "{}",
        serde_json::to_string_pretty(value).map_err(|error| error.to_string())?
    );
    Ok(())
}

fn evidence_list_json(page: &EvidenceListPage) -> serde_json::Value {
    serde_json::json!({
        "root": page.root.to_string_lossy(),
        "offset": page.offset,
        "limit": page.limit,
        "entries": page
            .entries
            .iter()
            .map(|entry| entry.to_string_lossy().into_owned())
            .collect::<Vec<_>>(),
        "next_offset": page.next_offset,
    })
}

fn evidence_bytes_json(page: &EvidenceBytesPage) -> serde_json::Value {
    serde_json::json!({
        "relative_path": page.relative_path.to_string_lossy(),
        "offset": page.offset,
        "total_bytes": page.total_bytes,
        "bytes_utf8_lossy": String::from_utf8_lossy(&page.bytes),
        "next_offset": page.next_offset,
    })
}

fn platform_error_to_string(error: PlatformError) -> String {
    error.to_string()
}
