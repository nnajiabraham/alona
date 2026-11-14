#!/bin/bash
# Downloads the native inference frameworks the Apple module links, checks
# their SHA-256, and unpacks them into modules/apple/. They are too large to
# commit (about 360 MB unpacked). Safe to rerun: a framework already in place
# is skipped.
#
#   tools/fetch-apple-frameworks.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/modules/apple"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name | url | sha256 | path of the .xcframework inside the zip
frameworks=(
  "sherpa-onnx|https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v2.0.1-macos-static.xcframework.zip|3c378789ebcbf3b1fb2e7cf0c58dae8e5629001598148aee2edd4494dc939a27|sherpa-onnx.xcframework"
  "onnxruntime|https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-macos-static-xcframework-1.28.2.xcframework.zip|cb0b0bec912c77229517c463e28a3fac9674c521f9599919efff1ef2b42f3da0|onnxruntime.xcframework"
  "llama|https://github.com/ggml-org/llama.cpp/releases/download/b12383/llama-b12383-xcframework.zip|8bb53be2fa94b3e483ecd2df7173ec7fe787d1630eb827070975eab93102f188|build-apple/llama.xcframework"
)

mkdir -p "$dest"
for entry in "${frameworks[@]}"; do
  IFS='|' read -r name url sha inner <<<"$entry"
  if [ -d "$dest/$name.xcframework" ]; then
    echo "$name.xcframework: already in place"
    continue
  fi
  echo "$name.xcframework: downloading"
  curl -fsSL -o "$work/$name.zip" "$url"
  actual="$(shasum -a 256 "$work/$name.zip" | awk '{print $1}')"
  if [ "$actual" != "$sha" ]; then
    echo "$name: SHA-256 is $actual, expected $sha" >&2
    exit 1
  fi
  mkdir -p "$work/$name"
  unzip -q "$work/$name.zip" -d "$work/$name"
  mv "$work/$name/$inner" "$dest/$name.xcframework"
done

# Some archives carry symlinks that point at nothing or at themselves. The linker ignores them, but Exact's
# freshness check cannot read them and then refuses to drive any host's build.
find "$dest" -type l | while read -r link; do
  [ -e "$link" ] || rm "$link"
done
echo "Apple frameworks are in $dest"
