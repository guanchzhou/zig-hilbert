#!/usr/bin/env bash
# Single-thread 2D encode/decode on identical random points (orders 32 and 16):
#   zig-hilbert (this repository)
#   Rust fast_hilbert 2.1.0 (crates.io)
#   AdamSabol89/fast_hilbert, the Zig port of the Rust crate
#   adolgert/HilbertCurveCompact, ported to Zig 0.17 by hcc-zig-0.17.patch
# Equal checksums mean the implementations produced the same indices.
# The "nd" lines compare n-D encode, decode, and consecutive-index decode
# against HilbertCurveCompact on the same random points (different curves).
set -euo pipefail

cd "$(dirname "$0")"
n="${1:-8388608}"
port_commit=0bdf867f81a5c899154dbaf1070f96ae71a582d4
port_sha256=aa59496a01f80d1082f1fed1a6a2cfbdb730d716182b9c4f6b4d6f10b79e7435
hcc_commit=1b33fa8be84542024c0c2801ec43043b7bad78eb
cache=.cache
mkdir -p "$cache"

zig build-exe -OReleaseFast --dep hilbert -Mroot=self.zig -Mhilbert=../../src/root.zig \
    -femit-bin="$cache/self" --cache-dir "$cache/zig"

cargo build --quiet --locked --release --manifest-path rust/Cargo.toml --target-dir "$cache/cargo"

port_src="$cache/fast_hilbert-$port_commit.zig"
if [ ! -f "$port_src" ]; then
    curl -fsSL "https://raw.githubusercontent.com/AdamSabol89/fast_hilbert/$port_commit/src/fast_hilbert.zig" -o "$port_src.tmp"
    echo "$port_sha256  $port_src.tmp" | shasum -a 256 -c - >/dev/null
    mv "$port_src.tmp" "$port_src"
fi
zig build-exe -OReleaseFast --dep fast_hilbert -Mroot=zigport.zig -Mfast_hilbert="$port_src" \
    -femit-bin="$cache/zigport" --cache-dir "$cache/zig"

hcc="$cache/hcc-$hcc_commit"
if [ ! -d "$hcc" ]; then
    git clone --quiet https://github.com/adolgert/HilbertCurveCompact "$hcc"
    git -C "$hcc" checkout --quiet "$hcc_commit"
    git -C "$hcc" apply "$PWD/hcc-zig-0.17.patch"
fi
zig build-exe -OReleaseFast --dep hilbertcurve --dep hilbert -Mroot=hcc.zig -Mhilbert=../../src/root.zig \
    --dep build_options -Mhilbertcurve="$hcc/src/bench_root.zig" -Mbuild_options="$hcc/src/build_options.zig" \
    -femit-bin="$cache/hcc" --cache-dir "$cache/zig"

"$cache/self" "$n"
"$cache/cargo/release/fast-hilbert-compare" "$n"
"$cache/zigport" "$n"
"$cache/hcc" "$n"
