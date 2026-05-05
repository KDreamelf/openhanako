# GPU Recovery Benchmark

用于在 Windows 本机显卡上测 Hanako 恢复慢路径的吞吐。

## 运行

```powershell
cd benchmarks\gpu_recovery_bench
uv sync
uv run python gpu_recovery_bench.py --seconds 60 --secp-seconds 10 --batch-size 32768 --json-out results\gtx1660super-60s.json
```

## 口径

- GPU：OpenCL 跑 `PBKDF2-HMAC-SHA512(password, "mnemonic", 2048, 64)`。
- 输入：默认使用一条中文助记词形态的 UTF-8 字符串，并为每个 work item 追加 nonce，避免所有线程完全同输入。
- 校验：OpenCL 输出会先和 Python `hashlib.pbkdf2_hmac` 对齐校验。
- 折算：BIP-39 12 词 checksum 约 `1/16` 通过，所以矩阵组合吞吐约等于 `GPU PBKDF2/s * 16`。
- secp256k1：用 `coincurve` 的 native `libsecp256k1` 绑定测 CPU 公钥派生吞吐，并用 `min(GPU PBKDF2/s, CPU secp256k1/s)` 估算完整慢路径上限。
- 注意：这是项目内可复现的 OpenCL 原型基准，不是 hand-tuned CUDA/hashcat 级绝对攻击上限。

## 当前结果

GTX 1660 SUPER，60 秒基准：

- GPU PBKDF2：约 `32,692/s`
- checksum 折算矩阵枚举：约 `523,066 组合/s`
- 60 秒折算：约 `31,457,280 组合`
- native CPU secp256k1：约 `44,474/s`

完整结果见 `results/gtx1660super-60s-reuse-kernel.json`。
