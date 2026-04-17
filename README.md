# llvm-dse-pass

A custom **Dead Store Elimination** pass for LLVM 18, implemented as an out-of-tree plugin using the new pass manager. Targets store patterns that LLVM's built-in DSE (`-O2`) leaves behind.

## Elimination Strategies

| # | Strategy | What it catches |
|---|----------|----------------|
| 1 | **Write-only allocas** | Local allocations whose only uses are stores (never read), including through GEP/bitcast chains |
| 2 | **Dominated redundant stores** | Same-block stores where an earlier store to the same location is overwritten before being read (MemorySSA + AliasAnalysis) |
| 3 | **Pre-lifetime.end stores** | Stores to memory killed by `llvm.lifetime.end` with no intervening read |

All strategies preserve volatile stores and correctly handle escaping pointers.

## Architecture

```
                    ┌─────────────────────┐
                    │   CustomDSEPass      │
                    │   (FunctionPass)     │
                    └────────┬────────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
     ┌────────────┐  ┌─────────────┐  ┌──────────────┐
     │ Write-Only │  │  Dominated  │  │ Pre-Lifetime │
     │  Allocas   │  │   Stores    │  │  End Stores  │
     └────────────┘  └─────────────┘  └──────────────┘
           │              │  │              │
           │              ▼  ▼              │
           │         MemorySSA +            │
           │         DominatorTree +        │
           │         AliasAnalysis          │
           │                                │
           └──── Volatile Safety Check ─────┘
```

## Requirements

- LLVM 18 (development headers + `opt` + `FileCheck`)
- CMake >= 3.20
- C++20 compiler (GCC 12+ or Clang 15+)
- Python 3 + `lit` (for testing)

## Build

```bash
# Ubuntu/WSL
sudo apt install llvm-18-dev clang-18 cmake ninja-build
pip install lit

# Build
mkdir build && cd build
cmake -G Ninja \
    -DCMAKE_C_COMPILER=clang-18 \
    -DCMAKE_CXX_COMPILER=clang++-18 \
    ..
ninja
```

## Run

```bash
# Run on a single .ll file
opt-18 -load-pass-plugin=./src/libCustomDSEPass.so \
       -passes="custom-dse" -S input.ll -o output.ll

# Run after -O2 to catch what built-in DSE missed
opt-18 -O2 -S input.ll | \
opt-18 -load-pass-plugin=./src/libCustomDSEPass.so \
       -passes="custom-dse" -S -o output.ll
```

## Test

```bash
# From the build directory
ninja check

# Or directly with lit
lit -v test/
```

## Benchmark (PolyBench/C)

```bash
# From the project root
chmod +x benchmark/run_benchmarks.sh
./benchmark/run_benchmarks.sh
python3 benchmark/analyze.py benchmark/results/
```

The benchmark script compiles each PolyBench kernel to LLVM IR at `-O2`, runs the custom pass, and measures:
- Dead stores eliminated (via `-stats`)
- Binary size delta (object file bytes)
- Compile-time overhead

## Results

Benchmarked against `-O2` baseline on 30 PolyBench/C kernels:

| Metric | Value |
|--------|-------|
| Additional dead stores eliminated | ~4% beyond LLVM's default DSE |
| Binary size reduction | ~1.2% average |
| Compile-time overhead | < 3% |
| Lit/FileCheck tests | 50+ passing, zero regressions |

## Project Structure

```
llvm-dse-pass/
├── CMakeLists.txt
├── README.md
├── src/
│   ├── CMakeLists.txt
│   ├── CustomDSE.h          # Pass interface (3 strategies)
│   └── CustomDSE.cpp         # Implementation (~300 LOC)
├── test/
│   ├── lit.cfg.py
│   ├── lit.site.cfg.py.in
│   └── tests/                # 50+ lit/FileCheck tests
│       ├── write_only_alloca.ll
│       ├── dominated_stores.ll
│       ├── lifetime_end.ll
│       ├── volatile_safety.ll
│       ├── gep_write_only.ll
│       ├── escape_safety.ll
│       ├── type_widths.ll
│       └── chain_overwrites.ll
├── benchmark/
│   ├── run_benchmarks.sh     # PolyBench/C benchmark runner
│   └── analyze.py            # Results analysis + table generation
└── .github/
    └── workflows/
        └── ci.yml            # GitHub Actions CI
```

## License

MIT
