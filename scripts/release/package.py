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
PROGRAM = "uidiff"
REPOSITORY = "https://github.com/pamin-labs/uidiff"
# The R2 bucket `uidiff` mirrors the release layout for hosts that cannot reach GitHub.
DOWNLOADS = "https://uidiff.paminlabs.com"
INSTALLERS = ("install.sh", "install.ps1")
CHECKSUMS = "SHA256SUMS"
VERSION_PATTERN = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?"
NOTICES = ("LICENSE", "THIRD_PARTY_NOTICES")
NATIVE_ENTRY = "./native"
NPM_SCOPE = "@pamin-labs"
NPM_PACKAGE = f"{NPM_SCOPE}/{PROGRAM}"
TAP_REPOSITORY = "pamin-labs/homebrew-tap"
TAP_FORMULA = f"Formula/{PROGRAM}.rb"
FORMULA_ASSET = Path(TAP_FORMULA).name


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
        return PROGRAM + self.binary_extension

    @property
    def binary_extension(self):
        return ".exe" if self.os == "windows" else ""

    def asset_stem(self, version):
        return f"{PROGRAM}-{version}-{self.os}-{self.arch}"

    def release_binary(self, version):
        return self.asset_stem(version) + self.binary_extension

    def archive(self, version):
        extension = ".zip" if self.os == "windows" else ".tar.gz"
        return self.asset_stem(version) + extension

    @property
    def npm_os(self):
        return {"macos": "darwin", "windows": "win32"}.get(self.os, self.os)

    @property
    def npm_name(self):
        return f"{NPM_PACKAGE}-{self.npm_platform}"

    @property
    def npm_platform(self):
        return f"{self.npm_os}-{self.arch}"


TARGETS = tuple(Target(zig) for zig in json.loads((ROOT / ".github/release-targets.json").read_text()))


ZON_VERSION = rf'^    \.version = "({VERSION_PATTERN})",$'


def version():
    zon = (ROOT / "build.zig.zon").read_text()
    match = re.search(ZON_VERSION, zon, re.M)
    if match is None:
        raise SystemExit("build.zig.zon: expected a release version")
    return match[1]


def with_version(zon, requested):
    """Return build.zig.zon text naming the requested version, given with or without a leading v."""
    release_version = requested.removeprefix("v")
    if re.fullmatch(VERSION_PATTERN, release_version) is None:
        raise SystemExit(f"invalid version: {requested}")
    updated, count = re.subn(ZON_VERSION, f'    .version = "{release_version}",', zon, count=1, flags=re.M)
    if count != 1:
        raise SystemExit("build.zig.zon: expected a release version")
    return updated


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
    url = f"{DOWNLOADS}/download/v{release_version}"
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
    (output / FORMULA_ASSET).write_text(formula)
    for installer in INSTALLERS:
        shutil.copy2(ROOT / installer, output / installer)
    assets = [FORMULA_ASSET, *INSTALLERS]
    for target in TARGETS:
        assets.extend((target.release_binary(release_version), target.archive(release_version)))
    write_checksums(output, assets)


def write_checksums(output, assets):
    sums = "".join(f"{digest(output / name)}  {name}\n" for name in sorted(assets))
    manifest = output / CHECKSUMS
    manifest.write_text(sums)
    return manifest


def tagged_dir(release_version, output):
    return output / "download" / f"v{release_version}"


def publish_latest(sums, output):
    latest = output / "latest" / "download"
    latest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(sums, latest / sums.name)


def mirror(release_version, release, output):
    """Lay out the R2 bucket: every release under its tag, and a stable one as latest."""
    tagged = tagged_dir(release_version, output)
    shutil.copytree(release, tagged)
    if "-" in release_version:
        return
    publish_latest(tagged / CHECKSUMS, output)
    for installer in INSTALLERS:
        shutil.copy2(tagged / installer, output / installer)


def installer_fixture(target, release_version, bin_dir, output):
    """Stage the same offline release fixture for both installer tests."""
    tagged = tagged_dir(release_version, output)
    asset = pack(target, release_version, bin_dir, tagged)
    sums = write_checksums(tagged, [asset])
    publish_latest(sums, output)
    checksum, _ = sums.read_text().split()
    return release_version, asset, checksum


def write_manifest(package_dir, manifest):
    package_dir.mkdir(parents=True, exist_ok=True)
    (package_dir / "package.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for name in NOTICES:
        shutil.copy2(ROOT / name, package_dir / name)


def npm_packages(release_version, binaries, output):
    publish_order = []
    shared = {
        "version": release_version,
        "license": "MIT",
        "repository": {"type": "git", "url": f"git+{REPOSITORY}.git"},
        "publishConfig": {"access": "public"},
    }
    for target in TARGETS:
        package_dir = output / target.npm_name
        publish_order.append(package_dir)
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
    main = output / NPM_PACKAGE
    write_manifest(main, {
        **shared,
        "name": NPM_PACKAGE,
        "description": "Align moved screenshot content and box visual changes",
        "bin": {"uidiff": "uidiff.cjs"},
        "files": ["uidiff.cjs", *NOTICES],
        "optionalDependencies": {target.npm_name: release_version for target in TARGETS},
        "uidiffNative": {target.npm_platform: target.npm_name for target in TARGETS},
    })
    shutil.copy2(ROOT / "npm/uidiff/uidiff.cjs", main / "uidiff.cjs")
    return [*publish_order, main]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("matrix")
    commands.add_parser("tap")
    commands.add_parser("version")
    commands.add_parser("set-version").add_argument("version")
    for command in ("pack", "installer-fixture"):
        package = commands.add_parser(command)
        package.add_argument("target", choices=[target.zig for target in TARGETS])
        package.add_argument("bin_dir", type=Path)
        package.add_argument("output", type=Path)
    commands.add_parser("finalize").add_argument("output", type=Path)
    bucket = commands.add_parser("mirror")
    bucket.add_argument("release", type=Path)
    bucket.add_argument("output", type=Path)
    npm = commands.add_parser("npm")
    npm.add_argument("binaries", type=Path)
    npm.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "set-version":
        zon = ROOT / "build.zig.zon"
        zon.write_text(with_version(zon.read_text(), args.version))
        print(version())
        return
    release_version = version()

    if args.command == "matrix":
        print(json.dumps([target.zig for target in TARGETS]))
    elif args.command == "tap":
        print(f"repository={TAP_REPOSITORY}")
        print(f"formula={TAP_FORMULA}")
        print(f"asset={FORMULA_ASSET}")
        print(f"version={release_version}")
    elif args.command == "version":
        print(release_version)
    elif args.command == "pack":
        print(pack(Target(args.target), release_version, args.bin_dir, args.output))
    elif args.command == "installer-fixture":
        print("\t".join(installer_fixture(Target(args.target), release_version, args.bin_dir, args.output)))
    elif args.command == "finalize":
        finalize(release_version, args.output)
    elif args.command == "mirror":
        mirror(release_version, args.release, args.output)
    elif args.command == "npm":
        for package_dir in npm_packages(release_version, args.binaries, args.output):
            print(package_dir)


if __name__ == "__main__":
    main()
