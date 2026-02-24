# Benchmark Results

Generated: 2026-02-24T07:23:02-05:00

## Environment
- buck2: buck2 2025-12-01-75e4243c93877a3db4acf55f20d2e80a32523233
- dhall: 1.42.3
- CPU: AMD Ryzen Threadripper PRO 7965WX 24-Cores

## 1. Dhall Evaluation Speed

How fast can we render BUILD.dhall → IR?

  Average: 0.046s per evaluation

## 2. Dhall → BUCK Rendering

Time to generate BUCK file from BUILD.dhall.

Skipped: to-buck2.dhall expects Target type

## 3. Buck2 Analysis Time

How fast can Buck2 parse and analyze the generated BUCK files?

  Average: 0.011s per analysis

## 4. sensenet DICE Performance

ActionKey computation and graph construction benchmarks.

╔══════════════════════════════════════════════════════════════════╗
║           sensenet DICE Performance Benchmarks                   ║
╚══════════════════════════════════════════════════════════════════╝

Configuration: 10000 actions, quick mode

┌──────────────────────────────────────────────────────────────────┐
│ 1. ACTION KEY COMPUTATION (BLAKE2b-256)                          │
└──────────────────────────────────────────────────────────────────┘
   Actions:     10000
   Total time:  0.0230 sec
   Per action:  2.30 µs
   Throughput:  435730 keys/sec
   Checksum:    640000 bytes

┌──────────────────────────────────────────────────────────────────┐
│ 2. CANONICAL FORM CONSTRUCTION (ByteString Builder)              │
└──────────────────────────────────────────────────────────────────┘
   Actions:     10000
   Total time:  0.0070 sec
   Per action:  0.70 µs
   Avg size:    136 bytes
   Total data:  1.37 MB

┌──────────────────────────────────────────────────────────────────┐
│ 3. GRAPH CONSTRUCTION                                            │
└──────────────────────────────────────────────────────────────────┘
   Actions:     10000
   Graph size:  10000 nodes
   Total time:  0.0306 sec
   Per insert:  3.06 µs
   Throughput:  327331 inserts/sec

┌──────────────────────────────────────────────────────────────────┐
│ 4. TOPOLOGICAL SORT                                              │
└──────────────────────────────────────────────────────────────────┘
   Nodes:       10000
   Linear chain (worst): 0.0256 sec (10000 sorted)
   Independent (best):   0.0038 sec (10000 sorted)

┌──────────────────────────────────────────────────────────────────┐
│ 5. END-TO-END (construct graph + topological sort)               │
└──────────────────────────────────────────────────────────────────┘
   Actions:     10000
   Sorted:      10000
   Total time:  0.0326 sec
   Per action:  3.26 µs

╔══════════════════════════════════════════════════════════════════╗
║                      Benchmark Complete                          ║
╚══════════════════════════════════════════════════════════════════╝
