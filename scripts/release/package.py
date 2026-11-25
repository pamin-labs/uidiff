#!/usr/bin/env python3
"""Package the pinned uidiff version for each supported release target."""

import argparse
from dataclasses import dataclass
from hashlib import file_digest
import json
from pathlib import Path
import re
import shutil
from string import Template
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "https://github.com/pamin-labs/uidiff"
NOTICES = ("LICENSE", "THIRD_PARTY_NOTICES")
NATIVE_ENTRY = "./native"


@dataclass(frozen=True)
class Target:
    zig: str

    @property
    def os(self):
        return self.zig.split("-")[1]

    @property
    def arch(self):
        return {"x86_64": "x64", "aarch64": "arm64"}[self.zig.split("-")[0]]

    @property
    def binary(self):
        return "uidiff.exe" if self.os == "windows" else "uidiff"

    def asset_stem(self, version):
        return f"uidiff-{version}-{self.os}-{self.arch}"

    def release_binary(self, version):
        return self.asset_stem(version) + self.binary.removeprefix("uidiff")

    def archive(self, version):
        extension = ".zip" if self.os == "windows" else ".tar.gz"
        return self.asset_stem(version) + extension

    @property
    def npm_os(self):
        return {"macos": "darwin", "windows": "win32"}.get(self.os, self.os)

    @property
    def npm_name(self):
        return f"@uidiff/{self.npm_os}-{self.arch}"


TARGETS = tuple(Target(zig) for zig in json.loads((ROOT / ".github/release-targets.json").read_text()))


def version():
    zon = (ROOT / "build.zig.zon").read_text()
    match = re.search(r'^    \.version = "([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)",$', zon, re.M)
    if match is None:
        raise SystemExit("build.zig.zon: expected a release version")
    return match[1]


def digest(path):
    with path.open("rb") as stream:
        return file_digest(stream, "sha256").hexdigest()


def pack(target, release_version, bin_dir, output):
    output.mkdir(parents=True, exist_ok=True)
    binary = bin_dir / target.binary
    standalone = target.release_binary(release_version)
    shutil.copy2(binary, output / standalone)
    archive = output / target.archive(release_version)
    entries = (binary, *(ROOT / name for name in NOTICES))
    if target.os == "windows":
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
            for source in entries:
                bundle.write(source, source.name)
    else:
        with tarfile.open(archive, "w:gz") as bundle:
            for source in entries:
                bundle.add(source, arcname=source.name)
    return standalone


def formula_platforms(release_version, output):
    url = f"{REPOSITORY}/releases/download/v{release_version}"
    lines = []
    for os in ("macos", "linux"):
        lines.append(f"  on_{os} do")
        for target in TARGETS:
            if target.os != os:
                continue
            archive = target.archive(release_version)
            arch = {"arm64": "arm", "x64": "intel"}[target.arch]
            lines.extend((
                f"    on_{arch} do",
                f'      url "{url}/{archive}"',
                f'      sha256 "{digest(output / archive)}"',
                "    end",
            ))
        lines.append("  end")
    return "\n".join(lines)


def finalize(release_version, output):
    template = Template(Path(__file__).with_name("uidiff.rb.in").read_text())
    formula = template.substitute(
        version=release_version, repository=REPOSITORY, platforms=formula_platforms(release_version, output)
    )
    (output / "uidiff.rb").write_text(formula)
    for installer in ("install.sh", "install.ps1"):
        shutil.copy2(ROOT / installer, output / installer)
    assets = ["uidiff.rb", "install.sh", "install.ps1"]
    for target in TARGETS:
        assets.extend((target.release_binary(release_version), target.archive(release_version)))
    sums = "".join(f"{digest(output / name)}  {name}\n" for name in sorted(assets))
    (output / "SHA256SUMS").write_text(sums)


def write_manifest(package_dir, manifest):
    package_dir.mkdir(parents=True, exist_ok=True)
    (package_dir / "package.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for name in NOTICES:
        shutil.copy2(ROOT / name, package_dir / name)


def npm_packages(release_version, binaries, output):
    shared = {
        "version": release_version,
        "license": "MIT",
        "repository": {"type": "git", "url": f"git+{REPOSITORY}.git"},
        "publishConfig": {"access": "public"},
    }
    for target in TARGETS:
        package_dir = output / target.npm_name
        write_manifest(package_dir, {
            **shared,
            "name": target.npm_name,
            "os": [target.npm_os],
            "cpu": [target.arch],
            "exports": {NATIVE_ENTRY: f"./{target.binary}"},
            "files": [target.binary, *NOTICES],
        })
        shutil.copy2(binaries / target.release_binary(release_version), package_dir / target.binary)
        (package_dir / target.binary).chmod(0o755)
    main = output / "uidiff"
    write_manifest(main, {
        **shared,
        "name": "uidiff",
        "description": "Align moved screenshot content and box visual changes",
        "bin": {"uidiff": "uidiff.cjs"},
        "files": ["uidiff.cjs", *NOTICES],
        "optionalDependencies": {target.npm_name: release_version for target in TARGETS},
    })
    shutil.copy2(ROOT / "npm/uidiff/uidiff.cjs", main / "uidiff.cjs")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("matrix")
    validate = commands.add_parser("version")
    validate.add_argument("--tag")
    package = commands.add_parser("pack")
    package.add_argument("target", choices=[target.zig for target in TARGETS])
    package.add_argument("bin_dir", type=Path)
    package.add_argument("output", type=Path)
    commands.add_parser("finalize").add_argument("output", type=Path)
    npm = commands.add_parser("npm")
    npm.add_argument("binaries", type=Path)
    npm.add_argument("output", type=Path)
    args = parser.parse_args()
    release_version = version()

    if args.command == "matrix":
        print(json.dumps([target.zig for target in TARGETS]))
    elif args.command == "version":
        if args.tag is not None and args.tag != f"v{release_version}":
            parser.error(f"tag {args.tag} does not match build.zig.zon (v{release_version})")
        print(release_version)
    elif args.command == "pack":
        print(pack(Target(args.target), release_version, args.bin_dir, args.output))
    elif args.command == "finalize":
        finalize(release_version, args.output)
    elif args.command == "npm":
        npm_packages(release_version, args.binaries, args.output)


if __name__ == "__main__":
    main()
