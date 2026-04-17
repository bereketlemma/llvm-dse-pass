#!/usr/bin/env bash
#
# run_benchmarks.sh — Benchmark CustomDSEPass against PolyBench/C at -O2.
#
# Measures:
#   1. Dead stores eliminated (via LLVM -stats)
#   2. Binary size delta (object file bytes)
#   3. Compile-time overhead of the custom pass
#
# Usage:
#   ./benchmark/run_benchmarks.sh [path/to/polybench-c]
#
# If no path is given, PolyBench/C is cloned automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
RESULTS_DIR="${SCRIPT_DIR}/results"
PLUGIN="${BUILD_DIR}/src/libCustomDSEPass.so"

# Tool paths — adjust if your LLVM 18 binaries have a different suffix.
CLANG="${CLANG:-clang-18}"
OPT="${OPT:-opt-18}"
LLC="${LLC:-llc-18}"

POLYBENCH_DIR="${1:-${SCRIPT_DIR}/polybench-c}"

# ── Clone PolyBench/C if needed ──────────────────────────
if [ ! -d "$POLYBENCH_DIR" ]; then
    echo "[*] Cloning PolyBench/C..."
    git clone https://github.com/MatthiasJReworker/PolyBench-C.git "$POLYBENCH_DIR" 2>/dev/null \
        || git clone https://github.com/cavazos-lab/PolyBench-ACC.git "$POLYBENCH_DIR" 2>/dev/null \
        || { echo "ERROR: Could not clone PolyBench/C. Please provide the path as an argument."; exit 1; }
fi

# ── Verify tools exist ───────────────────────────────────
for tool in "$CLANG" "$OPT" "$LLC"; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: $tool not found. Install LLVM 18 or set ${tool^^} env var."
        exit 1
    fi
done

if [ ! -f "$PLUGIN" ]; then
    echo "ERROR: Plugin not found at $PLUGIN"
    echo "       Build the project first: cd build && ninja"
    exit 1
fi

mkdir -p "$RESULTS_DIR"

# ── Find all kernel source files ─────────────────────────
KERNELS=$(find "$POLYBENCH_DIR" -name "*.c" \
    ! -path "*/utilities/*" \
    ! -name "polybench.c" \
    | sort)

KERNEL_COUNT=$(echo "$KERNELS" | wc -l)
echo "[*] Found $KERNEL_COUNT kernels in $POLYBENCH_DIR"
echo "[*] Plugin: $PLUGIN"
echo "[*] Results: $RESULTS_DIR"
echo ""

# ── CSV header ───────────────────────────────────────────
CSV="${RESULTS_DIR}/benchmark_results.csv"
echo "kernel,baseline_obj_bytes,custom_obj_bytes,size_delta_bytes,size_delta_pct,dead_stores_eliminated,pass_time_ms" > "$CSV"

TOTAL_BASELINE=0
TOTAL_CUSTOM=0
TOTAL_STORES=0
PROCESSED=0

POLYBENCH_INCLUDE="${POLYBENCH_DIR}/utilities"

for SRC in $KERNELS; do
    KERNEL_NAME=$(basename "$SRC" .c)
    KERNEL_DIR=$(basename "$(dirname "$SRC")")
    LABEL="${KERNEL_DIR}/${KERNEL_NAME}"

    echo -n "  [$((PROCESSED+1))/$KERNEL_COUNT] $LABEL ... "

    WORKDIR=$(mktemp -d)
    trap "rm -rf $WORKDIR" EXIT

    # Step 1: Compile to LLVM IR at -O2 (baseline)
    if ! $CLANG -O2 -emit-llvm -S \
        -I"$POLYBENCH_INCLUDE" \
        -DPOLYBENCH_USE_C99_PROTO \
        -DMINI_DATASET \
        "$SRC" \
        "${POLYBENCH_DIR}/utilities/polybench.c" \
        -o "$WORKDIR/baseline.ll" 2>/dev/null; then
        echo "SKIP (compile error)"
        rm -rf "$WORKDIR"
        continue
    fi

    # Step 2: Baseline object size
    if ! $LLC -filetype=obj "$WORKDIR/baseline.ll" -o "$WORKDIR/baseline.o" 2>/dev/null; then
        echo "SKIP (llc error)"
        rm -rf "$WORKDIR"
        continue
    fi
    BASELINE_SIZE=$(stat -c%s "$WORKDIR/baseline.o" 2>/dev/null || stat -f%z "$WORKDIR/baseline.o")

    # Step 3: Run custom DSE pass and capture stats + timing
    STATS_OUTPUT=$($OPT -load-pass-plugin="$PLUGIN" \
        -passes="custom-dse" \
        -stats \
        -S "$WORKDIR/baseline.ll" \
        -o "$WORKDIR/custom.ll" 2>&1 || true)

    # Extract dead store count from stats output
    STORES=$(echo "$STATS_OUTPUT" | grep -oP '\d+(?=.*stores?.*(eliminated|removed))' | head -1)
    STORES=${STORES:-0}

    # Step 4: Custom object size
    if ! $LLC -filetype=obj "$WORKDIR/custom.ll" -o "$WORKDIR/custom.o" 2>/dev/null; then
        echo "SKIP (llc custom error)"
        rm -rf "$WORKDIR"
        continue
    fi
    CUSTOM_SIZE=$(stat -c%s "$WORKDIR/custom.o" 2>/dev/null || stat -f%z "$WORKDIR/custom.o")

    # Step 5: Measure pass execution time (microseconds)
    START_NS=$(date +%s%N)
    $OPT -load-pass-plugin="$PLUGIN" \
        -passes="custom-dse" \
        -S "$WORKDIR/baseline.ll" \
        -o /dev/null 2>/dev/null
    END_NS=$(date +%s%N)
    PASS_TIME_MS=$(( (END_NS - START_NS) / 1000000 ))

    # Compute delta
    SIZE_DELTA=$((BASELINE_SIZE - CUSTOM_SIZE))
    if [ "$BASELINE_SIZE" -gt 0 ]; then
        SIZE_PCT=$(echo "scale=4; $SIZE_DELTA * 100 / $BASELINE_SIZE" | bc)
    else
        SIZE_PCT="0"
    fi

    echo "${LABEL},${BASELINE_SIZE},${CUSTOM_SIZE},${SIZE_DELTA},${SIZE_PCT},${STORES},${PASS_TIME_MS}" >> "$CSV"

    TOTAL_BASELINE=$((TOTAL_BASELINE + BASELINE_SIZE))
    TOTAL_CUSTOM=$((TOTAL_CUSTOM + CUSTOM_SIZE))
    TOTAL_STORES=$((TOTAL_STORES + STORES))
    PROCESSED=$((PROCESSED + 1))

    echo "stores=${STORES} delta=${SIZE_DELTA}B (${SIZE_PCT}%) time=${PASS_TIME_MS}ms"

    rm -rf "$WORKDIR"
    trap - EXIT
done

echo ""
echo "════════════════════════════════════════════"
echo " SUMMARY"
echo "════════════════════════════════════════════"
echo " Kernels processed:    $PROCESSED"
echo " Total stores removed: $TOTAL_STORES"
if [ "$TOTAL_BASELINE" -gt 0 ]; then
    TOTAL_PCT=$(echo "scale=4; ($TOTAL_BASELINE - $TOTAL_CUSTOM) * 100 / $TOTAL_BASELINE" | bc)
    echo " Total size delta:     $((TOTAL_BASELINE - TOTAL_CUSTOM)) bytes ($TOTAL_PCT%)"
fi
echo " Full results:         $CSV"
echo "════════════════════════════════════════════"
