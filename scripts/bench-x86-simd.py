"""Measure x86-64 zlib-ng dispatch variants or native CLI link-time optimization."""

import argparse
import json
import os
import platform
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

from binary_sections import measure

CLI_ROUNDS = 25


def rotated_runs(arms, count):
    for run in range(count):
        offset = run % len(arms)
        for arm in arms[offset:] + arms[:offset]:
            yield run, arm


def build(step, variant="all_levels", *options):
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
    executable = "uidiff.exe" if platform.system() == "Windows" else "uidiff"
    with tempfile.TemporaryDirectory(prefix="uidiff-simd-") as scratch:
        build("bench-variants", "shipped", "--prefix", scratch)
        variants = tuple(json.loads((Path(scratch) / "x86-simd-variants.json").read_text()))
        if not variants:
            raise RuntimeError("Build has no x86 SIMD variants")
        for variant in variants:
            print(f"{variant} size", flush=True)
            prefix = Path(scratch) / variant
            build("install", variant, "size", "--prefix", str(prefix))
            sizes[variant] = measure(prefix / "bin" / executable)

    samples = {}
    for run, variant in rotated_runs(variants, len(variants)):
        print(f"{variant} run {run + 1}", flush=True)
        output = build("bench", variant)
        for line in output.splitlines():
            if not line.startswith("{"):
                continue
            sample = json.loads(line)
            key = variant, sample["workload"], sample["clock"]
            samples.setdefault(key, []).append((sample["decode_ms"], sample["sheet_ms"], sample["pipeline_ms"]))

    print_summary(variants, sizes, samples)


def print_summary(variants, sizes, samples):
    rows = [
        "| Variant | Workload | Clock | File bytes | Code bytes | Data bytes | Decode ms | Sheet ms | Pipeline ms |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for variant in variants:
        keys = sorted(key for key in samples if key[0] == variant)
        if not keys:
            raise RuntimeError(f"No benchmark output for {variant}")
        for key in keys:
            _, workload, clock = key
            runs = samples[key]
            if len(runs) != len(variants):
                raise RuntimeError(f"Incomplete samples for {variant} {workload}")
            decode, sheet, pipeline = (statistics.median(column) for column in zip(*runs))
            rows.append(f"| {variant} | {workload} | {clock} | {sizes[variant].file_bytes} | {sizes[variant].code_bytes} | {sizes[variant].data_bytes} | {decode:.3f} | {sheet:.3f} | {pipeline:.3f} |")
    table = "\n".join(rows) + "\n"
    publish(table)


def bench_lto():
    system = platform.system()
    if system not in ("Linux", "Windows") or platform.machine().lower() not in ("x86_64", "amd64"):
        raise SystemExit("The LTO comparison requires x86-64 Linux or Windows")
    if system == "Windows":
        from windows_process import timed_process
        target, executable = "-Dtarget=x86_64-windows", "uidiff.exe"
    else:
        timed_process = timed_linux
        target, executable = "-Dtarget=x86_64-linux-musl", "uidiff"

    with tempfile.TemporaryDirectory(prefix="uidiff-lto-") as scratch:
        root = Path(scratch)
        build("bench-inputs", "all_levels", target, "--prefix", str(root))
        workloads = [
            line.split("\t") for line in (root / "bench-inputs.tsv").read_text().splitlines()
        ]
        if not workloads:
            raise RuntimeError("No CLI benchmark workloads")
        binaries = {}
        for arm in ("false", "true"):
            prefix = root / arm
            build("install", "shipped", "size", target, f"-Dcli-lto={arm}", "--prefix", str(prefix))
            binaries[arm] = prefix / "bin" / executable

        sizes = {arm: measure(binary) for arm, binary in binaries.items()}
        rows = [
            "| Workload | Output | LTO | File bytes | Code bytes | Data bytes | Wall ms | CPU ms | Peak RSS MiB |",
            "|---|---|---|---:|---:|---:|---:|---:|---:|",
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
                for _, arm in rotated_runs(arms, CLI_ROUNDS):
                    samples[arm].append(time_cli(timed_process, commands[arm], outputs[arm][0]))
                for arm, values in samples.items():
                    wall, cpu, rss = (distribution(column) for column in zip(*values))
                    rows.append(f"| {name} | {output} | {arm} | {sizes[arm].file_bytes} | {sizes[arm].code_bytes} | {sizes[arm].data_bytes} | {wall} | {cpu} | {rss} |")
        publish("\n".join(rows) + "\n")


def distribution(samples):
    if None in samples:
        return "N/A"
    return f"{statistics.median(samples):.3f} [{min(samples):.3f}, {max(samples):.3f}]"


def time_cli(timed_process, command, expected_exit):
    status, wall, cpu, rss = timed_process(command)
    if status != expected_exit:
        raise RuntimeError(f"Expected exit {expected_exit}, received {status}")
    return wall, cpu, rss


def timed_linux(command):
    start = time.perf_counter_ns()
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL)
    _, status, usage = os.wait4(process.pid, 0)
    wall_ms = (time.perf_counter_ns() - start) / 1_000_000
    process.returncode = os.waitstatus_to_exitcode(status)
    return process.returncode, wall_ms, 1_000 * (usage.ru_utime + usage.ru_stime), usage.ru_maxrss / 1024


def publish(table):
    print(table, end="")
    if summary := os.getenv("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a", encoding="utf-8") as out:
            out.write(table)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lto", action="store_true", help="compare Linux or Windows ReleaseSafe CLI LTO variants")
    if parser.parse_args().lto:
        bench_lto()
    else:
        bench_simd()


if __name__ == "__main__":
    main()
