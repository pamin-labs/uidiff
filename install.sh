#!/bin/sh
set -eu

fail() {
    printf "uidiff: %s\n" "$1" >&2
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
pattern="[0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z.-]+)?"
releases=https://github.com/pamin-labs/uidiff/releases
if [ -n "${UIDIFF_VERSION:-}" ]; then
    printf "%s\n" "$version" | awk -v pattern="$pattern" '$0 ~ ("^" pattern "$") { ok = 1 } END { exit !ok || NR != 1 }' ||
        fail "invalid UIDIFF_VERSION"
    manifest_url="$releases/download/v$version"
else
    manifest_url="$releases/latest/download"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/uidiff.XXXXXX")
staged=
trap 'rm -rf "$tmp"; if [ -n "$staged" ]; then rm -f "$staged"; fi' EXIT
trap 'exit 1' HUP INT TERM

download() {
    curl -q --fail --silent --show-error --location --proto "=https" --proto-redir "=https" --output "$2" "$1"
}

download "$manifest_url/SHA256SUMS" "$tmp/SHA256SUMS"
suffix="-$os-$arch"
entry=$(awk -v version="$version" -v pattern="$pattern" -v suffix="$suffix" '
    NF == 2 && length($1) == 64 && $1 ~ /^[0-9a-f]+$/ &&
        ((version != "" && $2 == "uidiff-" version suffix) ||
         (version == "" && $2 ~ ("^uidiff-" pattern suffix "$"))) {
        print $1, $2
        count++
    }
    END { if (count != 1) exit 1 }
' "$tmp/SHA256SUMS") || fail "SHA256SUMS: expected one binary entry for $os-$arch"
expected=${entry%% *}
asset=${entry#* }
version=${asset#uidiff-}
version=${version%"$suffix"}

download "$releases/download/v$version/$asset" "$tmp/$asset"
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum < "$tmp/$asset")
else
    actual=$(shasum -a 256 < "$tmp/$asset")
fi
[ "${actual%% *}" = "$expected" ] || fail "$asset: SHA-256 mismatch"

destination=$HOME/.local/bin
installed=$destination/uidiff
mkdir -p "$destination"
[ ! -d "$installed" ] || fail "$installed: is a directory"
staged=$(mktemp "$destination/.uidiff.XXXXXX")
cp "$tmp/$asset" "$staged"
chmod 755 "$staged"
mv -f "$staged" "$installed"
printf "%s\n" "$installed"
