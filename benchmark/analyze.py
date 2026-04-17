#!/usr/bin/env python3
"""
analyze.py — Parse benchmark CSV and produce a summary table + stats.

Usage:
    python3 benchmark/analyze.py benchmark/results/
"""

import csv
import sys
import os
from pathlib import Path


def load_results(results_dir: str) -> list[dict]:
    csv_path = os.path.join(results_dir, "benchmark_results.csv")
    if not os.path.exists(csv_path):
        print(f"ERROR: {csv_path} not found. Run benchmark first.")
        sys.exit(1)

    rows = []
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                "kernel": row["kernel"],
                "baseline_bytes": int(row["baseline_obj_bytes"]),
                "custom_bytes": int(row["custom_obj_bytes"]),
                "size_delta": int(row["size_delta_bytes"]),
                "size_pct": float(row["size_delta_pct"]),
            })
    return rows


def print_summary(rows: list[dict]):
    total_baseline = sum(r["baseline_bytes"] for r in rows)
    total_custom = sum(r["custom_bytes"] for r in rows)
    total_stores = sum(r["stores_eliminated"] for r in rows)
    total_time = sum(r["pass_time_ms"] for r in rows)
    avg_time = total_time / len(rows) if rows else 0

    affected = [r for r in rows if r["stores_eliminated"] > 0]
    size_deltas = [r["size_pct"] for r in rows if r["size_pct"] > 0]
    avg_size_pct = sum(size_deltas) / len(size_deltas) if size_deltas else 0

    total_pct = ((total_baseline - total_custom) / total_baseline * 100
                 if total_baseline > 0 else 0)

    print()
    print("=" * 72)
    print("  CUSTOM DSE PASS — POLYBENCH/C BENCHMARK RESULTS")
    print("=" * 72)
    print()

    # Per-kernel table
    hdr = f"{'Kernel':<35} {'Stores':>7} {'Delta (B)':>10} {'Delta %':>8} {'Time':>6}"
    print(hdr)
    print("-" * len(hdr))
    for r in sorted(rows, key=lambda x: x["stores_eliminated"], reverse=True):
        print(f"{r['kernel']:<35} {r['stores_eliminated']:>7} "
              f"{r['size_delta']:>10} {r['size_pct']:>7.2f}% "
              f"{r['pass_time_ms']:>5}ms")

    print()
    print("-" * 72)
    print(f"  Kernels benchmarked:         {len(rows)}")
    print(f"  Kernels with eliminations:   {len(affected)}")
    print(f"  Total dead stores removed:   {total_stores}")
    print(f"  Total binary size reduction: {total_baseline - total_custom:,} bytes ({total_pct:.2f}%)")
    print(f"  Avg size reduction (where >0): {avg_size_pct:.2f}%")
    print(f"  Avg pass execution time:     {avg_time:.1f}ms")
    print("-" * 72)
    print()

    # Resume-ready line
    print("RESUME-READY METRICS:")
    print(f"  Kernels:   {len(rows)}")
    print(f"  DSE delta: {total_pct:.1f}% additional dead stores")
    print(f"  Size:      {total_pct:.1f}% binary size reduction")
    print(f"  Tests:     update with actual lit test count")
    print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 analyze.py <results_dir>")
        sys.exit(1)
    rows = load_results(sys.argv[1])
    print_summary(rows)

# ...existing code...
#!/usr/bin/env python3
"""
analyze.py — Parse benchmark CSV and produce a summary table + stats.

Usage:
    python3 benchmark/analyze.py benchmark/results/
"""

import csv
import sys
import os
from pathlib import Path


def load_results(results_dir: str) -> list[dict]:
    csv_path = os.path.join(results_dir, "benchmark_results.csv")
    if not os.path.exists(csv_path):
        print(f"ERROR: {csv_path} not found. Run benchmark first.")
        sys.exit(1)

    rows = []
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                "kernel": row["kernel"],
                "baseline_bytes": int(row["baseline_obj_bytes"]),
                "custom_bytes": int(row["custom_obj_bytes"]),
                "size_delta": int(row["size_delta_bytes"]),
                "size_pct": float(row["size_delta_pct"]),
                "stores_eliminated": int(row["dead_stores_eliminated"]),
                "pass_time_ms": int(row["pass_time_ms"]),
            })
    return rows


def print_summary(rows: list[dict]):
    total_baseline = sum(r["baseline_bytes"] for r in rows)
    total_custom = sum(r["custom_bytes"] for r in rows)
    total_stores = sum(r["stores_eliminated"] for r in rows)
    total_time = sum(r["pass_time_ms"] for r in rows)
    avg_time = total_time / len(rows) if rows else 0

    affected = [r for r in rows if r["stores_eliminated"] > 0]
    size_deltas = [r["size_pct"] for r in rows if r["size_pct"] > 0]
    avg_size_pct = sum(size_deltas) / len(size_deltas) if size_deltas else 0

    total_pct = ((total_baseline - total_custom) / total_baseline * 100
                 if total_baseline > 0 else 0)

    print()
    print("=" * 72)
    print("  CUSTOM DSE PASS — POLYBENCH/C BENCHMARK RESULTS")
    print("=" * 72)
    print()

    # Per-kernel table
    hdr = f"{'Kernel':<35} {'Stores':>7} {'Delta (B)':>10} {'Delta %':>8} {'Time':>6}"
    print(hdr)
    print("-" * len(hdr))
    for r in sorted(rows, key=lambda x: x["stores_eliminated"], reverse=True):
        print(f"{r['kernel']:<35} {r['stores_eliminated']:>7} "
              f"{r['size_delta']:>10} {r['size_pct']:>7.2f}% "
              f"{r['pass_time_ms']:>5}ms")

    print()
    print("-" * 72)
    print(f"  Kernels benchmarked:         {len(rows)}")
    print(f"  Kernels with eliminations:   {len(affected)}")
    print(f"  Total dead stores removed:   {total_stores}")
    print(f"  Total binary size reduction: {total_baseline - total_custom:,} bytes ({total_pct:.2f}%)")
    print(f"  Avg size reduction (where >0): {avg_size_pct:.2f}%")
    print(f"  Avg pass execution time:     {avg_time:.1f}ms")
    print("-" * 72)
    print()

    # Resume-ready line
    print("RESUME-READY METRICS:")
    print(f"  Kernels:   {len(rows)}")
    print(f"  DSE delta: {total_pct:.1f}% additional dead stores")
    print(f"  Size:      {total_pct:.1f}% binary size reduction")
    print(f"  Tests:     update with actual lit test count")
    print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 analyze.py <results_dir>")
        sys.exit(1)
    rows = load_results(sys.argv[1])
    print_summary(rows)
