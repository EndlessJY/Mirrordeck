#!/bin/zsh
# Rebuilds lanadb-icons.dex (checked in, so the app builds without the
# Android SDK). Needs a JDK and the Android SDK (platform 31, build-tools).
set -euo pipefail
cd "${0:A:h}"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
platform_jar="$(ls "$sdk"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)"
[[ -n "$platform_jar" && -f "$platform_jar" ]] || { echo "缺少 Android SDK platform android.jar" >&2; exit 1; }
javac --release 11 -cp "$platform_jar" -d "$work" src/IconDump.java
"$(ls -d "$sdk"/build-tools/* | sort -V | tail -1)/d8" --min-api 26 --output "$work" "$work"/IconDump.class
cp "$work/classes.dex" lanadb-icons.dex
echo "已生成 $PWD/lanadb-icons.dex"
