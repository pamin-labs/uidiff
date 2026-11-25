"""Measure x86-64 zlib-ng dispatch variants or Linux CLI link-time optimization."""

import argparse
import os
import platform
import re
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

VARIANTS = (
    "baseline",
    "without_ssse3",
    "without_sse4",
    "without_avx2",
    "without_pclmul",
)
CLI_ROUNDS = 25
BENCHMARK = re.compile(
    r"^(\S+) \(\d+ runs, (CPU|wall)\): decode ([\d.]+) ms, compare [\d.]+ ms, "
    r"sheet ([\d.]+) ms, sheet size [\d.]+ KiB, file pipeline ([\d.]+) ms, peak RSS .+$",
    re.MULTILINE,
)


def build(step, variant="baseline", *options):
    result = subprocess.run(
        ["zig", "build", step, "-Doptimize=safe", "-Dcpu=baseline", f"-Dx86-simd={variant}", *options],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="", flush=True)
    result.check_returncode()
    return result.stdout


def bench_simd():
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
    publish(table)


def bench_lto():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise SystemExit("The LTO comparison requires x86-64 Linux")

    with tempfile.TemporaryDirectory(prefix="uidiff-lto-") as scratch:
        root = Path(scratch)
        target = "-Dtarget=x86_64-linux-musl"
        build("bench-inputs", "baseline", target, "--prefix", str(root))
        workloads = [
            line.split("\t") for line in (root / "bench-inputs.tsv").read_text().splitlines()
        ]
        if not workloads:
            raise RuntimeError("No CLI benchmark workloads")
        binaries = {}
        for arm in ("false", "true"):
            prefix = root / arm
            build("install", "baseline", target, f"-Dcli-lto={arm}", "--prefix", str(prefix))
            binaries[arm] = prefix / "bin" / "uidiff"

        rows = [
            "| Workload | Output | LTO | Binary bytes | Wall ms | CPU ms | Peak RSS MiB |",
            "|---|---|---|---:|---:|---:|---:|",
        ]
        for name, before, after, scale in workloads:
            for output in ("JSON", "JSON + sheet"):
                sheet = root / "sheet.png" if output == "JSON + sheet" else None
                args = [before, after, "--scale", scale, "--json"]
                outputs = {}
                commands = {}
                for arm, binary in binaries.items():
                    commands[arm] = [str(binary), *args]
                    if sheet is not None:
                        sheet.unlink(missing_ok=True)
                        commands[arm].extend(("--annotate", str(sheet)))
                    run = subprocess.run(commands[arm], capture_output=True, check=False)
                    if run.returncode not in (0, 1):
                        raise RuntimeError(f"{name} failed with exit code {run.returncode}")
                    outputs[arm] = (run.returncode, run.stdout, None if sheet is None else sheet.read_bytes())
                if outputs["false"] != outputs["true"]:
                    raise RuntimeError(f"{name} produced different {output} output with LTO")

                samples = {arm: [] for arm in commands}
                arms = tuple(commands)
                for i in range(CLI_ROUNDS):
                    offset = i % len(arms)
                    for arm in arms[offset:] + arms[:offset]:
                        samples[arm].append(time_cli(commands[arm], outputs[arm][0]))
                for arm, values in samples.items():
                    wall, cpu, rss = (statistics.median(column) for column in zip(*values))
                    rows.append(f"| {name} | {output} | {arm} | {binaries[arm].stat().st_size} | {wall:.3f} | {cpu:.3f} | {rss:.3f} |")
        publish("\n".join(rows) + "\n")


def time_cli(command, expected_exit):
    start = time.perf_counter_ns()
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL)
    _, status, usage = os.wait4(process.pid, 0)
    wall_ms = (time.perf_counter_ns() - start) / 1_000_000
    process.returncode = os.waitstatus_to_exitcode(status)
    if process.returncode != expected_exit:
        raise RuntimeError(f"Expected exit {expected_exit}, received {process.returncode}")
    return wall_ms, 1_000 * (usage.ru_utime + usage.ru_stime), usage.ru_maxrss / 1024


def publish(table):
    print(table, end="")
    if summary := os.getenv("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a", encoding="utf-8") as out:
            out.write(table)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lto", action="store_true", help="compare Linux ReleaseSafe CLI LTO variants")
    if parser.parse_args().lto:
        bench_lto()
    else:
        bench_simd()


if __name__ == "__main__":
    main()
