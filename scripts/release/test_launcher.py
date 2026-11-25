"""Check the standalone installer contract and exercise the staged npm launcher."""

import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
from tempfile import TemporaryDirectory
import zipfile

from package import (
    CHECKSUMS, FORMULA_ASSET, NOTICES, NPM_PACKAGE, PROGRAM, RELEASES, ROOT,
    TARGETS, VERSION_PATTERN, digest, finalize, npm_packages, pack, version,
)


def check_literals(text, filename, expected):
    for name, value in expected.items():
        pattern = rf"^\s*{re.escape(name)}\s*=\s*([^\r\n]+)"
        found = [literal.strip().strip("'\"") for literal in re.findall(pattern, text, re.M)]
        assert found == [value], f"{filename}: {name} differs from the release contract"


def check_installers():
    shell = (ROOT / "install.sh").read_text()
    powershell = (ROOT / "install.ps1").read_text()
    windows = [target for target in TARGETS if target.os == "windows"]
    posix = [target for target in TARGETS if target.os != "windows"]
    literal = dict(program=PROGRAM, releases=RELEASES, checksums=CHECKSUMS)
    sh_version = VERSION_PATTERN.replace(r"\.", "[.]").replace("(?:", "(")
    check_literals(shell, "install.sh", {**literal, "pattern": sh_version})
    check_literals(powershell, "install.ps1", {
        **{f"${name}": value for name, value in literal.items()},
        "$releaseOs": windows[0].os,
        "$extension": windows[0].binary_extension,
        "$versionPattern": VERSION_PATTERN,
    })

    # OS and CPU spellings on the left come from uname and .NET.
    systems = {"macos": "Darwin", "linux": "Linux"}
    machines = {"aarch64": "arm64|aarch64", "x86_64": "x86_64|amd64"}
    dotnet = {"aarch64": "Arm64", "x86_64": "X64"}
    shell_os = re.findall(r"^\s*(\w+)\) os=(\w+) ;;$", shell, re.M)
    shell_arch = re.findall(r"^\s*([\w|]+)\) arch=(\w+) ;;$", shell, re.M)
    windows_arch = re.findall(r"^\s*(\w+) \{ '(\w+)' }$", powershell, re.M)
    assert sorted(shell_os) == sorted({(systems[t.os], t.os) for t in posix}), "install.sh: OS mappings differ"
    assert sorted(shell_arch) == sorted({(machines[t.zig.split("-")[0]], t.arch) for t in posix}), "install.sh: CPU mappings differ"
    assert sorted(windows_arch) == sorted({(dotnet[t.zig.split("-")[0]], t.arch) for t in windows}), "install.ps1: CPU mappings differ"
    assert {(t.os, t.arch) for t in posix} == {(os, arch) for _, os in shell_os for _, arch in shell_arch}, "install.sh: target matrix differs"


def check_launcher(launcher, binary):
    fixtures = ROOT / "tests/fixtures/images"
    for case, expected_status in (("identical", 0), ("changed", 1)):
        pair = fixtures / case
        args = [str(pair / "before.png"), str(pair / "after.png"), "--json"]
        direct = subprocess.run([binary, *args], capture_output=True, text=True)
        result = subprocess.run(["node", launcher, *args], capture_output=True, text=True)
        assert direct.returncode == result.returncode == expected_status, result.stderr
        assert json.loads(result.stdout) == json.loads(direct.stdout)

    result = subprocess.run(["node", launcher], capture_output=True, text=True)
    assert result.returncode == 2, result.stderr


def check_assets(release, release_version):
    sums = release / CHECKSUMS
    lines = [line.split("  ", 1) for line in sums.read_text().splitlines()]
    assert {name: checksum for checksum, name in lines} == {
        asset.name: digest(asset) for asset in release.iterdir() if asset != sums
    }
    formula = release / FORMULA_ASSET
    content = formula.read_text()
    assert f'version "{release_version}"' in content
    for target in TARGETS:
        archive = release / target.archive(release_version)
        if target.os != "windows":
            assert f'url "{RELEASES}/download/v{release_version}/{archive.name}"' in content
            assert f'sha256 "{digest(archive)}"' in content
        if target.os == "windows":
            with zipfile.ZipFile(archive) as bundle:
                names = bundle.namelist()
        else:
            with tarfile.open(archive) as bundle:
                names = bundle.getnames()
        assert names == [target.binary, *NOTICES], archive.name


def main():
    check_installers()
    dist_os = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}[platform.system()]
    arch = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}[
        platform.machine().lower()
    ]
    host = next(target for target in TARGETS if (target.os, target.arch) == (dist_os, arch))
    release_version = version()

    with TemporaryDirectory(prefix="uidiff-launcher-") as directory:
        temp = Path(directory)
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        release = temp / "release"
        packages = temp / "node_modules"
        binary = ROOT / "zig-out/bin" / host.binary
        # Only the host package is executed. The other archives exercise the artifact layout.
        for target in TARGETS:
            shutil.copy2(binary, bin_dir / target.binary)
            pack(target, release_version, bin_dir, release)
        finalize(release_version, release)
        check_assets(release, release_version)
        if shutil.which("ruby"):
            subprocess.run(["ruby", "-c", release / FORMULA_ASSET], check=True)
        publish_order = npm_packages(release_version, release, packages)
        assert publish_order == [*(packages / target.npm_name for target in TARGETS), packages / NPM_PACKAGE]

        launcher = packages / NPM_PACKAGE / "uidiff.cjs"
        manifest = json.loads(launcher.with_name("package.json").read_text())
        assert manifest["optionalDependencies"] == {target.npm_name: release_version for target in TARGETS}
        assert manifest["name"] == NPM_PACKAGE
        assert manifest["bin"] == {"uidiff": "uidiff.cjs"}
        assert manifest["uidiffNative"] == {target.npm_platform: target.npm_name for target in TARGETS}
        assert f"npm install --save-dev {NPM_PACKAGE}" in (ROOT / "README.md").read_text()
        # Exercise Node package resolution for all six staged native packages.
        resolve = "process.stdout.write(require.resolve(process.argv[1], {paths: [process.argv[2]]}))"
        for target in TARGETS:
            target_dir = packages / target.npm_name
            executable = subprocess.check_output(
                ["node", "-e", resolve, f"{manifest['uidiffNative'][target.npm_platform]}/native", launcher.parent],
                text=True,
            )
            assert Path(executable) == (target_dir / target.binary).resolve()
        check_launcher(launcher, binary)
        shutil.rmtree(packages / host.npm_name)
        result = subprocess.run(["node", launcher, "--help"], capture_output=True, text=True)
        assert result.returncode == 2 and host.npm_name in result.stderr, result.stderr

        del manifest["uidiffNative"]
        launcher.with_name("package.json").write_text(json.dumps(manifest))
        result = subprocess.run(["node", launcher, "--help"], capture_output=True, text=True)
        assert result.returncode == 2 and "unsupported platform" in result.stderr, result.stderr


if __name__ == "__main__":
    main()
