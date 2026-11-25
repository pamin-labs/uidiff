"""Render the README sheets from a local screenshot corpus or check its links."""

import argparse
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
IMAGES = ROOT / "docs/images"
SHEETS = ("desktop-dark", "phone-insert", "phone-settings", "phone-list")
SCALE = "2"


class ReadmeImages(HTMLParser):
    def __init__(self):
        super().__init__()
        self.sources = []

    def handle_starttag(self, tag, attrs):
        if tag == "img":
            source = dict(attrs).get("src")
            if source:
                self.sources.append(source)


def check():
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    parsed = ReadmeImages()
    parsed.feed(readme)
    sources = parsed.sources + re.findall(r"!\[[^\]\n]*\]\(\s*<?([^\s)>]+)", readme)
    if not sources:
        raise SystemExit("README.md: expected at least one image reference")
    for ref in sources:
        url = urlsplit(ref)
        if url.scheme or url.netloc or not (ROOT / unquote(url.path)).is_file():
            raise SystemExit(f"README.md: missing image {ref}")


def render(args):
    IMAGES.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=IMAGES) as directory:
        work = Path(directory)
        for name in SHEETS:
            pair = args.pairs / getattr(args, name.replace("-", "_"))
            output = work / f"{name}.png"
            argv = [args.binary, pair / "before.png", pair / "after.png",
                    "--scale", SCALE, "--annotate", output]
            result = subprocess.run(argv, stdout=subprocess.DEVNULL, check=False)
            if result.returncode not in (0, 1):
                raise SystemExit(f"{output.name}: uidiff exited {result.returncode}")
            subprocess.run(["oxipng", "--quiet", "-o", "max", "--strip", "safe", output], check=True)
        for output in work.iterdir():
            output.replace(IMAGES / output.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    generate = commands.add_parser("render")
    generate.add_argument("pairs", type=Path)
    generate.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/uidiff")
    for name in SHEETS:
        generate.add_argument(f"--{name}", required=True, help="pair directory relative to the corpus")
    args = parser.parse_args()
    if args.command == "check":
        check()
    else:
        render(args)


if __name__ == "__main__":
    main()
