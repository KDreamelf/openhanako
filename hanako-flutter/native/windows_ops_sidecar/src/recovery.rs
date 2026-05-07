use crate::cuda_driver::CudaBackend;
use anyhow::{Context, Result, bail};
use k256::SecretKey;
use k256::elliptic_curve::sec1::ToEncodedPoint;
use pbkdf2::pbkdf2_hmac;
use rayon::prelude::*;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256, Sha512};
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const MNEMONIC_LEN: usize = 12;
const ENTROPY_BYTES: usize = 16;
const PBKDF2_ROUNDS: u32 = 2048;
const CUDA_BATCH_SIZE: usize = 8192;
const PROGRESS_EMIT_INTERVAL: Duration = Duration::from_millis(250);

#[derive(Debug, Deserialize)]
struct RecoverySearchRequest {
    matrix: Vec<Vec<u16>>,
    wordlist: Vec<String>,
    target_hashes: Vec<String>,
    #[serde(default = "default_d_max_hard")]
    d_max_hard: usize,
    #[serde(default = "default_deadline_ms")]
    deadline_ms: u64,
    worker_count: Option<usize>,
}

#[derive(Debug, Clone)]
struct FoundSeed {
    ids: Vec<u16>,
    public_key_hex: String,
    public_key_hash: String,
    hamming_distance: usize,
}

#[derive(Debug)]
struct SearchResult {
    backend: String,
    found: Option<FoundSeed>,
    attempted: u64,
    elapsed_ms: u128,
    hamming_distance: usize,
    timed_out: bool,
}

pub fn status_request(_params: &Value) -> Result<Value> {
    let cuda = CudaBackend::status();
    Ok(json!({
        "available": true,
        "backend": if cuda.available { "cuda" } else { "rust_cpu" },
        "gpu": {
            "available": cuda.available,
            "reason": cuda.reason,
            "device": cuda.device_name,
            "compute_capability": cuda.compute_capability,
            "driver_version": cuda.driver_version
        }
    }))
}

pub fn search_request<F>(params: &Value, on_progress: &mut F) -> Result<Value>
where
    F: FnMut(Value),
{
    let request: RecoverySearchRequest = serde_json::from_value(params.clone())
        .context("recovery.search 请求参数应为 JSON object")?;
    validate_request(&request)?;
    let _ = request.worker_count;

    let result = if let Ok(result) = search_cuda(&request, on_progress) {
        result
    } else {
        search_cpu(&request, on_progress)
    };

    Ok(json!({
        "backend": result.backend,
        "found": result.found.is_some(),
        "ids": result.found.as_ref().map(|hit| &hit.ids),
        "public_key_hex": result.found.as_ref().map(|hit| &hit.public_key_hex),
        "public_key_hash": result.found.as_ref().map(|hit| &hit.public_key_hash),
        "attempted": result.attempted,
        "elapsed_ms": result.elapsed_ms,
        "hamming_distance": result
            .found
            .as_ref()
            .map(|hit| hit.hamming_distance)
            .unwrap_or(result.hamming_distance),
        "timed_out": result.timed_out,
    }))
}

fn default_d_max_hard() -> usize {
    4
}

fn default_deadline_ms() -> u64 {
    10 * 60 * 1000
}

fn validate_request(request: &RecoverySearchRequest) -> Result<()> {
    if request.matrix.len() != MNEMONIC_LEN {
        bail!("matrix 必须包含 {MNEMONIC_LEN} 列");
    }
    let k = request
        .matrix
        .first()
        .map(|col| col.len())
        .unwrap_or_default();
    if k == 0 {
        bail!("matrix 每列至少需要一个候选");
    }
    for (index, column) in request.matrix.iter().enumerate() {
        if column.len() != k {
            bail!("matrix 第 {index} 列候选数不一致");
        }
        for id in column {
            if usize::from(*id) >= request.wordlist.len() {
                bail!("matrix 中的词 ID 超出 wordlist 范围: {id}");
            }
        }
    }
    if request.target_hashes.is_empty() {
        bail!("target_hashes 不能为空");
    }
    if request.wordlist.len() < 2048 {
        bail!("wordlist 长度不足 2048");
    }
    Ok(())
}

fn search_cuda<F>(request: &RecoverySearchRequest, on_progress: &mut F) -> Result<SearchResult>
where
    F: FnMut(Value),
{
    let backend = CudaBackend::new()?;
    let started = Instant::now();
    let mut progress = ProgressReporter::new(&started, on_progress);
    let deadline = Duration::from_millis(request.deadline_ms);
    let k = request.matrix[0].len();
    let base_ids = request
        .matrix
        .iter()
        .map(|column| column[0])
        .collect::<Vec<_>>();
    let target_hashes = request
        .target_hashes
        .iter()
        .map(|hash| hash.to_ascii_lowercase())
        .collect::<HashSet<_>>();

    let mut attempted = 0u64;
    let mut timed_out = false;
    let mut found = None;
    let mut last_distance = 0;
    let mut batch_ids = Vec::<Vec<u16>>::with_capacity(CUDA_BATCH_SIZE);
    let mut batch_mnemonics = Vec::<Vec<u8>>::with_capacity(CUDA_BATCH_SIZE);
    progress.emit(attempted, last_distance, true);

    for d in 0..=request.d_max_hard {
        last_distance = d;
        progress.emit(attempted, last_distance, true);
        if started.elapsed() >= deadline {
            timed_out = true;
            break;
        }

        let c_idx_max = binom(MNEMONIC_LEN, d);
        if c_idx_max == 0 {
            continue;
        }
        let subst_max = pow(k.saturating_sub(1), d);
        if subst_max == 0 {
            continue;
        }

        for c_idx in 0..c_idx_max {
            let cols = combo_at(MNEMONIC_LEN, d, c_idx);
            let mut ids = base_ids.clone();
            for s_idx in 0..subst_max {
                if s_idx % 256 == 0 && started.elapsed() >= deadline {
                    timed_out = true;
                    break;
                }

                ids.copy_from_slice(&base_ids);
                let mut s = s_idx;
                let rank_base = (k - 1) as u64;
                for &column in &cols {
                    let rank = ((s % rank_base) + 1) as usize;
                    ids[column] = request.matrix[column][rank];
                    s /= rank_base;
                }
                attempted += 1;
                progress.emit(attempted, d, false);

                if ids_to_entropy(&ids).is_none() {
                    continue;
                }
                if let Some(bytes) = mnemonic_bytes(&ids, &request.wordlist) {
                    batch_ids.push(ids.clone());
                    batch_mnemonics.push(bytes);
                }
                if batch_ids.len() >= CUDA_BATCH_SIZE {
                    found = flush_cuda_batch(
                        &backend,
                        &target_hashes,
                        d,
                        &mut batch_ids,
                        &mut batch_mnemonics,
                    )?;
                    if found.is_some() {
                        break;
                    }
                    progress.emit(attempted, d, true);
                }
            }
            if timed_out || found.is_some() {
                break;
            }
        }

        if found.is_none() && !batch_ids.is_empty() {
            found = flush_cuda_batch(
                &backend,
                &target_hashes,
                d,
                &mut batch_ids,
                &mut batch_mnemonics,
            )?;
            progress.emit(attempted, d, true);
        }
        if timed_out || found.is_some() {
            break;
        }
    }

    Ok(SearchResult {
        backend: format!(
            "cuda:{}:sm_{}",
            backend.device_name(),
            backend.compute_capability().replace('.', "")
        ),
        found,
        attempted,
        elapsed_ms: started.elapsed().as_millis(),
        hamming_distance: last_distance,
        timed_out,
    })
}

fn flush_cuda_batch(
    backend: &CudaBackend,
    target_hashes: &HashSet<String>,
    hamming_distance: usize,
    batch_ids: &mut Vec<Vec<u16>>,
    batch_mnemonics: &mut Vec<Vec<u8>>,
) -> Result<Option<FoundSeed>> {
    let seeds = backend.pbkdf2_batch(batch_mnemonics)?;
    let hit = batch_ids
        .par_iter()
        .zip(seeds.par_iter())
        .find_map_any(|(ids, seed)| {
            let (public_key_hex, public_key_hash) = derive_public_key_from_seed(seed)?;
            if !target_hashes.contains(&public_key_hash) {
                return None;
            }
            Some(FoundSeed {
                ids: ids.clone(),
                public_key_hex,
                public_key_hash,
                hamming_distance,
            })
        });
    batch_ids.clear();
    batch_mnemonics.clear();
    Ok(hit)
}

fn search_cpu<F>(request: &RecoverySearchRequest, on_progress: &mut F) -> SearchResult
where
    F: FnMut(Value),
{
    let started = Instant::now();
    let mut progress = ProgressReporter::new(&started, on_progress);
    let deadline = Duration::from_millis(request.deadline_ms);
    let k = request.matrix[0].len();
    let base_ids = request
        .matrix
        .iter()
        .map(|column| column[0])
        .collect::<Vec<_>>();
    let target_hashes = request
        .target_hashes
        .iter()
        .map(|hash| hash.to_ascii_lowercase())
        .collect::<HashSet<_>>();

    let attempted = Arc::new(AtomicU64::new(0));
    let timed_out = Arc::new(AtomicBool::new(false));
    let found = Arc::new(Mutex::new(None::<FoundSeed>));
    let mut last_distance = 0;
    progress.emit(0, 0, true);

    for d in 0..=request.d_max_hard {
        last_distance = d;
        progress.emit(attempted.load(Ordering::Relaxed), d, true);
        if started.elapsed() >= deadline {
            timed_out.store(true, Ordering::Relaxed);
            break;
        }

        let c_idx_max = binom(MNEMONIC_LEN, d);
        if c_idx_max == 0 {
            continue;
        }
        let subst_max = pow(k.saturating_sub(1), d);
        if subst_max == 0 {
            continue;
        }

        (0..c_idx_max).into_par_iter().for_each(|c_idx| {
            if timed_out.load(Ordering::Relaxed)
                || found.lock().ok().and_then(|g| g.clone()).is_some()
            {
                return;
            }

            let cols = combo_at(MNEMONIC_LEN, d, c_idx);
            let mut ids = base_ids.clone();

            for s_idx in 0..subst_max {
                if s_idx % 256 == 0 {
                    if started.elapsed() >= deadline {
                        timed_out.store(true, Ordering::Relaxed);
                        return;
                    }
                    if found.lock().ok().and_then(|g| g.clone()).is_some() {
                        return;
                    }
                }

                ids.copy_from_slice(&base_ids);
                let mut s = s_idx;
                let rank_base = (k - 1) as u64;
                for &column in &cols {
                    let rank = ((s % rank_base) + 1) as usize;
                    ids[column] = request.matrix[column][rank];
                    s /= rank_base;
                }
                attempted.fetch_add(1, Ordering::Relaxed);

                if ids_to_entropy(&ids).is_none() {
                    continue;
                }
                let Some(hit) = verify_candidate(&ids, &request.wordlist, &target_hashes, d) else {
                    continue;
                };

                if let Ok(mut guard) = found.lock() {
                    if guard.is_none() {
                        *guard = Some(hit);
                    }
                }
                return;
            }
        });

        if found.lock().ok().and_then(|g| g.clone()).is_some() {
            break;
        }
        if timed_out.load(Ordering::Relaxed) {
            break;
        }
        progress.emit(attempted.load(Ordering::Relaxed), d, true);
    }

    SearchResult {
        backend: "rust_cpu".to_owned(),
        found: found.lock().ok().and_then(|g| g.clone()),
        attempted: attempted.load(Ordering::Relaxed),
        elapsed_ms: started.elapsed().as_millis(),
        hamming_distance: last_distance,
        timed_out: timed_out.load(Ordering::Relaxed),
    }
}

struct ProgressReporter<'a, F>
where
    F: FnMut(Value),
{
    started: &'a Instant,
    last_emit: Instant,
    on_progress: &'a mut F,
}

impl<'a, F> ProgressReporter<'a, F>
where
    F: FnMut(Value),
{
    fn new(started: &'a Instant, on_progress: &'a mut F) -> Self {
        Self {
            started,
            last_emit: Instant::now() - PROGRESS_EMIT_INTERVAL,
            on_progress,
        }
    }

    fn emit(&mut self, attempted: u64, hamming_distance: usize, force: bool) {
        if !force && self.last_emit.elapsed() < PROGRESS_EMIT_INTERVAL {
            return;
        }
        (self.on_progress)(json!({
            "attempted": attempted,
            "elapsed_ms": self.started.elapsed().as_millis(),
            "hamming_distance": hamming_distance,
        }));
        self.last_emit = Instant::now();
    }
}

fn verify_candidate(
    ids: &[u16],
    wordlist: &[String],
    target_hashes: &HashSet<String>,
    hamming_distance: usize,
) -> Option<FoundSeed> {
    let (public_key_hex, public_key_hash) = derive_public_key(ids, wordlist)?;
    if !target_hashes.contains(&public_key_hash) {
        return None;
    }

    Some(FoundSeed {
        ids: ids.to_vec(),
        public_key_hex,
        public_key_hash,
        hamming_distance,
    })
}

fn derive_public_key(ids: &[u16], wordlist: &[String]) -> Option<(String, String)> {
    let mnemonic = ids
        .iter()
        .map(|id| wordlist.get(usize::from(*id)).map(String::as_str))
        .collect::<Option<Vec<_>>>()?
        .join(" ");
    let mut seed = [0u8; 64];
    pbkdf2_hmac::<Sha512>(mnemonic.as_bytes(), b"mnemonic", PBKDF2_ROUNDS, &mut seed);
    derive_public_key_from_seed(&seed)
}

fn derive_public_key_from_seed(seed: &[u8; 64]) -> Option<(String, String)> {
    let secret = SecretKey::from_slice(&seed[..32]).ok()?;
    let public_key = secret.public_key();
    let encoded = public_key.to_encoded_point(false);
    let public_key_bytes = encoded.as_bytes();
    let public_key_hash = hex::encode(Sha256::digest(public_key_bytes));
    Some((hex::encode(public_key_bytes), public_key_hash))
}

fn mnemonic_bytes(ids: &[u16], wordlist: &[String]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(128);
    for (index, id) in ids.iter().enumerate() {
        if index > 0 {
            out.push(b' ');
        }
        out.extend_from_slice(wordlist.get(usize::from(*id))?.as_bytes());
    }
    Some(out)
}

fn ids_to_entropy(ids: &[u16]) -> Option<[u8; ENTROPY_BYTES]> {
    if ids.len() != MNEMONIC_LEN {
        return None;
    }
    let mut entropy = [0u8; ENTROPY_BYTES];
    let mut checksum_expected = 0u8;
    let mut bit_index = 0usize;

    for &id in ids {
        if id >= 2048 {
            return None;
        }
        for shift in (0..11).rev() {
            let bit = ((id >> shift) & 1) as u8;
            if bit_index < ENTROPY_BYTES * 8 {
                if bit == 1 {
                    entropy[bit_index / 8] |= 1 << (7 - bit_index % 8);
                }
            } else {
                checksum_expected = (checksum_expected << 1) | bit;
            }
            bit_index += 1;
        }
    }

    let checksum_actual = Sha256::digest(entropy)[0] >> 4;
    if checksum_expected != checksum_actual {
        return None;
    }
    Some(entropy)
}

fn combo_at(n: usize, k: usize, idx: u64) -> Vec<usize> {
    if k == 0 {
        return Vec::new();
    }
    let mut out = vec![0usize; k];
    let mut c = idx;
    let mut start = 0usize;
    for (i, slot) in out.iter_mut().enumerate() {
        for x in start..n {
            let remaining = binom(n - x - 1, k - i - 1);
            if c < remaining {
                *slot = x;
                start = x + 1;
                break;
            }
            c -= remaining;
        }
    }
    out
}

fn binom(n: usize, k: usize) -> u64 {
    if k > n {
        return 0;
    }
    let kk = k.min(n - k);
    let mut result = 1u64;
    for i in 0..kk {
        result = result * (n - i) as u64 / (i + 1) as u64;
    }
    result
}

fn pow(base: usize, exp: usize) -> u64 {
    let mut result = 1u64;
    for _ in 0..exp {
        result *= base as u64;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_search_finds_rank_zero_seed() {
        let wordlist = test_wordlist();
        let ids = first_valid_ids();
        let (_, public_key_hash) =
            derive_public_key(&ids, &wordlist).expect("test ids should derive a public key");
        let request = RecoverySearchRequest {
            matrix: ids.iter().map(|id| vec![*id]).collect(),
            wordlist,
            target_hashes: vec![public_key_hash],
            d_max_hard: 0,
            deadline_ms: 30_000,
            worker_count: Some(1),
        };

        let mut noop = |_| {};
        let result = search_cpu(&request, &mut noop);

        let hit = result.found.expect("rank-0 matrix should be found");
        assert_eq!(hit.ids, ids);
        assert_eq!(hit.hamming_distance, 0);
        assert!(!result.timed_out);
    }

    #[test]
    fn recovery_search_finds_rank_one_seed_at_distance_two() {
        let wordlist = test_wordlist();
        let ids = first_valid_ids();
        let (_, public_key_hash) =
            derive_public_key(&ids, &wordlist).expect("test ids should derive a public key");
        let matrix = ids
            .iter()
            .enumerate()
            .map(|(index, id)| {
                if index == 0 || index == 5 {
                    vec![(*id + 1) % 2048, *id]
                } else {
                    vec![*id, (*id + 1) % 2048]
                }
            })
            .collect();
        let request = RecoverySearchRequest {
            matrix,
            wordlist,
            target_hashes: vec![public_key_hash],
            d_max_hard: 2,
            deadline_ms: 30_000,
            worker_count: Some(2),
        };

        let mut noop = |_| {};
        let result = search_cpu(&request, &mut noop);

        let hit = result.found.expect("D=2 matrix should be found");
        assert_eq!(hit.ids, ids);
        assert_eq!(hit.hamming_distance, 2);
        assert!(!result.timed_out);
    }

    #[test]
    fn recovery_search_reports_progress() {
        let wordlist = test_wordlist();
        let ids = first_valid_ids();
        let matrix = ids
            .iter()
            .map(|id| vec![*id, (*id + 1) % 2048, (*id + 2) % 2048])
            .collect();
        let request = RecoverySearchRequest {
            matrix,
            wordlist,
            target_hashes: vec![
                "0000000000000000000000000000000000000000000000000000000000000000".to_string(),
            ],
            d_max_hard: 2,
            deadline_ms: 30_000,
            worker_count: Some(2),
        };

        let mut progress_count = 0usize;
        let result = search_cpu(&request, &mut |_| {
            progress_count += 1;
        });

        assert!(result.found.is_none());
        assert!(progress_count > 0);
    }

    #[test]
    fn cuda_recovery_search_reports_progress_when_available() {
        if !CudaBackend::status().available {
            return;
        }
        let wordlist = test_wordlist();
        let ids = first_valid_ids();
        let matrix = ids
            .iter()
            .map(|id| vec![*id, (*id + 1) % 2048, (*id + 2) % 2048])
            .collect();
        let request = RecoverySearchRequest {
            matrix,
            wordlist,
            target_hashes: vec![
                "0000000000000000000000000000000000000000000000000000000000000000".to_string(),
            ],
            d_max_hard: 2,
            deadline_ms: 30_000,
            worker_count: Some(2),
        };

        let mut progress_count = 0usize;
        let result = search_cuda(&request, &mut |_| {
            progress_count += 1;
        })
        .expect("cuda search should run when status is available");

        assert!(result.found.is_none());
        assert!(progress_count > 0);
    }

    #[test]
    fn recovery_search_request_reports_progress() {
        let wordlist = test_wordlist();
        let ids = first_valid_ids();
        let matrix = ids
            .iter()
            .map(|id| vec![*id, (*id + 1) % 2048, (*id + 2) % 2048])
            .collect::<Vec<_>>();
        let params = json!({
            "matrix": matrix,
            "wordlist": wordlist,
            "target_hashes": [
                "0000000000000000000000000000000000000000000000000000000000000000"
            ],
            "d_max_hard": 2,
            "deadline_ms": 30_000
        });

        let mut progress_count = 0usize;
        let result = search_request(&params, &mut |_| {
            progress_count += 1;
        })
        .expect("search request should run");

        assert_eq!(result["found"], false);
        assert!(progress_count > 0);
    }

    fn test_wordlist() -> Vec<String> {
        (0..2048).map(|index| format!("词{index}")).collect()
    }

    fn first_valid_ids() -> Vec<u16> {
        let mut ids = vec![0u16; MNEMONIC_LEN];
        for id in 0..2048 {
            ids[MNEMONIC_LEN - 1] = id;
            if ids_to_entropy(&ids).is_some() {
                return ids;
            }
        }
        panic!("expected at least one valid checksum id");
    }
}
