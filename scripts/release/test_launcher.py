"""Exercise staged npm packages and the launcher with the locally built CLI."""

import json
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
from tempfile import TemporaryDirectory
import zipfile

from package import NOTICES, NPM_PACKAGE, ROOT, TARGETS, digest, finalize, npm_packages, pack, version


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
    sums = release / "SHA256SUMS"
    lines = [line.split("  ", 1) for line in sums.read_text().splitlines()]
    assert {name: checksum for checksum, name in lines} == {
        asset.name: digest(asset) for asset in release.iterdir() if asset != sums
    }
    for target in TARGETS:
        archive = release / target.archive(release_version)
        if target.os == "windows":
            with zipfile.ZipFile(archive) as bundle:
                names = bundle.namelist()
        else:
            with tarfile.open(archive) as bundle:
                names = bundle.getnames()
        assert names == [target.binary, *NOTICES], archive.name


def main():
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


if __name__ == "__main__":
    main()
