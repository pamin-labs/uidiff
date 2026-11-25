#!/bin/sh
set -eu

case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) exit 1 ;;
esac
case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x64 ;;
    *) exit 1 ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/uidiff-install-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export FIXTURE_RELEASE="$tmp/release"
export PATH="$tmp/bin:$PATH"
unset UIDIFF_VERSION

version=1.2.3
asset=uidiff-$version-$os-$arch
tagged=$FIXTURE_RELEASE/download/v$version
latest=$FIXTURE_RELEASE/latest/download
mkdir -p "$tagged" "$latest" "$tmp/bin"
cp zig-out/bin/uidiff "$tagged/$asset"
hash=$(shasum -a 256 < "$tagged/$asset")
printf "%s  %s\n" "${hash%% *}" "$asset" > "$tagged/SHA256SUMS"
cp "$tagged/SHA256SUMS" "$latest/SHA256SUMS"

cat > "$tmp/bin/curl" <<'MOCK'
#!/bin/sh
set -eu
while [ "$1" != --output ]; do shift; done
output=$2
case "$3" in
    https://github.com/pamin-labs/uidiff/releases/*)
        cp "$FIXTURE_RELEASE/${3#*"/releases/"}" "$output" ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/curl"

installed=$HOME/.local/bin/uidiff
[ "$(UIDIFF_VERSION=v$version sh install.sh)" = "$installed" ]
cmp "$installed" zig-out/bin/uidiff
[ "$(sh install.sh)" = "$installed" ]
"$installed" --help > /dev/null

printf "corrupt\n" > "$tagged/$asset"
if sh install.sh > "$tmp/output" 2> "$tmp/error"; then
    printf "install.sh accepted a corrupt asset\n" >&2
    exit 1
fi
grep -q "SHA-256 mismatch" "$tmp/error"
cmp "$installed" zig-out/bin/uidiff
