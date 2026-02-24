# sensenet Performance

This document describes the performance characteristics of sensenet's DICE
(Dynamic Incremental Computation Engine) and the optimizations applied.

## Executive Summary

| Operation | Throughput | Latency |
|-----------|------------|---------|
| ActionKey computation | **509K keys/sec** | 1.96 µs |
| Canonical form | 2.2M/sec | 0.46 µs |
| Graph construction | 235K inserts/sec | 4.25 µs |
| Topological sort (independent) | 1.6M nodes/sec | 0.62 µs |
| End-to-end (100K actions) | — | 435 ms |

## Hash Algorithm Selection

We use **BLAKE2b-256** instead of SHA256:

| Algorithm | Time/op | Throughput | Security |
|-----------|---------|------------|----------|
| SHA256 | 2.07 µs | 483K/sec | Cryptographic |
| **BLAKE2b-256** | **1.13 µs** | **885K/sec** | Cryptographic |
| FNV-1a 128-bit | 0.65 µs | 1.5M/sec | Non-cryptographic |

**Why BLAKE2b-256?**
- 1.5x faster than SHA256
- Still cryptographically secure (unlike FNV/xxHash)
- Same 256-bit output, same collision resistance
- Already in `crypton` package, no new dependencies
- Used by IPFS, WireGuard, libsodium

## Optimization History

### Baseline (v0.3)
```
Text.intercalate → Text → encodeUtf8 → SHA256 → hex
```
- ~483K keys/sec

### v0.4 Optimizations

1. **ByteString Builder** (+35% on canonical form)
   - Avoid intermediate Text allocations
   - Single-pass construction

2. **hashlazy** (+10% on hashing)
   - Hash lazy ByteString directly
   - Avoid `BL.toStrict` copy

3. **BLAKE2b-256** (+50% on hashing)
   - Faster algorithm, same security

4. **Fast-path escape** (+5% on inputs without special chars)
   - Skip byte-by-byte escaping when no `\0` or `\\` present

**Combined improvement: ~83% faster**

## Benchmark Results

### ActionKey Computation (BLAKE2b-256)

```
Actions:     100,000
Total time:  0.196 sec
Per action:  1.96 µs
Throughput:  509,036 keys/sec
```

### Canonical Form Construction

```
Actions:     100,000
Total time:  0.046 sec
Per action:  0.46 µs
Avg size:    140 bytes
Total data:  14.06 MB
```

### Graph Construction

```
Actions:     100,000
Graph size:  100,000 nodes
Total time:  0.425 sec
Per insert:  4.25 µs
Throughput:  235,402 inserts/sec
```

### Topological Sort

```
Nodes:       100,000
Linear chain (worst): 0.480 sec
Independent (best):   0.062 sec
```

### End-to-End

```
Actions:     100,000
Total time:  0.435 sec
Per action:  4.35 µs
```

## Comparative Benchmarks (vs Buck2)

**Environment**: AMD Ryzen Threadripper PRO 7965WX 24-Cores

| Stage | Tool | Time |
|-------|------|------|
| Dhall evaluation | dhall | 48 ms |
| BUCK analysis | buck2 | 11 ms |
| DICE ActionKey (10K) | sensenet | 25 ms |
| DICE graph+sort (10K) | sensenet | 32 ms |

**Key findings:**

1. **Dhall overhead**: BUILD.dhall → IR takes ~48ms (dominated by Dhall interpreter)
2. **Buck2 analysis**: Parsing BUCK files is very fast (~11ms for cxx example)
3. **DICE overhead**: Minimal compared to Dhall evaluation
   - ActionKey: 2.46 µs/action = 407K keys/sec
   - Graph: 2.79 µs/insert = 359K inserts/sec

**Bottleneck**: Dhall evaluation is 4x slower than Buck2 analysis.

## DhallFast Optimization

DhallFast is a drop-in replacement normalizer that provides 2-10x speedup for
normalization-bound workloads:

| Workload | Upstream | DhallFast | Speedup |
|----------|----------|-----------|---------|
| Simple arithmetic | 0.21 µs | 0.02 µs | **10x** |
| Natural/fold 1000 | 31.6 µs | 12.8 µs | **2.5x** |
| 200 nested lets | 9.2 µs | 2.4 µs | **3.9x** |
| Natural/fold 10000 | 307 µs | 118 µs | **2.6x** |
| Record 100 fields | 1.35 µs | 0.28 µs | **4.8x** |
| List/fold 100 | 6.4 µs | 3.4 µs | **1.9x** |

**Key optimizations:**
- De Bruijn indices: O(1) variable lookup vs O(n) name search
- Strict spine list environment: O(1) cons, O(i) lookup (i typically < 10)
- Sorted vector fields: Binary search with better cache locality
- Unboxed literals: Less indirection, better L2 cache usage

**When DhallFast helps:**
- Cold cache (no semantic cache hit)
- Compute-bound expressions (Natural/fold, List/fold)
- Deep nesting (many let bindings, lambdas)

**When DhallFast has overhead:**
- Already-normalized expressions (conversion cost ~0.5-1µs)
- Small, simple expressions (conversion dominates)

Run DhallFast benchmarks:
```bash
./bench/dhall-fast-bench
./bench/integration-test path/to/BUILD.dhall 1000
```

## Running Benchmarks

```bash
# Quick mode (10K actions)
nix run .#bench -- --quick

# Full mode (100K actions)
nix run .#bench

# Comparative benchmarks
./bench/comparative/run.sh

# Or directly
ghc -O2 -package crypton -package memory bench/Main.hs -o bench
./bench +RTS -N1
```

## Theoretical Limits

| Component | Current | Theoretical | Efficiency |
|-----------|---------|-------------|------------|
| BLAKE2b-256 | 509K/sec | ~2M/sec (small msg) | 25% |
| Map.insert | 235K/sec | ~1M/sec | 24% |
| TopoSort | 1.6M/sec | ~5M/sec | 32% |

Remaining overhead:
- UTF-8 encoding of Text fields (~20%)
- Memory allocation (~30%)
- Map rebalancing (~20%)

## Memory Usage

For 100K actions:
- Graph: ~50 MB
- Peak during sort: ~80 MB
- ActionKey size: 64 bytes (hex-encoded BLAKE2b-256)

## Scaling

| Actions | Build Graph | TopoSort | End-to-End |
|---------|-------------|----------|------------|
| 1,000 | 2 ms | 0.5 ms | 3 ms |
| 10,000 | 25 ms | 5 ms | 32 ms |
| 100,000 | 425 ms | 62 ms | 435 ms |
| 1,000,000 | ~5 sec | ~700 ms | ~6 sec |

Graph construction is O(n log n) due to Map insertions.
Topological sort is O(n + e) where e = edges.

## Profiling

To profile:
```bash
ghc -O2 -prof -fprof-auto bench/Main.hs -o bench
./bench +RTS -p -N1
cat bench.prof
```

Key findings:
- 70% of time in `actionKey` (hash computation)
- 15% of time in `Map.insert`
- 10% of time in `topoSort`
- 5% in canonical form construction
