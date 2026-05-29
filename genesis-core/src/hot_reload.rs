// genesis-core/src/hot_reload.rs
use notify::{RecursiveMode, Result, Watcher};
use std::path::Path;
use std::sync::mpsc::channel;


/// 监控指定目录下的文件变化，触发回调。
/// 
/// # Box::leak 设计决策
/// watcher 通过 leak 获得 "永生"——它独立于任何 RAII 所有权存在。
/// 在单实例场景中这是合理的（watcher 与进程同生命周期）；
/// 如果需要多实例/可回收，应改为 Arc<RefCell<Watcher>> + 手动 drop。
pub fn start_watcher<F>(path: &str, mut callback: F) -> Result<()>
where
    F: FnMut(&str) + Send + 'static,
{
    let (tx, rx) = channel();
    let path_owned = path.to_string();

    // 使用 unwrap_or_else 替代 unwrap，防止接收端退出时 panic。
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(event) = res {
            println!("[底层雷达] ⚡ 捕捉到系统底层事件: {:?}", event.kind);

            for p in event.paths {
                if let Some(s) = p.to_str() {
                    // unwrap_or_else: tx.send 失败时（接收端退出），静默丢弃而非 panic。
                    if tx.send(s.to_string()).is_err() {
                        println!("[底层雷达] 🚫 watcher → callback channel closed, stopping.");
                        return;
                    }
                }
            }
        }
    })?;

    watcher.watch(Path::new(&path_owned), RecursiveMode::Recursive)?;

    // 设计选择：leak watcher，让它与进程同生命周期。
    let _watcher_ptr = Box::leak(Box::new(watcher));

    std::thread::spawn(move || {
        for path in rx {
            callback(&path);
        }
    });
    Ok(())
}
