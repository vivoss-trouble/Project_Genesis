use lazarus_breakwater::StateSnapshot;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct JavaMethodSource {
    pub method_tag: String,
    pub source: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MethodCorpus {
    pub method_tag: String,
    pub legacy_source: String,
    pub snapshots: Vec<StateSnapshot>,
}

pub fn correlate_snapshots_by_trace_tag(
    sources: &[JavaMethodSource],
    snapshots: &[StateSnapshot],
) -> BTreeMap<String, MethodCorpus> {
    let source_by_tag = sources
        .iter()
        .map(|source| (source.method_tag.clone(), source.source.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut corpora = BTreeMap::new();
    for snapshot in snapshots {
        let Some(method_tag) = snapshot.trace_tags.get("business_method") else {
            continue;
        };
        let Some(source) = source_by_tag.get(method_tag) else {
            continue;
        };
        corpora
            .entry(method_tag.clone())
            .or_insert_with(|| MethodCorpus {
                method_tag: method_tag.clone(),
                legacy_source: source.clone(),
                snapshots: Vec::new(),
            })
            .snapshots
            .push(snapshot.clone());
    }
    corpora
}
