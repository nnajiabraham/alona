#!/bin/sh
# Run once; prints the environment used by Android builds. Leaves upstream Exact untouched.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source=${ALONA_EXACT_SOURCE:-/Users/manlikeabro/Documents/repos/exact}
copy=${ALONA_EXACT_COPY:-/tmp/alona-android-exact}
if [ ! -d "$copy" ]; then
  mkdir -p "$copy"
  # Other builds create and unlink temporary target files while this snapshot is made.
  for entry in "$source"/* "$source"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "$(basename "$entry")" in target|.exact) continue ;; esac
    cp -cR "$entry" "$copy/"
  done
fi
if ! grep -q ALONA_ANDROID_MAVEN "$copy/host/android/settings.gradle.kts"; then
  patch "$copy/host/android/settings.gradle.kts" < "$root/tools/patches/android-local-maven.patch"
fi
if ! grep -q 'android:allowBackup="false"' "$copy/host/android/app/src/main/AndroidManifest.xml"; then
  patch -d "$copy" -p1 < "$root/tools/patches/android-private-backup.patch"
fi
printf 'export EXACT="%s" ALONA_ANDROID_MAVEN="%s/.exact/android-maven"\n' "$copy" "$root"
