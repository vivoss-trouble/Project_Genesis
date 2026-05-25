use genesis_contracts::declare_genesis_plugin;
use genesis_contracts::sdk::{GenesisContext, GenesisPlugin, GenesisResult};
use genesis_contracts::wire::GENESIS_ERROR_INTERNAL;
use memmap2::{MmapMut, MmapOptions};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::sync::Mutex;

const FILE_MAGIC: &[u8; 4] = b"GEN1";
const BLOCK_MAGIC: &[u8; 4] = b"BLK1";
const HEADER_SIZE: usize = 8;
const BLOCK_HEADER_SIZE: usize = 16;
const BLOCK_SIZE: usize = 1024 * 1024;
const MMAP_SIZE: usize = HEADER_SIZE + BLOCK_SIZE * 2;
const STATE_DIR: &str = ".genesis-state";
const STATE_FILE: &str = ".genesis-state/anchor.mmap";

#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct KernelState {
    pub tick_count: u64,
    pub last_timestamp: u64,
    pub entropy_level: f64,
    pub recent_payload: String,
}

pub struct AnchorPlugin {
    mmap_handle: Mutex<MmapMut>,
}

impl AnchorPlugin {
    pub fn new() -> Self {
        fs::create_dir_all(STATE_DIR).expect("failed to create genesis state directory");

        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(STATE_FILE)
            .expect("failed to open anchor mmap file");

        if file.metadata().expect("failed to stat anchor mmap").len() < MMAP_SIZE as u64 {
            file.set_len(MMAP_SIZE as u64)
                .expect("failed to preallocate anchor mmap");
        }

        let mut mmap = unsafe {
            MmapOptions::new()
                .map_mut(&file)
                .expect("failed to map anchor mmap")
        };

        if &mmap[0..4] != FILE_MAGIC {
            mmap[0..4].copy_from_slice(FILE_MAGIC);
            mmap[4] = 0;
            mmap[5..HEADER_SIZE].fill(0);
            initialize_empty_block(&mut mmap, 0);
            initialize_empty_block(&mut mmap, 1);
            mmap.flush().expect("failed to flush anchor mmap header");
        }

        Self {
            mmap_handle: Mutex::new(mmap),
        }
    }

    fn block_offset(index: u8) -> usize {
        HEADER_SIZE + (index as usize * BLOCK_SIZE)
    }

    fn read_state(mmap: &MmapMut, block_idx: u8) -> Option<KernelState> {
        let offset = Self::block_offset(block_idx);
        if &mmap[offset..offset + 4] != BLOCK_MAGIC {
            return None;
        }

        let data_len = read_u32(mmap, offset + 4) as usize;
        let checksum = read_u64(mmap, offset + 8);
        if data_len == 0 || data_len > BLOCK_SIZE - BLOCK_HEADER_SIZE {
            return None;
        }

        let data_start = offset + BLOCK_HEADER_SIZE;
        let data_end = data_start + data_len;
        let json_bytes = &mmap[data_start..data_end];
        if fnv1a64(json_bytes) != checksum {
            return None;
        }

        serde_json::from_slice(json_bytes).ok()
    }

    fn write_state(mmap: &mut MmapMut, block_idx: u8, state: &KernelState) -> Result<(), String> {
        let json_bytes = serde_json::to_vec(state).map_err(|err| err.to_string())?;
        if json_bytes.len() > BLOCK_SIZE - BLOCK_HEADER_SIZE {
            return Err("state too large".to_string());
        }

        let offset = Self::block_offset(block_idx);
        mmap[offset..offset + 4].copy_from_slice(BLOCK_MAGIC);
        mmap[offset + 4..offset + 8].copy_from_slice(&(json_bytes.len() as u32).to_le_bytes());
        mmap[offset + 8..offset + 16].copy_from_slice(&fnv1a64(&json_bytes).to_le_bytes());
        mmap[offset + BLOCK_HEADER_SIZE..offset + BLOCK_HEADER_SIZE + json_bytes.len()]
            .copy_from_slice(&json_bytes);

        Ok(())
    }
}

impl GenesisPlugin for AnchorPlugin {
    fn name(&self) -> &'static str {
        "anchor-mmap"
    }

    fn on_event(&self, ctx: GenesisContext, payload: &[u8]) -> GenesisResult {
        let mut mmap = self.mmap_handle.lock().expect("anchor mmap mutex poisoned");
        let active_idx = mmap[4];
        if active_idx > 1 {
            panic!("invalid active mmap block index");
        }

        let mut state = Self::read_state(&mmap, active_idx)
            .or_else(|| Self::read_state(&mmap, 1 - active_idx))
            .unwrap_or_default();

        state.tick_count += 1;
        state.last_timestamp = ctx.timestamp_ms;
        state.recent_payload = String::from_utf8_lossy(payload).into_owned();
        if state.tick_count % 10 == 0 {
            state.entropy_level -= 1.0;
        } else {
            state.entropy_level += 0.2;
        }

        let target_idx = 1 - active_idx;
        if let Err(err) = Self::write_state(&mut mmap, target_idx, &state) {
            return GenesisResult::error(GENESIS_ERROR_INTERNAL, err.into_bytes());
        }

        mmap[4] = target_idx;
        let _ = mmap.flush_async();

        GenesisResult::ok(
            format!(
                "[Anchor] State locked. Tick: {}, Entropy: {:.2}, ActiveBlock: {}",
                state.tick_count, state.entropy_level, target_idx
            )
            .into_bytes(),
        )
    }
}

fn initialize_empty_block(mmap: &mut MmapMut, block_idx: u8) {
    let state = KernelState::default();
    let _ = AnchorPlugin::write_state(mmap, block_idx, &state);
}

fn read_u32(mmap: &MmapMut, offset: usize) -> u32 {
    let mut bytes = [0u8; 4];
    bytes.copy_from_slice(&mmap[offset..offset + 4]);
    u32::from_le_bytes(bytes)
}

fn read_u64(mmap: &MmapMut, offset: usize) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&mmap[offset..offset + 8]);
    u64::from_le_bytes(bytes)
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in bytes {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

declare_genesis_plugin!(AnchorPlugin, AnchorPlugin::new);
