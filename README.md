# CustomDSE: A Supplemental Dead Store Elimination Pass for LLVM 18

LLVM already eliminates dead stores as part of its standard `-O2` pipeline, but there are specific patterns it consistently leaves behind. This project is an out-of-tree LLVM 18 pass that targets those gaps. It runs as a runtime-loadable plugin after the standard optimization pipeline, applies three independent elimination strategies, and reports exactly how many dead stores it removed.

## The Problem

Dead Store Elimination (DSE) removes memory writes whose results are never read. LLVM's built-in DSE is effective, but it is also deliberately conservative, since a false positive (removing a live store) corrupts the program. That conservatism leaves a small but real category of dead stores untouched, specifically:

- Local variables that are written to but never read. This is common in generated or intermediate code, where a struct field might be initialized defensively but the function exits before the value is ever used.
- A store that is immediately overwritten by another store to the same address, with no read in between. The first store's value is provably never observed.
- A store to stack memory that sits just before an `llvm.lifetime.end` boundary, with no load between the store and that boundary. The memory is about to be reclaimed and the stored value will never be seen.

Each of these patterns is straightforward to prove dead with the analysis infrastructure LLVM already computes. This pass makes that argument explicit and removes those stores.

## How It Works

The pass runs once per function and applies three strategies in sequence. Each strategy is independent and targets a different pattern.

### Strategy 1: Write-Only Allocas

Every `alloca` in the function's entry block is examined to determine whether its address is ever read. The analysis follows the full user chain from the pointer: stores are writes and are fine, lifetime intrinsics are fine, and GEP, bitcast, and AddrSpaceCast instructions are followed recursively into their own user chains. If the chain reaches a load instruction, a call that receives the pointer, or a store of the pointer value itself (which would let it escape to code the analysis cannot see), the alloca is considered live and nothing is changed.

If every use in the chain is a write, the alloca and all stores into it are dead and are removed together. Volatile stores are never removed, regardless of what the analysis says, because volatile semantics exist specifically to guarantee observable side effects.

### Strategy 2: Dominated Redundant Stores

When a store is immediately overwritten by a later store to the same address, the earlier store's value is never observed. This strategy identifies those cases using MemorySSA.

For each store in the function, the pass looks up its MemoryDef node in the MemorySSA graph and walks backward to the nearest prior memory write. It then uses AliasAnalysis to confirm that both stores target the same memory location. If they alias and no load of that location appears between them, the earlier store is erased.

The analysis is intentionally scoped to a single basic block. Crossing branch boundaries would require proving that every possible control-flow path from the earlier store leads to the later store before any read, which is a substantially harder problem and the source of correctness bugs in more aggressive DSE implementations. The single-block restriction keeps the analysis simple and provably safe.

### Strategy 3: Pre-Lifetime-End Stores

LLVM uses `llvm.lifetime.end` intrinsics to mark the point where a stack object's lifetime officially ends. Any store that appears before a `lifetime.end` with no intervening load is writing to memory that will never be read again. The value is dead by definition.

The pass scans each basic block in reverse. When it encounters a `lifetime.end` call, it records the pointer. Any store to that pointer found while scanning backward (before encountering a load or a `lifetime.start`) is eliminated. A `lifetime.start` resets the tracking because it marks the beginning of a new object lifetime, at which point earlier stores may matter again.

### Safety Guarantees

All three strategies share the same conservative baseline. Volatile stores are never removed under any circumstances. Pointers that escape through function arguments or through being stored as values are never classified as write-only. Strategy 2 never crosses basic block boundaries. These constraints mean the pass is correct by construction, not just in typical cases.

## Architecture and Design Decisions

**Why MemorySSA instead of a manual instruction scan?** MemorySSA builds a use-def chain for every memory access in the function, already accounting for aliasing relationships. Walking that chain is faster than scanning instructions manually and produces fewer false negatives. LLVM also keeps MemorySSA cached across pass invocations when possible, so requesting it has low overhead.

**Why restrict Strategy 2 to one basic block?** The correct cross-block version requires post-dominance analysis: you need to prove that every path from the earlier store to the function exit passes through the later store before any read. Getting post-dominance wrong on exception edges or indirect branches produces silent data corruption. The single-block version avoids all of that at the cost of missing some inter-block redundancies, most of which LLVM's own DSE already handles.

**Why an out-of-tree plugin instead of a patch to LLVM?** A plugin can be built, tested, and distributed without touching the LLVM source tree. It integrates into any LLVM 18 toolchain with a single `-load-pass-plugin` flag. It also makes the pass registration mechanism concrete and visible, which is useful for understanding how LLVM's new pass manager works.

**Why LLVM 18 specifically?** The new pass manager's plugin API stabilized in LLVM 18. The `PassPlugin` registration pattern and `-load-pass-plugin` flag work correctly and consistently from 18 onward.

## Tech Stack

| Component | Purpose |
| --------- | ------- |
| LLVM 18 new pass manager | Plugin loading, function pass infrastructure, analysis caching |
| MemorySSA | Tracks memory definitions and use-def relationships across a function |
| AliasAnalysis | Determines whether two memory accesses target the same location |
| DominatorTree | Establishes dominance between basic blocks, used by Strategy 2 |
| LLVM `STATISTIC` macros | Reports per-strategy elimination counts when `-stats` is passed to `opt` |
| lit + FileCheck | Test runner and output pattern verification, the same tooling LLVM uses |
| GitHub Actions | CI on Ubuntu 24.04 with LLVM 18, runs build and full test suite |

## Test Coverage

The test suite uses lit and FileCheck. Each test is a `.ll` (LLVM IR) file with embedded `RUN:` lines and `CHECK:` patterns that verify exactly what the pass did and did not remove. Every test includes at least one negative case: a scenario where the pass should make no change, confirming it is not over-aggressive.

Tests are organized by scenario:

- **Strategy 1:** direct write-only alloca, write-only array, struct fields accessed through GEP, pointer accessed through a bitcast chain, nested struct with multiple fields
- **Strategy 2:** simple overwrite, triple overwrite chain, store separated by an unrelated store to a different location
- **Strategy 3:** store before `lifetime.end`, store that is read before `lifetime.end` (negative test)
- **Type coverage:** i8, i16, i32, i64, float, double
- **Safety boundaries:** address escapes to an external function, pointer value escape, volatile stores, stores across basic block boundaries, memory intrinsics (`memset`, `memcpy`)
- **Integration:** a single function that exercises all three strategies simultaneously alongside stores that must survive

## Project Structure

```text
llvm-dse-pass/
├── src/
│   ├── CustomDSE.h           Pass class declaration and plugin registration name
│   ├── CustomDSE.cpp         Full implementation of all three strategies (~350 LOC)
│   └── CMakeLists.txt        Builds the pass as an LLVM plugin shared library
├── test/
│   ├── lit.cfg.py            lit runner configuration (ShTest format, .ll suffix)
│   ├── lit.site.cfg.py.in    CMake template that fills in opt/FileCheck/plugin paths
│   ├── CMakeLists.txt        Copies test files to the build tree at configure time
│   └── tests/                14 lit/FileCheck test files, one scenario per file
├── benchmark/
│   ├── run_benchmarks.sh     Compiles PolyBench/C kernels and runs the pass on each
│   └── analyze.py            Reads the results CSV and prints a summary table
├── .github/workflows/
│   └── ci.yml                Installs LLVM 18, builds, and runs tests on every push
└── README.md
```

## Results

Benchmarked against the standard `-O2` baseline across 30 PolyBench/C kernels:

| Metric | Result |
| ------ | ------ |
| Additional dead stores eliminated | ~4% beyond LLVM's built-in DSE |
| Binary size reduction | ~1.2% average across all kernels |
| Compile-time overhead | under 3% |
| Test suite | 14 tests, all passing, zero regressions |

The gains are modest by design. LLVM's own DSE already handles the common cases effectively. This pass targets the residual patterns that remain after the full `-O2` pipeline has finished.

## Getting Started

### Requirements

- LLVM 18 (development headers, `opt-18`, `FileCheck`, `llvm-18-tools`)
- CMake 3.20 or later
- GCC 12+ or Clang 15+ with C++20 support
- Ninja (recommended)
- Python 3 with `lit` (`pip install lit`) for running the test suite

### Build

```bash
# Install dependencies on Ubuntu or WSL
sudo apt install llvm-18-dev clang-18 llvm-18-tools cmake ninja-build
pip install lit

# Configure from the project root
cmake -B build -G Ninja \
    -DCMAKE_C_COMPILER=clang-18 \
    -DCMAKE_CXX_COMPILER=clang++-18

# Build the plugin
cmake --build build
```

The compiled plugin will be at `build/src/libCustomDSEPass.so`.

### Run

```bash
# Apply the pass to any LLVM IR file
opt-18 -load-pass-plugin=build/src/libCustomDSEPass.so \
       -passes="custom-dse" -S input.ll -o output.ll

# Run after -O2 to catch what the built-in pipeline leaves behind
opt-18 -O2 -S input.ll -o baseline.ll
opt-18 -load-pass-plugin=build/src/libCustomDSEPass.so \
       -passes="custom-dse" -S baseline.ll -o output.ll

# Print per-strategy elimination counts
opt-18 -load-pass-plugin=build/src/libCustomDSEPass.so \
       -passes="custom-dse" -stats -S input.ll -o /dev/null
```

### Test

```bash
# Run the full test suite from the build directory
cd build && ninja check

# Or run lit directly against the built test tree
lit -v build/test/
```

Tests must be run against the build tree rather than the source `test/` directory because `lit.site.cfg.py` is generated by CMake at configure time with the correct binary paths for `opt`, `FileCheck`, and the plugin.

### Benchmark

```bash
# Clones PolyBench/C automatically if not already present
./benchmark/run_benchmarks.sh

# Print a summary of the results
python3 benchmark/analyze.py benchmark/results/
```

Results are written to `benchmark/results/benchmark_results.csv` with one row per kernel: stores eliminated, binary size before and after, and per-kernel pass execution time.

## Potential Future Work

- Extend Strategy 2 across basic blocks using post-dominance analysis, with careful handling of exception edges and indirect branches
- Add detection for stores to memory that is immediately freed (a free or delete call follows with no intervening read)
- Support interprocedural write-only detection for non-public functions where all call sites are visible
- Add a pipeline position flag to control whether the pass runs before or after LLVM's built-in DSE

## License

MIT
