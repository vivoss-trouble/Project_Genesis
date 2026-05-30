use crate::hash::stable_hash_bytes;
use crate::types::{BehaviorCase, SynthesisInput};
use lazarus_breakwater::StateSnapshot;
use serde::Serialize;

pub(crate) struct CorpusPlan {
    pub(crate) visible_state_snapshots: Vec<StateSnapshot>,
    pub(crate) training_cases: Vec<BehaviorCase>,
    pub(crate) blind_cases: Vec<BehaviorCase>,
}

pub(crate) fn split_corpus(
    input: &SynthesisInput,
    training_percent: u8,
) -> Result<CorpusPlan, String> {
    let visible_state_snapshots = split_items(&input.state_snapshots, training_percent)?
        .0
        .into_iter()
        .cloned()
        .collect();
    let (training_cases, blind_cases) = split_items(&input.behavior_cases, training_percent)?;
    Ok(CorpusPlan {
        visible_state_snapshots,
        training_cases: training_cases.into_iter().cloned().collect(),
        blind_cases: blind_cases.into_iter().cloned().collect(),
    })
}

fn split_items<T: Serialize>(
    items: &[T],
    training_percent: u8,
) -> Result<(Vec<&T>, Vec<&T>), String> {
    if items.is_empty() {
        return Ok((Vec::new(), Vec::new()));
    }
    let mut indexed = items
        .iter()
        .map(|item| {
            serde_json::to_vec(item)
                .map(|bytes| (stable_hash_bytes(&bytes), item))
                .map_err(|error| error.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    indexed.sort_by(|left, right| left.0.cmp(&right.0));
    let mut training_count = (indexed.len() * training_percent as usize).div_ceil(100);
    if training_count == 0 && !indexed.is_empty() {
        training_count = 1;
    }
    if indexed.len() > 1 && training_count >= indexed.len() {
        training_count = indexed.len() - 1;
    }
    let training = indexed
        .iter()
        .take(training_count)
        .map(|(_, item)| *item)
        .collect();
    let blind = indexed
        .iter()
        .skip(training_count)
        .map(|(_, item)| *item)
        .collect();
    Ok((training, blind))
}
