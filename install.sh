#!/bin/sh
set -eu

# Release metadata is checked against the packager.
program=uidiff
downloads=https://uidiff.paminlabs.com
checksums=SHA256SUMS
pattern="[0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z.-]+)?"

fail() {
    printf "%s: %s\n" "$program" "$1" >&2
    exit 1
}

case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) fail "unsupported operating system" ;;
esac
case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x64 ;;
    *) fail "unsupported architecture" ;;
esac

version=${UIDIFF_VERSION:-}
version=${version#v}
if [ -n "${UIDIFF_VERSION:-}" ]; then
    printf "%s\n" "$version" | awk -v pattern="$pattern" '$0 ~ ("^" pattern "$") { ok = 1 } END { exit !ok || NR != 1 }' ||
        fail "invalid UIDIFF_VERSION"
    manifest_url="$downloads/download/v$version"
else
    manifest_url="$downloads/latest/download"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/$program.XXXXXX")
staged=
trap 'rm -rf "$tmp"; if [ -n "$staged" ]; then rm -f "$staged"; fi' EXIT
trap 'exit 1' HUP INT TERM

download() {
    curl -q --fail --silent --show-error --location --proto "=https" --proto-redir "=https" --output "$2" "$1"
}

download "$manifest_url/$checksums" "$tmp/$checksums"
suffix="-$os-$arch"
prefix="$program-"
entry=$(awk -v version="$version" -v pattern="$pattern" -v prefix="$prefix" -v suffix="$suffix" '
    NF == 2 && length($1) == 64 && $1 ~ /^[0-9a-f]+$/ &&
        ((version != "" && $2 == prefix version suffix) ||
         (version == "" && $2 ~ ("^" prefix pattern suffix "$"))) {
        print $1, $2
        count++
    }
    END { if (count != 1) exit 1 }
' "$tmp/$checksums") || fail "$checksums: expected one binary entry for $os-$arch"
expected=${entry%% *}
asset=${entry#* }
version=${asset#"$prefix"}
version=${version%"$suffix"}

download "$downloads/download/v$version/$asset" "$tmp/$asset"
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum < "$tmp/$asset")
else
    actual=$(shasum -a 256 < "$tmp/$asset")
fi
[ "${actual%% *}" = "$expected" ] || fail "$asset: SHA-256 mismatch"

destination=$HOME/.local/bin
installed=$destination/$program
mkdir -p "$destination"
[ ! -d "$installed" ] || fail "$installed: is a directory"
staged=$(mktemp "$destination/.$program.XXXXXX")
cp "$tmp/$asset" "$staged"
chmod 755 "$staged"
mv -f "$staged" "$installed"
printf "%s\n" "$installed"
case ":$PATH:" in
    *":$destination:"*) ;;
    *) printf "%s: add %s to PATH to run %s\n" "$program" "$destination" "$program" >&2 ;;
esac
