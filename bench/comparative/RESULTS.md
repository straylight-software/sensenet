# Benchmark Results

Generated: 2026-02-26T12:11:17-05:00

## Environment

- buck2: buck2 2025-12-01-75e4243c93877a3db4acf55f20d2e80a32523233
- dhall: 1.42.3
- CPU: AMD Ryzen Threadripper PRO 7965WX 24-Cores

## 1. DICE Performance (100K actions)

ActionKey computation and graph construction benchmarks at scale.

```
╔══════════════════════════════════════════════════════════════════╗
║           sensenet DICE Performance Benchmarks                   ║
╚══════════════════════════════════════════════════════════════════╝

Configuration: 100000 actions, full mode

┌──────────────────────────────────────────────────────────────────┐
│ 1. ACTION KEY COMPUTATION (BLAKE2b-256)                          │
└──────────────────────────────────────────────────────────────────┘
   Actions:     100000
   Total time:  0.2058 sec
   Per action:  2.06 µs
   Throughput:  485808 keys/sec
   Checksum:    6400000 bytes

┌──────────────────────────────────────────────────────────────────┐
│ 2. CANONICAL FORM CONSTRUCTION (ByteString Builder)              │
└──────────────────────────────────────────────────────────────────┘
   Actions:     100000
   Total time:  0.0478 sec
   Per action:  0.48 µs
   Avg size:    140 bytes
   Total data:  14.06 MB

┌──────────────────────────────────────────────────────────────────┐
│ 3. GRAPH CONSTRUCTION                                            │
└──────────────────────────────────────────────────────────────────┘
   Actions:     100000
   Graph size:  100000 nodes
   Total time:  0.4234 sec
   Per insert:  4.23 µs
   Throughput:  236181 inserts/sec

┌──────────────────────────────────────────────────────────────────┐
│ 4. TOPOLOGICAL SORT                                              │
└──────────────────────────────────────────────────────────────────┘
   Nodes:       100000
   Linear chain (worst): 0.4684 sec (100000 sorted)
   Independent (best):   0.0636 sec (100000 sorted)

┌──────────────────────────────────────────────────────────────────┐
│ 5. END-TO-END (construct graph + topological sort)               │
└──────────────────────────────────────────────────────────────────┘
   Actions:     100000
   Sorted:      100000
   Total time:  0.4385 sec
   Per action:  4.38 µs
```

## 2. DhallFast vs Upstream Performance

### Simple Arithmetic

| Implementation | Time/iter | Speedup |
|---------------|-----------|---------|
| Upstream Dhall | 0.21 µs | baseline |
| DhallFast (eval) | 0.15 µs | 1.4x |
| DhallFast (full) | 0.02 µs | 10.5x |

### Natural/fold (loop performance)

| N | Upstream | DhallFast | Speedup |
|---|----------|-----------|---------|
| 100 | 3.53 µs | 1.61 µs | 2.2x |
| 1000 | 33.55 µs | 12.42 µs | 2.7x |
| 5000 | 154.12 µs | 65.70 µs | 2.3x |
| 10000 | 313.92 µs | 128.08 µs | 2.5x |

### Nested Let Bindings (environment lookup)

| Depth | Upstream | DhallFast | Speedup |
|-------|----------|-----------|---------|
| 10 | 0.54 µs | 0.15 µs | 3.6x |
| 50 | 2.70 µs | 0.64 µs | 4.2x |
| 100 | 4.57 µs | 1.27 µs | 3.6x |
| 200 | 9.86 µs | 2.29 µs | 4.3x |

### Record Operations

| Operation | Upstream | DhallFast | Speedup |
|-----------|----------|-----------|---------|
| 10-field access | 0.17 µs | 0.07 µs | 2.4x |
| 50-field access | 0.52 µs | 0.13 µs | 4.0x |
| 100-field access | 1.87 µs | 0.27 µs | 6.9x |
| Record merge | 0.21 µs | 0.35 µs | 0.6x\* |

\*Record merge is slower due to Vector allocation overhead; upstream uses linked list.

### List Operations

| Operation | Upstream | DhallFast | Speedup |
|-----------|----------|-----------|---------|
| List/length (100) | 0.17 µs | 0.04 µs | 4.3x |
| List/length (500) | 0.20 µs | 0.04 µs | 5.0x |
| List/fold (50) | 3.57 µs | 2.14 µs | 1.7x |
| List/fold (100) | 7.07 µs | 3.57 µs | 2.0x |

## 3. Summary

| Metric | Value | Notes |
|--------|-------|-------|
| ActionKey throughput | **486K keys/sec** | BLAKE2b-256, 64-byte hash |
| Graph construction | **236K inserts/sec** | Strict Map with key computation |
| Topo sort (independent) | **1.6M nodes/sec** | Best case |
| Topo sort (linear chain) | **214K nodes/sec** | Worst case |
| DhallFast speedup (avg) | **2-7x** | Depending on workload |
| DhallFast field access | **Up to 6.9x** | Sorted vector with binary search |

### Key Optimizations

**DhallFast:**

- De Bruijn indices: O(1) variable lookup vs O(n) name search
- Array environment: Cache-friendly vs linked list
- Sorted vector fields: Binary search with better locality
- Unboxed literals: Less indirection, better cache usage

**DICE:**

- BLAKE2b-256: 1.5x faster than SHA256, still cryptographic
- ByteString Builder: Zero-copy canonical form construction
- Strict Data.Map: Efficient persistent maps for graph
