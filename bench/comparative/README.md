# sensenet vs Buck2 Comparative Benchmarks

This directory contains benchmarks comparing sensenet's Dhall→Buck2 pipeline
against native Buck2.

## Architecture

```
sensenet flow:
  BUILD.dhall → [dhall] → to-buck2.dhall → BUCK → [buck2] → build

native buck2:
  BUCK (hand-written) → [buck2] → build
```

## What We Measure

1. **Dhall evaluation time**: How fast can we render BUILD.dhall → BUCK?
2. **Buck2 analysis time**: Does generated BUCK have overhead vs hand-written?
3. **End-to-end no-op**: Time from `sensenet build` to completion (cached)
4. **DICE vs Buck2 caching**: ActionKey computation overhead

## Running Benchmarks

```bash
# Generate synthetic projects
./setup.sh

# Run comparison
./run.sh
```

## Results

See `RESULTS.md` after running benchmarks.
