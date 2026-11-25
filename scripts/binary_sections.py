"""Report file bytes and code/data section bytes for a release executable."""

import argparse
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import NamedTuple

MACH_MAGIC = {b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe"}
MACH_SECTION = re.compile(r"^\s*Section (?:\([^,]+,\s*)?([^:)]+)\)?:\s+(\d+)", re.MULTILINE)
SYSV_SECTION = re.compile(r"^\s*(\.\S+)\s+(\d+)\s+\d+\s*$", re.MULTILINE)
MACH_CODE = {"__text", "__stubs", "__stub_helper"}
MACH_UNINITIALIZED = {"__bss", "__common", "__thread_bss"}
SYSV_CODE = {".text", ".init", ".fini", ".plt", ".iplt"}
SYSV_DATA = {
    ".rodata", ".rdata", ".data", ".data.rel.ro", ".sdata", ".tdata", ".tls",
    ".got", ".idata", ".edata", ".pdata", ".xdata", ".eh_frame",
    ".eh_frame_hdr", ".gcc_except_table", ".init_array", ".fini_array",
    ".preinit_array", ".dynamic", ".srodata",
}


class Footprint(NamedTuple):
    file_bytes: int
    code_bytes: int
    data_bytes: int


def named_section(name, bases):
    return any(name == base or name.startswith(base + ".") or name.startswith(base + "$") for base in bases)


def measure(binary):
    with binary.open("rb") as source:
        magic = source.read(4)
    macho = magic in MACH_MAGIC
    if not macho and magic != b"\x7fELF" and not magic.startswith(b"MZ"):
        raise ValueError(f"Unsupported executable format for {binary.name}")
    tool = os.getenv("LLVM_SIZE") or shutil.which("llvm-size") or shutil.which("size")
    if tool is None:
        raise RuntimeError("Install llvm-size or set LLVM_SIZE to its path")
    listing = subprocess.check_output([tool, "-m" if macho else "-A", str(binary)], text=True)
    if macho:
        sections = [(name, int(size)) for name, size in MACH_SECTION.findall(listing)]
        code = sum(size for name, size in sections if name in MACH_CODE)
        data = sum(size for name, size in sections if name not in MACH_CODE | MACH_UNINITIALIZED)
    else:
        sections = [(name, int(size)) for name, size in SYSV_SECTION.findall(listing)]
        code = sum(size for name, size in sections if named_section(name, SYSV_CODE))
        data = sum(size for name, size in sections if named_section(name, SYSV_DATA))
    if code == 0:
        raise RuntimeError(f"No executable code sections found for {binary.name}")
    return Footprint(binary.stat().st_size, code, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, nargs="+")
    for binary in parser.parse_args().binary:
        print(binary.name, *measure(binary), sep="\t")


if __name__ == "__main__":
    main()
