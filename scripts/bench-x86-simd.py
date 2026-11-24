"""Print sizes and rotated medians for the x86-64 zlib-ng dispatch variants."""

import os
import re
import statistics
import subprocess
from pathlib import Path

VARIANTS = (
    "baseline",
    "without_ssse3",
    "without_sse4",
    "without_avx2",
    "without_pclmul",
)
BENCHMARK = re.compile(
    r"^(\S+) \(\d+ runs, (CPU|wall)\): decode ([\d.]+) ms, compare [\d.]+ ms, "
    r"sheet ([\d.]+) ms, sheet size [\d.]+ KiB, file pipeline ([\d.]+) ms, peak RSS .+$",
    re.MULTILINE,
)


def build(step, variant):
    result = subprocess.run(
        ["zig", "build", step, "-Doptimize=safe", "-Dcpu=baseline", f"-Dx86-simd={variant}"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="", flush=True)
    result.check_returncode()
    return result.stdout


def main():
    sizes = {}
    for variant in VARIANTS:
        print(f"{variant} size", flush=True)
        size = re.search(r": (\d+) bytes, budget ", build("size", variant))
        sizes[variant] = int(size[1])

    samples = {}
    for start in range(len(VARIANTS)):
        for variant in VARIANTS[start:] + VARIANTS[:start]:
            print(f"{variant} run {start + 1}", flush=True)
            output = build("bench", variant)
            for workload, clock, decode, sheet, pipeline in BENCHMARK.findall(output):
                samples.setdefault((variant, workload, clock), []).append(
                    (float(decode), float(sheet), float(pipeline))
                )

    print_summary(sizes, samples)


def print_summary(sizes, samples):
    rows = [
        "| Variant | Workload | Clock | Binary bytes | Decode ms | Sheet ms | Pipeline ms |",
        "|---|---|---|---:|---:|---:|---:|",
    ]
    for variant in VARIANTS:
        keys = sorted(key for key in samples if key[0] == variant)
        if not keys:
            raise RuntimeError(f"No benchmark output for {variant}")
        for key in keys:
            _, workload, clock = key
            runs = samples[key]
            if len(runs) != len(VARIANTS):
                raise RuntimeError(f"Incomplete samples for {variant} {workload}")
            decode, sheet, pipeline = (statistics.median(column) for column in zip(*runs))
            rows.append(f"| {variant} | {workload} | {clock} | {sizes[variant]} | {decode:.3f} | {sheet:.3f} | {pipeline:.3f} |")
    table = "\n".join(rows) + "\n"
    print(table, end="")
    if summary := os.getenv("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a", encoding="utf-8") as out:
            out.write(table)


if __name__ == "__main__":
    main()
