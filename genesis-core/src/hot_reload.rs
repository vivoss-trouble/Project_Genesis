// genesis-core/src/hot_reload.rs
use notify::{RecursiveMode, Result, Watcher};
use std::path::Path;
use std::sync::mpsc::channel;

pub fn start_watcher<F>(path: &str, mut callback: F) -> Result<()>
where
    F: FnMut(&str) + Send + 'static,
{
    let (tx, rx) = channel();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(event) = res {
            println!("[底层雷达] ⚡ 捕捉到系统底层事件: {:?}", event.kind);

            for p in event.paths {
                if let Some(s) = p.to_str() {
                    tx.send(s.to_string()).unwrap();
                }
            }
        }
    })?;

    watcher.watch(Path::new(path), RecursiveMode::Recursive)?;

    // 🧙‍♀️ 终极黑魔法：献祭给内存，加上永生之锁！
    // 告诉 Rust 死神：“这个对象归宇宙管了，你不许碰！”
    Box::leak(Box::new(watcher));

    std::thread::spawn(move || {
        for path in rx {
            callback(&path);
        }
    });
    Ok(())
}
