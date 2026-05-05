import argparse
import hashlib
import json
import math
import os
import statistics
import time
from dataclasses import dataclass
from pathlib import Path

import coincurve
import numpy as np
import pyopencl as cl


KERNEL = r"""
#pragma OPENCL EXTENSION cl_khr_int64 : enable

typedef ulong u64;
typedef uchar u8;

__constant u64 K512[80] = {
  0x428a2f98d728ae22UL, 0x7137449123ef65cdUL, 0xb5c0fbcfec4d3b2fUL, 0xe9b5dba58189dbbcUL,
  0x3956c25bf348b538UL, 0x59f111f1b605d019UL, 0x923f82a4af194f9bUL, 0xab1c5ed5da6d8118UL,
  0xd807aa98a3030242UL, 0x12835b0145706fbeUL, 0x243185be4ee4b28cUL, 0x550c7dc3d5ffb4e2UL,
  0x72be5d74f27b896fUL, 0x80deb1fe3b1696b1UL, 0x9bdc06a725c71235UL, 0xc19bf174cf692694UL,
  0xe49b69c19ef14ad2UL, 0xefbe4786384f25e3UL, 0x0fc19dc68b8cd5b5UL, 0x240ca1cc77ac9c65UL,
  0x2de92c6f592b0275UL, 0x4a7484aa6ea6e483UL, 0x5cb0a9dcbd41fbd4UL, 0x76f988da831153b5UL,
  0x983e5152ee66dfabUL, 0xa831c66d2db43210UL, 0xb00327c898fb213fUL, 0xbf597fc7beef0ee4UL,
  0xc6e00bf33da88fc2UL, 0xd5a79147930aa725UL, 0x06ca6351e003826fUL, 0x142929670a0e6e70UL,
  0x27b70a8546d22ffcUL, 0x2e1b21385c26c926UL, 0x4d2c6dfc5ac42aedUL, 0x53380d139d95b3dfUL,
  0x650a73548baf63deUL, 0x766a0abb3c77b2a8UL, 0x81c2c92e47edaee6UL, 0x92722c851482353bUL,
  0xa2bfe8a14cf10364UL, 0xa81a664bbc423001UL, 0xc24b8b70d0f89791UL, 0xc76c51a30654be30UL,
  0xd192e819d6ef5218UL, 0xd69906245565a910UL, 0xf40e35855771202aUL, 0x106aa07032bbd1b8UL,
  0x19a4c116b8d2d0c8UL, 0x1e376c085141ab53UL, 0x2748774cdf8eeb99UL, 0x34b0bcb5e19b48a8UL,
  0x391c0cb3c5c95a63UL, 0x4ed8aa4ae3418acbUL, 0x5b9cca4f7763e373UL, 0x682e6ff3d6b2b8a3UL,
  0x748f82ee5defb2fcUL, 0x78a5636f43172f60UL, 0x84c87814a1f0ab72UL, 0x8cc702081a6439ecUL,
  0x90befffa23631e28UL, 0xa4506cebde82bde9UL, 0xbef9a3f7b2c67915UL, 0xc67178f2e372532bUL,
  0xca273eceea26619cUL, 0xd186b8c721c0c207UL, 0xeada7dd6cde0eb1eUL, 0xf57d4f7fee6ed178UL,
  0x06f067aa72176fbaUL, 0x0a637dc5a2c898a6UL, 0x113f9804bef90daeUL, 0x1b710b35131c471bUL,
  0x28db77f523047d84UL, 0x32caab7b40c72493UL, 0x3c9ebe0a15c9bebcUL, 0x431d67c49c100d4cUL,
  0x4cc5d4becb3e42b6UL, 0x597f299cfc657e2aUL, 0x5fcb6fab3ad6faecUL, 0x6c44198c4a475817UL
};

u64 rotr64(u64 x, uint n) {
  return (x >> n) | (x << (64 - n));
}

u64 load_be64(__private const u8 *p) {
  return ((u64)p[0] << 56) | ((u64)p[1] << 48) | ((u64)p[2] << 40) | ((u64)p[3] << 32) |
         ((u64)p[4] << 24) | ((u64)p[5] << 16) | ((u64)p[6] << 8) | (u64)p[7];
}

void store_be64(__private u8 *p, u64 x) {
  p[0] = (u8)(x >> 56);
  p[1] = (u8)(x >> 48);
  p[2] = (u8)(x >> 40);
  p[3] = (u8)(x >> 32);
  p[4] = (u8)(x >> 24);
  p[5] = (u8)(x >> 16);
  p[6] = (u8)(x >> 8);
  p[7] = (u8)x;
}

void sha512_compress(__private u64 h[8], __private const u8 block[128]) {
  u64 w[80];
  for (uint i = 0; i < 16; i++) {
    w[i] = load_be64(block + i * 8);
  }
  for (uint i = 16; i < 80; i++) {
    u64 s0 = rotr64(w[i - 15], 1) ^ rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7);
    u64 s1 = rotr64(w[i - 2], 19) ^ rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }

  u64 a = h[0];
  u64 b = h[1];
  u64 c = h[2];
  u64 d = h[3];
  u64 e = h[4];
  u64 f = h[5];
  u64 g = h[6];
  u64 hh = h[7];

  for (uint i = 0; i < 80; i++) {
    u64 s1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41);
    u64 ch = (e & f) ^ ((~e) & g);
    u64 temp1 = hh + s1 + ch + K512[i] + w[i];
    u64 s0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39);
    u64 maj = (a & b) ^ (a & c) ^ (b & c);
    u64 temp2 = s0 + maj;
    hh = g;
    g = f;
    f = e;
    e = d + temp1;
    d = c;
    c = b;
    b = a;
    a = temp1 + temp2;
  }

  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
  h[5] += f;
  h[6] += g;
  h[7] += hh;
}

void sha512_hash(__private const u8 *msg, uint len, __private u64 out[8]) {
  u64 h[8] = {
    0x6a09e667f3bcc908UL, 0xbb67ae8584caa73bUL,
    0x3c6ef372fe94f82bUL, 0xa54ff53a5f1d36f1UL,
    0x510e527fade682d1UL, 0x9b05688c2b3e6c1fUL,
    0x1f83d9abfb41bd6bUL, 0x5be0cd19137e2179UL
  };

  uint pos = 0;
  while (len - pos >= 128) {
    sha512_compress(h, msg + pos);
    pos += 128;
  }

  u8 block[128];
  for (uint i = 0; i < 128; i++) block[i] = 0;
  uint rem = len - pos;
  for (uint i = 0; i < rem; i++) block[i] = msg[pos + i];
  block[rem] = 0x80;

  if (rem >= 112) {
    sha512_compress(h, block);
    for (uint i = 0; i < 128; i++) block[i] = 0;
  }

  u64 bit_len = (u64)len * 8UL;
  store_be64(block + 112, 0UL);
  store_be64(block + 120, bit_len);
  sha512_compress(h, block);

  for (uint i = 0; i < 8; i++) out[i] = h[i];
}

void digest_words_to_bytes(__private const u64 words[8], __private u8 out[64]) {
  for (uint i = 0; i < 8; i++) store_be64(out + i * 8, words[i]);
}

void hmac_sha512(
  __private const u8 *key,
  uint key_len,
  __private const u8 *data,
  uint data_len,
  __private u8 out[64]
) {
  u8 k0[128];
  for (uint i = 0; i < 128; i++) k0[i] = 0;

  if (key_len > 128) {
    u64 key_digest[8];
    sha512_hash(key, key_len, key_digest);
    for (uint i = 0; i < 8; i++) store_be64(k0 + i * 8, key_digest[i]);
  } else {
    for (uint i = 0; i < key_len; i++) k0[i] = key[i];
  }

  u8 msg[256];
  for (uint i = 0; i < 128; i++) msg[i] = k0[i] ^ 0x36;
  for (uint i = 0; i < data_len; i++) msg[128 + i] = data[i];

  u64 inner_words[8];
  sha512_hash(msg, 128 + data_len, inner_words);

  for (uint i = 0; i < 128; i++) msg[i] = k0[i] ^ 0x5c;
  for (uint i = 0; i < 8; i++) store_be64(msg + 128 + i * 8, inner_words[i]);

  u64 outer_words[8];
  sha512_hash(msg, 192, outer_words);
  digest_words_to_bytes(outer_words, out);
}

__kernel void pbkdf2_hmac_sha512_bench(
  __global const u8 *base_password,
  uint base_password_len,
  ulong nonce_offset,
  uint varied_input,
  __global ulong *out
) {
  size_t gid = get_global_id(0);
  u8 key[160];
  for (uint i = 0; i < base_password_len; i++) key[i] = base_password[i];

  uint key_len = base_password_len;
  if (varied_input != 0) {
    ulong nonce = nonce_offset + (ulong)gid;
    for (uint i = 0; i < 8; i++) {
      key[base_password_len + i] = (u8)(nonce >> (56 - i * 8));
    }
    key_len = base_password_len + 8;
  }

  u8 salt_block[12] = {
    (u8)'m', (u8)'n', (u8)'e', (u8)'m', (u8)'o', (u8)'n',
    (u8)'i', (u8)'c', 0, 0, 0, 1
  };

  u8 u[64];
  u8 t[64];
  hmac_sha512(key, key_len, salt_block, 12, u);
  for (uint i = 0; i < 64; i++) t[i] = u[i];

  for (uint iter = 1; iter < 2048; iter++) {
    hmac_sha512(key, key_len, u, 64, u);
    for (uint i = 0; i < 64; i++) t[i] ^= u[i];
  }

  out[gid] = load_be64(t);
}
"""


DEFAULT_PASSWORD = "海洋 桥梁 星星 花园 火山 纸张 蜡烛 钥匙 月亮 森林 钟表 雨伞"


@dataclass
class RunStats:
    batch_size: int
    seconds: float
    batches: int
    pbkdf2_total: int
    pbkdf2_per_second: float
    matrix_candidates_per_second: float
    matrix_candidates_total: float
    samples_per_batch: list[float]


def first_gpu_device() -> tuple[cl.Platform, cl.Device]:
    devices: list[tuple[cl.Platform, cl.Device]] = []
    for platform in cl.get_platforms():
        for device in platform.get_devices():
            if device.type & cl.device_type.GPU:
                devices.append((platform, device))
    if not devices:
        raise RuntimeError("没有找到 OpenCL GPU 设备。")
    nvidia = [pair for pair in devices if "nvidia" in pair[1].name.lower()]
    return nvidia[0] if nvidia else devices[0]


def build_program(context: cl.Context) -> cl.Program:
    return cl.Program(context, KERNEL).build()


def validate_kernel(queue: cl.CommandQueue, kernel: cl.Kernel, password: bytes) -> None:
    ctx = queue.context
    mf = cl.mem_flags
    password_buf = cl.Buffer(ctx, mf.READ_ONLY | mf.COPY_HOST_PTR, hostbuf=np.frombuffer(password, dtype=np.uint8))
    out = np.zeros(1, dtype=np.uint64)
    out_buf = cl.Buffer(ctx, mf.WRITE_ONLY, out.nbytes)

    kernel(
        queue,
        (1,),
        None,
        password_buf,
        np.uint32(len(password)),
        np.uint64(0),
        np.uint32(0),
        out_buf,
    )
    cl.enqueue_copy(queue, out, out_buf).wait()
    expected = int.from_bytes(hashlib.pbkdf2_hmac("sha512", password, b"mnemonic", 2048, 64)[:8], "big")
    actual = int(out[0])
    if actual != expected:
        raise RuntimeError(f"OpenCL PBKDF2 校验失败：actual={actual:016x}, expected={expected:016x}")


def calibrate_batch(
    queue: cl.CommandQueue,
    kernel: cl.Kernel,
    password_buf: cl.Buffer,
    password_len: int,
    out_buf: cl.Buffer,
    max_batch_size: int,
    varied_input: bool,
) -> int:
    candidates = [512, 1024, 2048, 4096, 8192, 16384, 32768]
    candidates = [c for c in candidates if c <= max_batch_size]
    best_size = candidates[0]
    best_rate = 0.0
    for batch_size in candidates:
        start = time.perf_counter()
        event = kernel(
            queue,
            (batch_size,),
            None,
            password_buf,
            np.uint32(password_len),
            np.uint64(0),
            np.uint32(1 if varied_input else 0),
            out_buf,
        )
        event.wait()
        elapsed = time.perf_counter() - start
        rate = batch_size / elapsed
        if rate > best_rate:
            best_rate = rate
            best_size = batch_size
    return best_size


def run_gpu_benchmark(seconds: int, batch_size: int | None, varied_input: bool, password: bytes) -> tuple[dict, RunStats]:
    platform, device = first_gpu_device()
    ctx = cl.Context([device])
    queue = cl.CommandQueue(ctx)
    program = build_program(ctx)
    kernel = cl.Kernel(program, "pbkdf2_hmac_sha512_bench")
    validate_kernel(queue, kernel, password)

    mf = cl.mem_flags
    password_buf = cl.Buffer(ctx, mf.READ_ONLY | mf.COPY_HOST_PTR, hostbuf=np.frombuffer(password, dtype=np.uint8))
    max_batch_size = 32768
    out_buf = cl.Buffer(ctx, mf.WRITE_ONLY, np.zeros(max_batch_size, dtype=np.uint64).nbytes)

    if batch_size is None:
        batch_size = calibrate_batch(queue, kernel, password_buf, len(password), out_buf, max_batch_size, varied_input)

    # Warm up the GPU and clocks.
    for i in range(3):
        kernel(
            queue,
            (batch_size,),
            None,
            password_buf,
            np.uint32(len(password)),
            np.uint64(i * batch_size),
            np.uint32(1 if varied_input else 0),
            out_buf,
        ).wait()

    started = time.perf_counter()
    deadline = started + seconds
    batches = 0
    sample_rates: list[float] = []
    nonce = 0

    while time.perf_counter() < deadline:
        batch_started = time.perf_counter()
        kernel(
            queue,
            (batch_size,),
            None,
            password_buf,
            np.uint32(len(password)),
            np.uint64(nonce),
            np.uint32(1 if varied_input else 0),
            out_buf,
        ).wait()
        elapsed = time.perf_counter() - batch_started
        sample_rates.append(batch_size / elapsed)
        batches += 1
        nonce += batch_size

    total_seconds = time.perf_counter() - started
    total_pbkdf2 = batches * batch_size
    pbkdf2_per_second = total_pbkdf2 / total_seconds

    # BIP-39 12词助记词 checksum 通过率约 1/16。GPU PBKDF2 吞吐换算到矩阵枚举：
    # 每 16 个矩阵组合平均只有 1 个进入 PBKDF2 慢路径。
    matrix_per_second = pbkdf2_per_second * 16.0

    device_info = {
        "platform": platform.name,
        "platform_version": platform.version,
        "device": device.name,
        "driver_version": device.driver_version,
        "opencl_c_version": device.opencl_c_version,
        "compute_units": device.max_compute_units,
        "global_mem_mib": device.global_mem_size // (1024 * 1024),
        "max_work_group_size": device.max_work_group_size,
    }
    stats = RunStats(
        batch_size=batch_size,
        seconds=total_seconds,
        batches=batches,
        pbkdf2_total=total_pbkdf2,
        pbkdf2_per_second=pbkdf2_per_second,
        matrix_candidates_per_second=matrix_per_second,
        matrix_candidates_total=matrix_per_second * total_seconds,
        samples_per_batch=sample_rates,
    )
    return device_info, stats


def benchmark_native_secp256k1(seconds: int) -> dict:
    private_keys = []
    for i in range(4096):
        digest = hashlib.sha256(f"hanako-secp256k1-bench-{i}".encode()).digest()
        # coincurve requires 1 <= key < curve_order; sha256 fixture is sufficient for this benchmark.
        private_keys.append(digest)

    # Warm up.
    for key in private_keys[:256]:
        coincurve.PublicKey.from_valid_secret(key).format(compressed=False)

    started = time.perf_counter()
    deadline = started + seconds
    count = 0
    idx = 0
    while time.perf_counter() < deadline:
        key = private_keys[idx]
        coincurve.PublicKey.from_valid_secret(key).format(compressed=False)
        count += 1
        idx += 1
        if idx >= len(private_keys):
            idx = 0
    elapsed = time.perf_counter() - started
    return {
        "seconds": elapsed,
        "public_keys_total": count,
        "public_keys_per_second": count / elapsed,
    }


def search_space(k: int, d_max: int, cols: int = 12) -> int:
    return sum(math.comb(cols, d) * ((k - 1) ** d) for d in range(d_max + 1))


def summarize(device_info: dict, stats: RunStats, secp_stats: dict, seconds: int) -> dict:
    secp_rate = secp_stats["public_keys_per_second"]
    full_slow_path_rate = min(stats.pbkdf2_per_second, secp_rate)
    full_matrix_rate = full_slow_path_rate * 16.0
    return {
        "device": device_info,
        "duration_target_seconds": seconds,
        "gpu_pbkdf2": {
            "batch_size": stats.batch_size,
            "seconds": stats.seconds,
            "batches": stats.batches,
            "pbkdf2_total": stats.pbkdf2_total,
            "pbkdf2_per_second": stats.pbkdf2_per_second,
            "matrix_candidates_per_second_checksum_adjusted": stats.matrix_candidates_per_second,
            "matrix_candidates_total_checksum_adjusted": stats.matrix_candidates_total,
            "per_batch_rate_min": min(stats.samples_per_batch),
            "per_batch_rate_median": statistics.median(stats.samples_per_batch),
            "per_batch_rate_max": max(stats.samples_per_batch),
        },
        "native_cpu_secp256k1": secp_stats,
        "combined_estimate": {
            "slow_path_per_second_limited_by_min_gpu_pbkdf2_and_cpu_secp256k1": full_slow_path_rate,
            "matrix_candidates_per_second_checksum_adjusted": full_matrix_rate,
            "matrix_candidates_total_in_duration": full_matrix_rate * stats.seconds,
        },
        "search_spaces": {
            "k3_full": 3**12,
            "k4_full": 4**12,
            "k5_full": 5**12,
            "k3_d12": search_space(3, 12),
            "k4_d12": search_space(4, 12),
            "k5_d12": search_space(5, 12),
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Hanako recovery GPU benchmark")
    parser.add_argument("--seconds", type=int, default=60, help="GPU benchmark duration, seconds")
    parser.add_argument("--secp-seconds", type=int, default=10, help="native secp256k1 benchmark duration, seconds")
    parser.add_argument("--batch-size", type=int, default=None, help="OpenCL global work size")
    parser.add_argument("--fixed-input", action="store_true", help="do not append a nonce to the benchmark password")
    parser.add_argument("--json-out", type=Path, default=None, help="write JSON result to this path")
    parser.add_argument("--password", default=DEFAULT_PASSWORD, help="base mnemonic-like password")
    args = parser.parse_args()

    if args.seconds <= 0:
        raise SystemExit("--seconds 必须大于 0")
    password = args.password.encode("utf-8")
    if len(password) + (0 if args.fixed_input else 8) > 160:
        raise SystemExit("benchmark password 太长，当前 OpenCL kernel 上限为 160 字节")

    print("== Hanako GPU Recovery Benchmark ==")
    print(f"PID: {os.getpid()}")
    print(f"GPU PBKDF2 duration: {args.seconds}s")
    print(f"Native secp256k1 duration: {args.secp_seconds}s")
    print(f"Input mode: {'fixed' if args.fixed_input else 'varied nonce suffix'}")
    print(f"Base password bytes: {len(password)}")

    device_info, stats = run_gpu_benchmark(args.seconds, args.batch_size, not args.fixed_input, password)
    print(f"\nOpenCL device: {device_info['device']} ({device_info['platform']})")
    print(f"Batch size: {stats.batch_size}")
    print(f"GPU PBKDF2-HMAC-SHA512-2048: {stats.pbkdf2_per_second:,.2f} /s")
    print(f"Checksum-adjusted matrix rate: {stats.matrix_candidates_per_second:,.2f} combos/s")
    print(f"Checksum-adjusted total: {stats.matrix_candidates_total:,.0f} combos in {stats.seconds:.1f}s")

    secp_stats = benchmark_native_secp256k1(args.secp_seconds)
    print(f"\nNative CPU secp256k1 public key derivation: {secp_stats['public_keys_per_second']:,.2f} /s")

    result = summarize(device_info, stats, secp_stats, args.seconds)
    combined = result["combined_estimate"]
    print("\nCombined estimate (GPU PBKDF2 + native CPU secp256k1 bottleneck):")
    print(f"  slow-path verifications: {combined['slow_path_per_second_limited_by_min_gpu_pbkdf2_and_cpu_secp256k1']:,.2f} /s")
    print(f"  matrix candidates:       {combined['matrix_candidates_per_second_checksum_adjusted']:,.2f} combos/s")
    print(f"  total in run:            {combined['matrix_candidates_total_in_duration']:,.0f} combos")

    print("\nFull matrix time estimate:")
    rate = combined["matrix_candidates_per_second_checksum_adjusted"]
    for k in (3, 4, 5):
        total = k**12
        secs = total / rate if rate > 0 else float("inf")
        print(f"  K={k}: {total:,} combos -> {secs / 60:.2f} min")

    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nJSON result: {args.json_out}")


if __name__ == "__main__":
    main()
