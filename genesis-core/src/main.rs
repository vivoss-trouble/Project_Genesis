// genesis-core/src/main.rs
#![cfg_attr(
    not(any(feature = "native-runtime", feature = "wasm-runtime")),
    allow(dead_code)
)]

mod act;
mod audit;
mod hot_reload;
mod kernel;
mod sense;
mod verify;
mod watchdog;
use audit::{AuditEvent, AuditLogger};
use genesis_platform::desktop::DesktopPlatformAdapter;
use genesis_platform::{PlatformAdapter, RuntimeProfile};
use kernel::GenesisKernel;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const GENESIS_ALLOW_NATIVE_PLUGINS: &str = "GENESIS_ALLOW_NATIVE_PLUGINS";
const GENESIS_NATIVE_PLUGIN_TRUST: &str = "GENESIS_NATIVE_PLUGIN_TRUST";
const GENESIS_RUNTIME_PROFILE: &str = "GENESIS_RUNTIME_PROFILE";
const NATIVE_PLUGIN_EXTENSIONS: &[&str] = &["dylib", "so", "dll"];

fn main() {
    println!("🌌 创世纪微核 (Genesis Core) - 永不停机版本启动...");
    let auditor = AuditLogger::new(4096);
    let platform = DesktopPlatformAdapter::legacy_runtime(RuntimeProfile::DesktopSafe);
    let kernel = Arc::new(Mutex::new(GenesisKernel::new(auditor.clone())));
    let k = kernel.clone();

    // 锁定绝对物理坐标
    let current_dir = platform.current_dir().unwrap();
    let watch_path = current_dir.join("genesis-plugins");
    let watch_path_str = watch_path.to_str().unwrap().to_string();

    println!("[微核] 🔍 正在锁定绝对物理坐标: {}", watch_path_str);

    let allow_native_plugins = native_plugins_enabled();
    if !allow_native_plugins {
        println!(
            "[微核] 🔒 原生 .so/.dylib/.dll 插件默认禁用；仅明确 development/local profile + {}=1 + {}=dev-only 才会加载可信插件。",
            GENESIS_ALLOW_NATIVE_PLUGINS, GENESIS_NATIVE_PLUGIN_TRUST
        );
    }

    // 启动全知之眼
    let mut last_reload_at: HashMap<String, Instant> = HashMap::new();
    if allow_native_plugins {
        hot_reload::start_watcher(&watch_path_str, move |path| {
            if is_native_plugin_path(path) {
                let now = Instant::now();
                if last_reload_at
                    .get(path)
                    .is_some_and(|last| now.duration_since(*last) < Duration::from_millis(500))
                {
                    return;
                }
                last_reload_at.insert(path.to_string(), now);

                println!("[监视器] 🧐 捕获到物理变动: {}", path);
                let mut guard = k.lock().unwrap();
                match guard.reload_plugin(path) {
                    Ok(_) => println!("[监视器] ✅ 换头手术成功！"),
                    Err(e) => println!("[监视器] ❌ 换头手术失败: {}", e),
                }
            }
        })
        .unwrap();
    }

    println!("[微核] 🧿 全知之眼已睁开，心跳脉冲发生器启动...");

    let plugin_entries = platform.read_dir_paths(&watch_path).ok();
    if let Some(entries) = plugin_entries {
        let mut wasm_plugin_paths = Vec::new();
        let mut native_plugin_paths = Vec::new();
        for path in entries {
            let extension = path.extension().and_then(|ext| ext.to_str());
            match extension {
                Some("wasm") => wasm_plugin_paths.push(path),
                Some(ext) if is_native_plugin_extension(ext) && allow_native_plugins => {
                    native_plugin_paths.push(path)
                }
                Some(ext) if is_native_plugin_extension(ext) => {
                    println!(
                        "[微核] 🔒 跳过原生插件 [{}]；仅 development/local profile + {}=1 + {}=dev-only 会加载可信插件。",
                        path.display(),
                        GENESIS_ALLOW_NATIVE_PLUGINS,
                        GENESIS_NATIVE_PLUGIN_TRUST
                    );
                }
                _ => {}
            }
        }
        wasm_plugin_paths.sort();
        native_plugin_paths.sort();

        let mut guard = kernel.lock().unwrap();
        for plugin_path in wasm_plugin_paths {
            let Some(plugin_path_str) = plugin_path.to_str() else {
                continue;
            };

            let Ok(wasm_bytes) = platform.read_file(plugin_path.as_path()) else {
                println!(
                    "[微核] ❌ 初始 Wasm 插件读取失败 [{}]",
                    plugin_path.display()
                );
                continue;
            };

            match guard.load_wasm_plugin(plugin_path_str, &wasm_bytes) {
                Ok(_) => println!("[微核] ✅ 初始 Wasm 插件装载完成: {}", plugin_path_str),
                Err(e) => println!(
                    "[微核] ❌ 初始 Wasm 插件装载失败 [{}]: {}",
                    plugin_path_str, e
                ),
            }
        }

        for plugin_path in native_plugin_paths {
            let Some(plugin_path) = plugin_path.to_str() else {
                continue;
            };

            match guard.load_plugin(plugin_path) {
                Ok(_) => println!("[微核] ✅ 初始插件装载完成: {}", plugin_path),
                Err(e) => println!("[微核] ❌ 初始插件装载失败 [{}]: {}", plugin_path, e),
            }
        }
    }

    // 💓 终极狂欢：每隔 2 秒的心跳脉冲
    let mut tick = 0;
    loop {
        thread::sleep(Duration::from_secs(2));
        tick += 1;

        auditor.log(AuditEvent::TickStarted { tick_id: tick });
        let mut payload = sense::build_tick_payload(tick, None);
        let mut guard = kernel.lock().unwrap();
        if let Some(outcome) = guard.verify_pending_outcomes(tick, &payload) {
            payload = sense::attach_last_outcome(&payload, outcome);
        }
        if let Some(active_step) = guard.active_step_payload() {
            payload = sense::attach_active_step(&payload, active_step);
        }
        auditor.log(AuditEvent::SenseCaptured {
            tick_id: tick,
            state_json: payload.clone(),
        });
        let kernel_health = guard.health();
        println!("\n🫀 [微核脉冲] 正在向插件发射: {}", payload);
        println!("[微核健康] {:?}", kernel_health);

        guard.trigger_all(tick, &payload);
    }
}

fn is_native_plugin_path(path: &str) -> bool {
    std::path::Path::new(path)
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(is_native_plugin_extension)
}

fn is_native_plugin_extension(extension: &str) -> bool {
    NATIVE_PLUGIN_EXTENSIONS.contains(&extension)
}

fn native_plugins_enabled() -> bool {
    native_plugins_enabled_for(
        std::env::var(GENESIS_ALLOW_NATIVE_PLUGINS).ok().as_deref(),
        std::env::var(GENESIS_RUNTIME_PROFILE).ok().as_deref(),
        std::env::var(GENESIS_NATIVE_PLUGIN_TRUST).ok().as_deref(),
    )
}

fn native_plugins_enabled_for(
    allow_value: Option<&str>,
    profile_value: Option<&str>,
    trust_value: Option<&str>,
) -> bool {
    if !runtime_profile_allows_native_plugins(profile_value) {
        return false;
    }
    parse_native_plugin_flag(allow_value) && parse_native_plugin_trust(trust_value)
}

fn parse_native_plugin_flag(value: Option<&str>) -> bool {
    matches!(
        value.map(str::trim),
        Some("1") | Some("true") | Some("TRUE") | Some("yes") | Some("YES")
    )
}

fn parse_native_plugin_trust(value: Option<&str>) -> bool {
    matches!(
        value.map(str::trim),
        Some("dev-only") | Some("DEV-ONLY") | Some("trusted-dev") | Some("TRUSTED-DEV")
    )
}

fn runtime_profile_allows_native_plugins(value: Option<&str>) -> bool {
    matches!(
        value.map(str::trim),
        Some("development")
            | Some("DEVELOPMENT")
            | Some("dev")
            | Some("DEV")
            | Some("local")
            | Some("LOCAL")
            | Some("test")
            | Some("TEST")
    )
}

#[cfg(test)]
mod tests {
    use super::{
        is_native_plugin_extension, is_native_plugin_path, native_plugins_enabled_for,
        parse_native_plugin_flag, parse_native_plugin_trust,
    };

    #[test]
    fn native_plugin_extensions_cover_desktop_dev_targets() {
        assert!(is_native_plugin_extension("dylib"));
        assert!(is_native_plugin_extension("so"));
        assert!(is_native_plugin_extension("dll"));
        assert!(is_native_plugin_path("genesis-plugins/libplugin_dummy.dll"));
        assert!(!is_native_plugin_path(
            "genesis-plugins/plugin-dummy-wasm.wasm"
        ));
    }

    #[test]
    fn native_plugin_loading_is_opt_in() {
        assert!(!parse_native_plugin_flag(None));
        assert!(!parse_native_plugin_flag(Some("0")));
        assert!(!parse_native_plugin_flag(Some("false")));
        assert!(parse_native_plugin_flag(Some("1")));
        assert!(parse_native_plugin_flag(Some("true")));
        assert!(parse_native_plugin_flag(Some(" yes ")));
    }

    #[test]
    fn native_plugin_trust_scope_is_explicit() {
        assert!(!parse_native_plugin_trust(None));
        assert!(!parse_native_plugin_trust(Some("production")));
        assert!(parse_native_plugin_trust(Some("dev-only")));
        assert!(parse_native_plugin_trust(Some("trusted-dev")));
    }

    #[test]
    fn native_plugins_require_dev_profile_flag_and_trust_scope() {
        assert!(!native_plugins_enabled_for(
            Some("1"),
            Some("release"),
            Some("dev-only")
        ));
        assert!(!native_plugins_enabled_for(
            Some("true"),
            Some("production"),
            Some("dev-only")
        ));
        assert!(!native_plugins_enabled_for(
            Some("1"),
            None,
            Some("dev-only")
        ));
        assert!(!native_plugins_enabled_for(
            Some("1"),
            Some("development"),
            None
        ));
        assert!(!native_plugins_enabled_for(
            Some("0"),
            Some("development"),
            Some("dev-only")
        ));
        assert!(native_plugins_enabled_for(
            Some("1"),
            Some("development"),
            Some("dev-only")
        ));
        assert!(native_plugins_enabled_for(
            Some("1"),
            Some("local"),
            Some("trusted-dev")
        ));
    }
}
