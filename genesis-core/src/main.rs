// genesis-core/src/main.rs
mod act;
mod audit;
mod hot_reload;
mod kernel;
mod sense;
mod verify;
mod watchdog;
use audit::{AuditEvent, AuditLogger};
use kernel::GenesisKernel;
use std::collections::HashMap;
use std::fs;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const GENESIS_ALLOW_NATIVE_PLUGINS: &str = "GENESIS_ALLOW_NATIVE_PLUGINS";

fn main() {
    println!("🌌 创世纪微核 (Genesis Core) - 永不停机版本启动...");
    let auditor = AuditLogger::new(4096);
    let kernel = Arc::new(Mutex::new(GenesisKernel::new(auditor.clone())));
    let k = kernel.clone();

    // 锁定绝对物理坐标
    let current_dir = std::env::current_dir().unwrap();
    let watch_path = current_dir.join("genesis-plugins");
    let watch_path_str = watch_path.to_str().unwrap().to_string();

    println!("[微核] 🔍 正在锁定绝对物理坐标: {}", watch_path_str);

    let allow_native_plugins = native_plugins_enabled();
    if !allow_native_plugins {
        println!(
            "[微核] 🔒 原生 .so/.dylib 插件默认禁用；设置 {}=1 才会加载可信插件。",
            GENESIS_ALLOW_NATIVE_PLUGINS
        );
    }

    // 启动全知之眼
    let mut last_reload_at: HashMap<String, Instant> = HashMap::new();
    if allow_native_plugins {
        hot_reload::start_watcher(&watch_path_str, move |path| {
            if path.ends_with(".dylib") || path.ends_with(".so") {
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

    let plugin_entries = if allow_native_plugins {
        fs::read_dir(&watch_path).ok()
    } else {
        None
    };
    if let Some(entries) = plugin_entries {
        let mut plugin_paths = entries
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| ext == "dylib" || ext == "so")
            })
            .collect::<Vec<_>>();
        plugin_paths.sort();

        let mut guard = kernel.lock().unwrap();
        for plugin_path in plugin_paths {
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
        println!("\n🫀 [微核脉冲] 正在向插件发射: {}", payload);

        guard.trigger_all(tick, &payload);
    }
}

fn native_plugins_enabled() -> bool {
    parse_native_plugin_flag(std::env::var(GENESIS_ALLOW_NATIVE_PLUGINS).ok().as_deref())
}

fn parse_native_plugin_flag(value: Option<&str>) -> bool {
    matches!(
        value.map(str::trim),
        Some("1") | Some("true") | Some("TRUE") | Some("yes") | Some("YES")
    )
}

#[cfg(test)]
mod tests {
    use super::parse_native_plugin_flag;

    #[test]
    fn native_plugin_loading_is_opt_in() {
        assert!(!parse_native_plugin_flag(None));
        assert!(!parse_native_plugin_flag(Some("0")));
        assert!(!parse_native_plugin_flag(Some("false")));
        assert!(parse_native_plugin_flag(Some("1")));
        assert!(parse_native_plugin_flag(Some("true")));
        assert!(parse_native_plugin_flag(Some(" yes ")));
    }
}
