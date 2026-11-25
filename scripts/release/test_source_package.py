"""Build the source package Zig actually extracts from a release archive."""
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
from tempfile import TemporaryDirectory

from package import ROOT


def main():
    tracked = {
        os.fsdecode(name) for name in
        subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
        if name
    }
    with TemporaryDirectory(prefix="uidiff-source-package-") as directory:
        work = Path(directory)
        archive = work / "uidiff-source.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            for path in sorted(tracked):
                bundle.add(ROOT / path, arcname=f"uidiff/{path}", recursive=False)

        # Ask Zig which paths the manifest publishes.
        inventory = subprocess.check_output(
            ["zig", "fetch", "--debug-hash", "--pkg-dir", str(work / "cache"), str(archive)],
            cwd=ROOT,
            text=True,
        )
        published = {
            line.split(": ", 2)[2] for line in inventory.splitlines() if line.startswith("file: ")
        }
        assert "build.zig" in published and published <= tracked
        package = work / "package"
        for path in published:
            target = package / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, target)
        # The normal build fetches the pinned dependencies before this gate.
        dependencies = ROOT / "zig-pkg"
        if os.name != "nt" and dependencies.is_dir():
            (package / "zig-pkg").symlink_to(dependencies, target_is_directory=True)

        assert not (package / "tests/fuzz").exists()
        assert not (package / "tests/fixtures/jpeg").exists()
        subprocess.run(["zig", "build", "-Doptimize=safe"], cwd=package, check=True)


if __name__ == "__main__":
    main()
