#!/bin/sh
# Run once; prints the environment used by Android builds. Leaves upstream Exact untouched.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source=${ALONA_EXACT_SOURCE:-/Users/manlikeabro/Documents/repos/exact}
copy=${ALONA_EXACT_COPY:-/tmp/alona-android-exact}
if [ ! -d "$copy" ]; then cp -cR "$source" "$copy"; fi
if ! grep -q ALONA_ANDROID_MAVEN "$copy/host/android/settings.gradle.kts"; then
  patch "$copy/host/android/settings.gradle.kts" < "$root/tools/patches/android-local-maven.patch"
fi
printf 'export EXACT="%s" ALONA_ANDROID_MAVEN="%s/.exact/android-maven"\n' "$copy" "$root"
