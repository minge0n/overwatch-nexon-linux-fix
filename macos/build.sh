#!/bin/bash
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'macOS is required.' >&2; exit 1; }
[ "$#" -eq 1 ] || { printf '%s\n' 'Usage: bash macos/build.sh OUTPUT_DIRECTORY' >&2; exit 2; }
source_dir="$(cd "$(dirname "$0")" && pwd -P)"
mkdir -p "$1"
output="$(cd "$1" && pwd -P)"
/usr/bin/ruby -rdigest -e '
    der = File.binread(ARGV[0])
    abort "Pinned root fingerprint mismatch" unless Digest::SHA256.hexdigest(der) == "3e9099b5015e8f486c00bcea9d111ee721faba355a89bcf1df69561e3dc6325c"
    File.write(ARGV[1], "static const unsigned char pinned_root_der[] = {" + der.bytes.map { |byte| "0x%02x" % byte }.join(",") + "};\n")
' "$source_dir/certs/assured-id-root.der" "$output/pinned-root.h"
/usr/bin/xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
    -Wall -Wextra -Werror -O2 -I "$output" -dynamiclib -framework Security -framework CoreFoundation \
    "$source_dir/trust-filter.c" -o "$output/libow-nexon-trust.dylib"
/usr/bin/xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
    -Wall -Wextra -Werror -O2 -framework Security -framework CoreFoundation \
    "$source_dir/trust-probe.c" -o "$output/trust-probe"
/usr/bin/codesign --force --sign - "$output/libow-nexon-trust.dylib" "$output/trust-probe"
