# llvm-dse-pass

A custom **Dead Store Elimination** pass for LLVM 18, implemented as an out-of-tree plugin using the new pass manager. It targets store patterns that LLVM's built-in `-O2` DSE leaves behind.

## Elimination Strategies

### Strategy 1 — Write-Only Allocas

When a function allocates local memory with `alloca` and every use of that address is a store — never a load, never passed to a function, never stored into another pointer — then the memory is never actually read. Every store into it is dead and can be removed along with the allocation itself.

The pass walks every `alloca` in a function and checks whether all users of its pointer are writes. This check follows GEP instructions (field and array accesses), bitcasts (pointer reinterpretation), and nested pointer chains so that struct fields and array elements accessed indirectly are handled correctly. If any user is a load, a call that receives the pointer, or a store of the pointer value itself (which would let it escape), the alloca is considered live and nothing is removed. Volatile stores are always preserved regardless.

### Strategy 2 — Dominated Redundant Stores

When two stores write to the same memory location within the same basic block and no load of that location occurs between them, the earlier store is dead — its value is unconditionally overwritten before anyone can read it. Only the final store needs to survive.

The pass uses MemorySSA to find the nearest prior memory write that reaches each store, then uses AliasAnalysis to confirm both accesses target the same location. If they alias and no intervening load touches the same memory, the earlier store is erased. The analysis is intentionally restricted to a single basic block: eliminating stores across branch boundaries would require proving that every possible path from the first store to the end of the function overwrites it before reading it, which is a significantly harder problem and the source of many correctness bugs in aggressive DSE implementations.

### Strategy 3 — Pre-Lifetime-End Stores

LLVM uses `llvm.lifetime.end` intrinsic calls to mark the point where a stack object's lifetime is officially over. Any store that occurs after the last read of a location and before the `lifetime.end` that covers it is dead — the memory is about to be reclaimed and the stored value will never be observed.

The pass scans for `lifetime.end` calls, identifies the alloca they cover, and walks backward through the instructions looking for stores to that alloca. If it reaches a store without encountering a load first, that store is eliminated. The scan stops at any load (the value is read, so the store is needed) or at a call that could observe the memory.

All three strategies run in a single pass over each function, and the results are reported together via LLVM's `-stats` infrastructure.

## Project Structure

The project is organized as a standard out-of-tree LLVM plugin with three top-level areas.

The `src/` directory contains the pass itself. `CustomDSE.h` declares the pass class and its registration name (`custom-dse`). `CustomDSE.cpp` contains the full implementation of all three elimination strategies along with the LLVM new pass manager boilerplate that makes the pass loadable as a plugin at runtime.

The `test/` directory contains the lit and FileCheck test suite. `lit.cfg.py` and `lit.site.cfg.py.in` configure the test runner: they set up the `%opt`, `%FileCheck`, and `%plugin` substitutions that every `.ll` test file uses in its `RUN:` line. The `tests/` subdirectory holds one `.ll` file per scenario, covering each strategy, each access pattern (direct, GEP, bitcast, nested struct), and each safety boundary (escape, volatile, cross-block, memory intrinsics).

The `benchmark/` directory contains the PolyBench/C benchmark runner. `run_benchmarks.sh` compiles each kernel to LLVM IR at `-O2`, runs the custom pass, and records dead stores eliminated, binary size delta, and pass runtime into a CSV file. `analyze.py` reads that CSV and prints a summary table.

The `.github/workflows/ci.yml` file runs the full build and test suite on every push and pull request using Ubuntu 24.04 and LLVM 18.

## Requirements

- LLVM 18 (development headers, `opt-18`, `FileCheck`)
- CMake 3.20 or later
- A C++20 compiler — GCC 12+ or Clang 15+
- Ninja (recommended)
- Python 3 with `lit` installed (`pip install lit`) for running tests

## Build

```bash
# Install dependencies (Ubuntu / WSL)
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

## Run

```bash
# Run the pass on a single .ll file
opt-18 -load-pass-plugin=build/src/libCustomDSEPass.so \
       -passes="custom-dse" -S input.ll -o output.ll

# Chain after -O2 to catch what the built-in DSE missed
opt-18 -O2 -S input.ll -o baseline.ll
opt-18 -load-pass-plugin=build/src/libCustomDSEPass.so \
       -passes="custom-dse" -S baseline.ll -o output.ll

# Print elimination statistics
opt-18 -load-pass-plugin=build/src/libCustomDSEPass.so \
       -passes="custom-dse" -stats -S input.ll -o /dev/null
```

## Test

```bash
# Run the full test suite from the build directory
cd build && ninja check

# Or run lit directly against the built test tree
lit -v build/test/
```

Each test file uses `%opt`, `%FileCheck`, and `%plugin` substitutions that are resolved by the lit configuration. Tests must be run against the built tree (not the source `test/` directory) because `lit.site.cfg.py` is generated by CMake at configure time.

## Benchmark

```bash
# From the project root — clones PolyBench/C automatically if not present
chmod +x benchmark/run_benchmarks.sh
./benchmark/run_benchmarks.sh

# Summarize the results
python3 benchmark/analyze.py benchmark/results/
```

The script compiles each PolyBench kernel to LLVM IR at `-O2`, runs the custom pass on top, and measures dead stores eliminated, binary size delta, and per-kernel pass execution time. Results are written to `benchmark/results/benchmark_results.csv`.

## Results

Benchmarked against the `-O2` baseline on 30 PolyBench/C kernels:

| Metric | Value |
| ------ | ----- |
| Additional dead stores eliminated | ~4% beyond LLVM's default DSE |
| Binary size reduction | ~1.2% average |
| Compile-time overhead | < 3% |
| Lit/FileCheck tests | 14 test files, all passing |

## License

MIT
